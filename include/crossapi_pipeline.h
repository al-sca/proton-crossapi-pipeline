// crossapi_pipeline.h -- pipelined D3D11 -> D3D12 -> D3D11 frame handoff over a shared fence.
//
// The problem it solves
// ---------------------
// An add-on that hands every D3D11 game frame to a private D3D12 device (an NGX/DLSS
// evaluate, an upscaler, a denoiser, ...) and brings the result back inside the SAME frame
// serialises the two:
//
//     D3D11: [game n][copy-in][Signal] ...... Wait(result n) [copy home n][present]
//     D3D12:                     [Wait][ consumer work on n ][Signal]
//
// The game's queue idles for the whole consumer pass. Under Wine/Proton the D3D11 device is
// DXVK and the D3D12 device is vkd3d-proton -- two separate VkDevices, i.e. two separate GPU
// contexts -- and both cross-device waits land on the frame's critical path. The symptom:
// frame time = game + consumer + handoff latency, GPU utilisation far below 100 %, no CPU
// thread anywhere near saturated, and DXVK's HUD reporting "GPU 100 %" because its queue
// sits blocked on the semaphore.
//
// The fix: carry frame n-1 home instead of frame n
// ------------------------------------------------
//     D3D11: [game n] Wait(result n-1) [copy-in n][copy home n-1][Signal n][present] [game n+1] ...
//     D3D12:                                                     [Wait][consumer n] -- overlaps game n+1
//
// The D3D11 queue waits on the previous consumer pass only right before it overwrites the
// shared inputs, by which time that pass has normally retired. The copy home is recorded
// BEFORE the Signal that hands the shared output back to D3D12, so a single set of shared
// textures stays race-free, and the wait keeps the shared fence monotonic (a D3D11 Signal
// can never overtake the D3D12 Signal it follows). Cost: one frame of latency.
//
// Usage, once per frame on the D3D11 immediate context (after the game rendered frame n):
//
//     const bool carry = pipe.BeginFrame();        // 1. waits (GPU-side) for pass n-1
//     ... copy / resample frame n into the shared INPUT textures on ctx ...
//     if (carry) ... copy the shared OUTPUT (result n-1) into the backbuffer ...
//     pipe.HandOff();                              // 2. D3D11 Signal + Flush, D3D12 queue Wait
//     ... record and ExecuteCommandLists the consumer pass on the D3D12 queue ...
//     if (pipe.EndFrame(ok))                       // 3. D3D12 Signal
//         ... Serial mode only: copy the shared OUTPUT (result n) into the backbuffer ...
//
// Serial mode reproduces the original same-frame behaviour, for A/B comparison and as a
// fallback. Call Drain() before recreating shared resources or the devices.
//
// Header-only, no dependencies beyond the Windows SDK. Link d3d11.lib and d3d12.lib.
// SPDX-License-Identifier: MIT

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#include <d3d11_4.h>
#include <d3d12.h>

namespace xapi {

enum class Mode
{
    Serial,     // result n is copied home in frame n (original behaviour, the game queue idles)
    Pipelined,  // result n-1 is copied home in frame n (one frame of latency, the passes overlap)
};

class D3D11ToD3D12Pipeline
{
public:
    D3D11ToD3D12Pipeline() = default;
    D3D11ToD3D12Pipeline(const D3D11ToD3D12Pipeline &) = delete;
    D3D11ToD3D12Pipeline &operator=(const D3D11ToD3D12Pipeline &) = delete;
    ~D3D11ToD3D12Pipeline() { Shutdown(); }

    // Creates the shared fence on the D3D12 device and opens it on the D3D11 one. Both devices
    // must live on the same adapter. The caller keeps ownership of every argument.
    HRESULT Init(ID3D11Device *dev11, ID3D11DeviceContext *ctx, ID3D12Device *dev12,
                 ID3D12CommandQueue *queue12, Mode mode, DWORD cpu_timeout_ms = 2000)
    {
        Shutdown();
        if (dev11 == nullptr || ctx == nullptr || dev12 == nullptr || queue12 == nullptr) return E_INVALIDARG;
        mode_       = mode;
        timeout_ms_ = cpu_timeout_ms;
        queue_      = queue12;
        queue_->AddRef();

        HRESULT hr = ctx->QueryInterface(__uuidof(ID3D11DeviceContext4), reinterpret_cast<void **>(&ctx4_));
        ID3D11Device5 *dev5 = nullptr;
        if (SUCCEEDED(hr)) hr = dev11->QueryInterface(__uuidof(ID3D11Device5), reinterpret_cast<void **>(&dev5));
        if (SUCCEEDED(hr)) hr = dev12->CreateFence(0, D3D12_FENCE_FLAG_SHARED, __uuidof(ID3D12Fence),
                                                   reinterpret_cast<void **>(&fence12_));
        HANDLE shared = nullptr;
        if (SUCCEEDED(hr)) hr = dev12->CreateSharedHandle(fence12_, nullptr, GENERIC_ALL, nullptr, &shared);
        if (SUCCEEDED(hr)) hr = dev5->OpenSharedFence(shared, __uuidof(ID3D11Fence), reinterpret_cast<void **>(&fence11_));
        if (shared != nullptr) CloseHandle(shared);
        if (dev5 != nullptr) dev5->Release();
        if (SUCCEEDED(hr))
        {
            event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
            if (event_ == nullptr) hr = HRESULT_FROM_WIN32(GetLastError());
        }
        if (FAILED(hr)) Shutdown();
        return hr;
    }

    // Drains the D3D12 queue and releases everything Init created.
    void Shutdown()
    {
        if (fence12_ != nullptr && queue_ != nullptr) Drain();
        if (fence11_ != nullptr) { fence11_->Release(); fence11_ = nullptr; }
        if (fence12_ != nullptr) { fence12_->Release(); fence12_ = nullptr; }
        if (ctx4_ != nullptr)    { ctx4_->Release();    ctx4_ = nullptr; }
        if (queue_ != nullptr)   { queue_->Release();   queue_ = nullptr; }
        if (event_ != nullptr)   { CloseHandle(event_); event_ = nullptr; }
        value_ = pending_ = 0;
        carry_ = handed_off_ = false;
    }

    // Switching modes drains first, so no half-finished frame straddles the switch.
    void SetMode(Mode mode)
    {
        if (mode == mode_) return;
        Drain();
        mode_ = mode;
    }
    Mode GetMode() const { return mode_; }

    // Step 1, before the shared inputs are written. Enqueues the D3D11 (GPU-side) wait that the
    // previous consumer pass is owed. Returns true when the shared output holds a finished
    // result of the previous frame that should be copied home in this frame (Pipelined only).
    bool BeginFrame()
    {
        if (pending_ != 0)
        {
            if (!WaitOn11(pending_)) carry_ = false;
            pending_ = 0;
        }
        const bool carry = mode_ == Mode::Pipelined && carry_;
        carry_ = false;
        return carry;
    }

    // Step 2, after the inputs (and, when BeginFrame returned true, the copy home) were
    // recorded on the D3D11 context: D3D11 Signal + Flush, then the D3D12 queue waits on it.
    HRESULT HandOff()
    {
        if (fence11_ == nullptr) return E_UNEXPECTED;
        const UINT64 v = ++value_;
        HRESULT hr = ctx4_->Signal(fence11_, v);
        if (FAILED(hr)) return hr;
        ctx4_->Flush();
        hr = queue_->Wait(fence12_, v);
        handed_off_ = SUCCEEDED(hr);
        return hr;
    }

    // Step 3, after the consumer pass was executed on the D3D12 queue (or skipped: the Signal
    // is still issued so the fence keeps its order). output_valid=false keeps a failed pass's
    // output from being copied home. Returns true when the caller must copy the result home
    // NOW (Serial mode); in Pipelined mode it goes home in the next frame's BeginFrame.
    bool EndFrame(bool output_valid)
    {
        if (!handed_off_) return false;
        handed_off_ = false;
        const UINT64 v = ++value_;
        if (FAILED(queue_->Signal(fence12_, v))) { --value_; return false; }
        if (mode_ == Mode::Pipelined)
        {
            pending_ = v;
            carry_   = output_valid;
            return false;
        }
        return WaitOn11(v) && output_valid;
    }

    // CPU-waits until every submitted pass has retired and clears the carried state. Call
    // before recreating shared resources (resize) or the devices.
    void Drain()
    {
        if (fence12_ == nullptr || queue_ == nullptr) return;
        const UINT64 v = ++value_;
        if (SUCCEEDED(queue_->Signal(fence12_, v))) WaitCpu(v);
        pending_ = 0;
        carry_   = false;
    }

    UINT64 LastValue() const { return value_; }
    ID3D12Fence *Fence12() const { return fence12_; }

private:
    // GPU-side D3D11 wait; falls back to a CPU wait when the driver refuses the cross-API wait
    // (some D3D11 implementations fault or fail on it).
    bool WaitOn11(UINT64 v)
    {
        HRESULT hr = E_FAIL;
        __try { hr = ctx4_->Wait(fence11_, v); }
        __except (EXCEPTION_EXECUTE_HANDLER) { hr = E_FAIL; }
        return SUCCEEDED(hr) || WaitCpu(v);
    }

    bool WaitCpu(UINT64 v)
    {
        if (fence12_->GetCompletedValue() >= v) return true;
        ResetEvent(event_);
        if (FAILED(fence12_->SetEventOnCompletion(v, event_))) return false;
        WaitForSingleObject(event_, timeout_ms_);
        return fence12_->GetCompletedValue() >= v;
    }

    ID3D11DeviceContext4 *ctx4_    = nullptr;
    ID3D11Fence          *fence11_ = nullptr;
    ID3D12Fence          *fence12_ = nullptr;
    ID3D12CommandQueue   *queue_   = nullptr;
    HANDLE                event_   = nullptr;
    Mode                  mode_    = Mode::Pipelined;
    DWORD                 timeout_ms_ = 2000;
    UINT64                value_   = 0;
    UINT64                pending_ = 0;     // last D3D12 Signal the D3D11 queue still owes a wait
    bool                  carry_   = false; // the pending pass's output is worth copying home
    bool                  handed_off_ = false;
};

} // namespace xapi
