// xapi_bench -- reproduces the D3D11 -> D3D12 cross-API handoff stall without any game.
//
// A "game" pass on a D3D11 device and a "consumer" pass on a private D3D12 device (the shape
// of a DLSS / upscaler / denoiser add-on) exchange every frame through shared textures and a
// shared fence. Both passes are calibrated to a target GPU time, then the same frame loop runs
// in Serial mode (result n goes home in frame n) and Pipelined mode (result n-1 goes home in
// frame n, see include/crossapi_pipeline.h). Run it under Proton/Wine (D3D11 = DXVK,
// D3D12 = vkd3d-proton) and on Windows to compare.
//
//   xapi_bench.exe [--game-ms 5] [--consumer-ms 7] [--frames 600] [--width 2560] [--height 1440]
//                  [--latency 2] [--adapter 0]
//
// SPDX-License-Identifier: MIT

#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include <d3d11_4.h>
#include <d3d12.h>
#include <dxgi1_4.h>
#include <d3dcompiler.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdarg>

#include "../include/crossapi_pipeline.h"

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "d3d12.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "d3dcompiler.lib")

namespace {

FILE *g_out = nullptr;   // results file next to the exe; Wine does not always forward stdout

void Print(const char *fmt, ...)
{
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    fputs(buf, stdout);
    fflush(stdout);
    if (g_out != nullptr) { fputs(buf, g_out); fflush(g_out); }
}

[[noreturn]] void Die(const char *what, HRESULT hr)
{
    Print("FATAL: %s failed 0x%08X\n", what, static_cast<unsigned>(hr));
    if (g_out != nullptr) fclose(g_out);
    ExitProcess(1);
}

#define CHECK(x) do { const HRESULT hr_ = (x); if (FAILED(hr_)) Die(#x, hr_); } while (0)

template <class T> void SafeRelease(T *&p) { if (p != nullptr) { p->Release(); p = nullptr; } }

double NowMs()
{
    static LARGE_INTEGER freq = {};
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return 1000.0 * static_cast<double>(t.QuadPart) / static_cast<double>(freq.QuadPart);
}

// Same ALU loop on both sides: cost scales linearly with 'iters'.
const char kGameCs[] = R"(
RWTexture2D<float4> o : register(u0);
cbuffer C : register(b0) { uint iters; uint frame; uint2 pad; };
[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    float4 v = float4(id.x * 1e-3, id.y * 1e-3, frame * 1e-2, 1.0);
    [loop] for (uint i = 0; i < iters; ++i) v = sin(v * 1.0001 + 0.37) * 0.5 + 0.5;
    o[id.xy] = v;
}
)";

const char kConsumerCs[] = R"(
Texture2D<float4>   src : register(t0);
RWTexture2D<float4> dst : register(u0);
cbuffer C : register(b0) { uint iters; uint frame; };
[numthreads(8, 8, 1)]
void main(uint3 id : SV_DispatchThreadID)
{
    float4 v = src[id.xy];
    [loop] for (uint i = 0; i < iters; ++i) v = sin(v * 1.0001 + 0.53) * 0.5 + 0.5;
    dst[id.xy] = v;
}
)";

ID3DBlob *Compile(const char *src, size_t len, const char *name)
{
    ID3DBlob *code = nullptr, *err = nullptr;
    const HRESULT hr = D3DCompile(src, len, name, nullptr, nullptr, "main", "cs_5_0",
                                  D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &err);
    if (FAILED(hr))
    {
        Print("shader %s: %s\n", name, err != nullptr ? static_cast<const char *>(err->GetBufferPointer()) : "?");
        Die("D3DCompile", hr);
    }
    SafeRelease(err);
    if (getenv("XAPI_DUMP_SHADERS") != nullptr)
    {
        ID3DBlob *dis = nullptr;
        if (SUCCEEDED(D3DDisassemble(code->GetBufferPointer(), code->GetBufferSize(), 0, nullptr, &dis)))
        {
            Print("---- %s ----\n%s\n", name, static_cast<const char *>(dis->GetBufferPointer()));
            dis->Release();
        }
    }
    return code;
}

struct Options
{
    double game_ms     = 5.0;
    double consumer_ms = 7.0;
    int    frames      = 600;
    UINT   width       = 2560;
    UINT   height      = 1440;
    int    latency     = 2;     // frames the CPU may run ahead, like a swapchain's max latency
    UINT   adapter     = 0;
};

struct Bench
{
    Options opt;

    // D3D11 side ("the game")
    ID3D11Device         *dev11 = nullptr;
    ID3D11DeviceContext  *ctx   = nullptr;
    ID3D11ComputeShader  *game_cs = nullptr;
    ID3D11Buffer         *game_cb = nullptr;
    ID3D11Texture2D      *game_tex = nullptr;   // what the game rendered
    ID3D11UnorderedAccessView *game_uav = nullptr;
    ID3D11Texture2D      *home_tex = nullptr;   // where the result lands ("the backbuffer")
    ID3D11Query          *throttle[8] = {};
    ID3D11Query          *drain11 = nullptr;

    // D3D12 side ("the consumer")
    ID3D12Device               *dev12 = nullptr;
    ID3D12CommandQueue         *queue = nullptr;
    ID3D12GraphicsCommandList  *list  = nullptr;
    static const int            kAllocs = 8;
    ID3D12CommandAllocator     *alloc[kAllocs] = {};
    UINT64                      alloc_value[kAllocs] = {};
    ID3D12RootSignature        *root = nullptr;
    ID3D12PipelineState        *pso  = nullptr;
    ID3D12DescriptorHeap       *heap = nullptr;
    ID3D12Resource             *scratch12 = nullptr;   // consumer's private UAV target
    ID3D12Fence                *own_fence = nullptr;   // consumer-only calibration runs
    HANDLE                      own_event = nullptr;
    UINT64                      own_value = 0;

    // Shared pair: created on D3D12, opened on D3D11 (the direction the Feeder uses)
    ID3D12Resource  *in12 = nullptr,  *out12 = nullptr;
    ID3D11Texture2D *in11 = nullptr,  *out11 = nullptr;

    UINT game_iters = 64, consumer_iters = 64;
    int  alloc_slot = 0;

    void Init()
    {
        IDXGIFactory4 *factory = nullptr;
        CHECK(CreateDXGIFactory1(__uuidof(IDXGIFactory4), reinterpret_cast<void **>(&factory)));
        IDXGIAdapter1 *adapter = nullptr;
        CHECK(factory->EnumAdapters1(opt.adapter, &adapter));
        DXGI_ADAPTER_DESC1 ad = {};
        adapter->GetDesc1(&ad);
        char name[128] = {};
        WideCharToMultiByte(CP_UTF8, 0, ad.Description, -1, name, sizeof(name) - 1, nullptr, nullptr);
        Print("adapter %u: %s\n", opt.adapter, name);

        const D3D_FEATURE_LEVEL fl = D3D_FEATURE_LEVEL_11_1;
        CHECK(D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0, &fl, 1, D3D11_SDK_VERSION,
                                &dev11, nullptr, &ctx));
        CHECK(D3D12CreateDevice(adapter, D3D_FEATURE_LEVEL_11_0, __uuidof(ID3D12Device),
                                reinterpret_cast<void **>(&dev12)));
        SafeRelease(adapter);
        SafeRelease(factory);

        D3D12_COMMAND_QUEUE_DESC qd = {};
        qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        CHECK(dev12->CreateCommandQueue(&qd, __uuidof(ID3D12CommandQueue), reinterpret_cast<void **>(&queue)));
        for (int i = 0; i < kAllocs; ++i)
            CHECK(dev12->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, __uuidof(ID3D12CommandAllocator),
                                                reinterpret_cast<void **>(&alloc[i])));
        CHECK(dev12->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc[0], nullptr,
                                       __uuidof(ID3D12GraphicsCommandList), reinterpret_cast<void **>(&list)));
        CHECK(list->Close());
        CHECK(dev12->CreateFence(0, D3D12_FENCE_FLAG_NONE, __uuidof(ID3D12Fence), reinterpret_cast<void **>(&own_fence)));
        own_event = CreateEventW(nullptr, FALSE, FALSE, nullptr);

        MakeD3D11Side();
        MakeD3D12Side();
        MakeSharedPair(&in12, &in11);
        MakeSharedPair(&out12, &out11);

        D3D12_SHADER_RESOURCE_VIEW_DESC sv = {};
        sv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        sv.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        sv.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        sv.Texture2D.MipLevels = 1;
        D3D12_CPU_DESCRIPTOR_HANDLE h = heap->GetCPUDescriptorHandleForHeapStart();
        dev12->CreateShaderResourceView(in12, &sv, h);
        h.ptr += dev12->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        D3D12_UNORDERED_ACCESS_VIEW_DESC uv = {};
        uv.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
        uv.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
        dev12->CreateUnorderedAccessView(scratch12, nullptr, &uv, h);
    }

    void MakeD3D11Side()
    {
        ID3DBlob *cs = Compile(kGameCs, sizeof(kGameCs) - 1, "game_cs");
        CHECK(dev11->CreateComputeShader(cs->GetBufferPointer(), cs->GetBufferSize(), nullptr, &game_cs));
        SafeRelease(cs);

        D3D11_BUFFER_DESC bd = {};
        bd.ByteWidth = 16;
        bd.Usage     = D3D11_USAGE_DEFAULT;
        bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
        CHECK(dev11->CreateBuffer(&bd, nullptr, &game_cb));

        D3D11_TEXTURE2D_DESC td = {};
        td.Width = opt.width; td.Height = opt.height; td.MipLevels = 1; td.ArraySize = 1;
        td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1; td.Usage = D3D11_USAGE_DEFAULT;
        td.BindFlags = D3D11_BIND_UNORDERED_ACCESS | D3D11_BIND_SHADER_RESOURCE;
        CHECK(dev11->CreateTexture2D(&td, nullptr, &game_tex));
        CHECK(dev11->CreateUnorderedAccessView(game_tex, nullptr, &game_uav));
        td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        CHECK(dev11->CreateTexture2D(&td, nullptr, &home_tex));

        D3D11_QUERY_DESC qd = { D3D11_QUERY_EVENT, 0 };
        for (auto &q : throttle) CHECK(dev11->CreateQuery(&qd, &q));
        CHECK(dev11->CreateQuery(&qd, &drain11));
    }

    void MakeD3D12Side()
    {
        D3D12_DESCRIPTOR_RANGE ranges[2] = {};
        ranges[0].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_SRV; ranges[0].NumDescriptors = 1;
        ranges[1].RangeType = D3D12_DESCRIPTOR_RANGE_TYPE_UAV; ranges[1].NumDescriptors = 1;
        ranges[1].OffsetInDescriptorsFromTableStart = 1;
        D3D12_ROOT_PARAMETER params[2] = {};
        params[0].ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
        params[0].DescriptorTable.NumDescriptorRanges = 2;
        params[0].DescriptorTable.pDescriptorRanges   = ranges;
        params[1].ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
        params[1].Constants.Num32BitValues = 2;
        D3D12_ROOT_SIGNATURE_DESC rs = {};
        rs.NumParameters = 2;
        rs.pParameters   = params;
        ID3DBlob *blob = nullptr, *err = nullptr;
        CHECK(D3D12SerializeRootSignature(&rs, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &err));
        CHECK(dev12->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(),
                                         __uuidof(ID3D12RootSignature), reinterpret_cast<void **>(&root)));
        SafeRelease(blob);
        SafeRelease(err);

        ID3DBlob *cs = Compile(kConsumerCs, sizeof(kConsumerCs) - 1, "consumer_cs");
        D3D12_COMPUTE_PIPELINE_STATE_DESC pd = {};
        pd.pRootSignature = root;
        pd.CS = { cs->GetBufferPointer(), cs->GetBufferSize() };
        CHECK(dev12->CreateComputePipelineState(&pd, __uuidof(ID3D12PipelineState), reinterpret_cast<void **>(&pso)));
        SafeRelease(cs);

        D3D12_DESCRIPTOR_HEAP_DESC hd = {};
        hd.Type = D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        hd.NumDescriptors = 2;
        hd.Flags = D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        CHECK(dev12->CreateDescriptorHeap(&hd, __uuidof(ID3D12DescriptorHeap), reinterpret_cast<void **>(&heap)));

        D3D12_HEAP_PROPERTIES hp = {};
        hp.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC rd = TexDesc(D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS);
        CHECK(dev12->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_NONE, &rd, D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                                             nullptr, __uuidof(ID3D12Resource), reinterpret_cast<void **>(&scratch12)));
    }

    D3D12_RESOURCE_DESC TexDesc(D3D12_RESOURCE_FLAGS flags) const
    {
        D3D12_RESOURCE_DESC rd = {};
        rd.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        rd.Width = opt.width; rd.Height = opt.height; rd.DepthOrArraySize = 1; rd.MipLevels = 1;
        rd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; rd.SampleDesc.Count = 1;
        rd.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN; rd.Flags = flags;
        return rd;
    }

    // Shared textures without a UAV bind (the combination D3D11 implementations accept most
    // widely); the consumer writes its private UAV and copies into the shared output.
    void MakeSharedPair(ID3D12Resource **r12, ID3D11Texture2D **t11)
    {
        D3D12_HEAP_PROPERTIES hp = {};
        hp.Type = D3D12_HEAP_TYPE_DEFAULT;
        D3D12_RESOURCE_DESC rd = TexDesc(D3D12_RESOURCE_FLAG_ALLOW_SIMULTANEOUS_ACCESS |
                                         D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET);
        CHECK(dev12->CreateCommittedResource(&hp, D3D12_HEAP_FLAG_SHARED, &rd, D3D12_RESOURCE_STATE_COMMON,
                                             nullptr, __uuidof(ID3D12Resource), reinterpret_cast<void **>(r12)));
        HANDLE h = nullptr;
        CHECK(dev12->CreateSharedHandle(*r12, nullptr, GENERIC_ALL, nullptr, &h));
        ID3D11Device1 *dev1 = nullptr;
        CHECK(dev11->QueryInterface(__uuidof(ID3D11Device1), reinterpret_cast<void **>(&dev1)));
        CHECK(dev1->OpenSharedResource1(h, __uuidof(ID3D11Texture2D), reinterpret_cast<void **>(t11)));
        dev1->Release();
        CloseHandle(h);
    }

    // ---- per-frame pieces -------------------------------------------------------------

    void GamePass(UINT frame)
    {
        const UINT cb[4] = { game_iters, frame, 0, 0 };
        ctx->UpdateSubresource(game_cb, 0, nullptr, cb, 0, 0);
        ctx->CSSetShader(game_cs, nullptr, 0);
        ctx->CSSetConstantBuffers(0, 1, &game_cb);
        ctx->CSSetUnorderedAccessViews(0, 1, &game_uav, nullptr);
        ctx->Dispatch((opt.width + 7) / 8, (opt.height + 7) / 8, 1);
        ID3D11UnorderedAccessView *none = nullptr;
        ctx->CSSetUnorderedAccessViews(0, 1, &none, nullptr);
    }

    static D3D12_RESOURCE_BARRIER Transition(ID3D12Resource *r, D3D12_RESOURCE_STATES a, D3D12_RESOURCE_STATES b)
    {
        D3D12_RESOURCE_BARRIER br = {};
        br.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        br.Transition.pResource   = r;
        br.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        br.Transition.StateBefore = a;
        br.Transition.StateAfter  = b;
        return br;
    }

    // Waits (CPU) until the allocator about to be reused has retired.
    void WaitAllocator(ID3D12Fence *fence, HANDLE ev)
    {
        const UINT64 v = alloc_value[alloc_slot];
        if (v != 0 && fence->GetCompletedValue() < v)
        {
            fence->SetEventOnCompletion(v, ev);
            WaitForSingleObject(ev, 5000);
        }
    }

    // Records and submits the consumer pass: shared input -> private UAV -> shared output.
    void ConsumerPass(UINT frame, bool with_copies)
    {
        CHECK(alloc[alloc_slot]->Reset());
        CHECK(list->Reset(alloc[alloc_slot], pso));
        D3D12_RESOURCE_BARRIER b[2];
        if (with_copies)
        {
            b[0] = Transition(in12, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
            list->ResourceBarrier(1, b);
        }
        list->SetComputeRootSignature(root);
        list->SetDescriptorHeaps(1, &heap);
        list->SetComputeRootDescriptorTable(0, heap->GetGPUDescriptorHandleForHeapStart());
        const UINT c[2] = { consumer_iters, frame };
        list->SetComputeRoot32BitConstants(1, 2, c, 0);
        list->Dispatch((opt.width + 7) / 8, (opt.height + 7) / 8, 1);
        if (with_copies)
        {
            b[0] = Transition(in12, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE, D3D12_RESOURCE_STATE_COMMON);
            b[1] = Transition(scratch12, D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
            list->ResourceBarrier(2, b);
            b[0] = Transition(out12, D3D12_RESOURCE_STATE_COMMON, D3D12_RESOURCE_STATE_COPY_DEST);
            list->ResourceBarrier(1, b);
            list->CopyResource(out12, scratch12);
            b[0] = Transition(out12, D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_COMMON);
            b[1] = Transition(scratch12, D3D12_RESOURCE_STATE_COPY_SOURCE, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
            list->ResourceBarrier(2, b);
        }
        CHECK(list->Close());
        ID3D12CommandList *lists[] = { list };
        queue->ExecuteCommandLists(1, lists);
    }

    void Throttle(int frame)
    {
        // Like a swapchain with max frame latency N: before frame n, frame n-N must be done.
        if (frame >= opt.latency) WaitQuery(throttle[frame % opt.latency]);
    }

    // Spins until an event query has signalled. Asks for the BOOL result explicitly: a
    // NULL/0-byte GetData is allowed by the spec, but not every implementation (DXVK
    // included) treats it as "wait for completion".
    void WaitQuery(ID3D11Query *q)
    {
        BOOL done = FALSE;
        for (;;)
        {
            const HRESULT hr = ctx->GetData(q, &done, sizeof(done), 0);
            if (FAILED(hr)) Die("ID3D11DeviceContext::GetData", hr);
            if (hr == S_OK && done) return;
            YieldProcessor();
        }
    }

    void Drain11()
    {
        ctx->End(drain11);
        ctx->Flush();
        WaitQuery(drain11);
    }

    void DrainOwn()
    {
        const UINT64 v = ++own_value;
        queue->Signal(own_fence, v);
        if (own_fence->GetCompletedValue() < v)
        {
            own_fence->SetEventOnCompletion(v, own_event);
            WaitForSingleObject(own_event, 10000);
        }
    }

    // ---- measurements -----------------------------------------------------------------

    double TimeGameOnly(int frames)
    {
        Drain11();
        const double t0 = NowMs();
        for (int n = 0; n < frames; ++n)
        {
            Throttle(n);
            GamePass(static_cast<UINT>(n));
            ctx->End(throttle[n % opt.latency]);
            ctx->Flush();
        }
        Drain11();
        return (NowMs() - t0) / frames;
    }

    double TimeConsumerOnly(int frames)
    {
        DrainOwn();
        const double t0 = NowMs();
        for (int n = 0; n < frames; ++n)
        {
            alloc_slot = n % kAllocs;
            WaitAllocator(own_fence, own_event);
            ConsumerPass(static_cast<UINT>(n), false);
            queue->Signal(own_fence, ++own_value);
            alloc_value[alloc_slot] = own_value;
        }
        DrainOwn();
        for (auto &v : alloc_value) v = 0;
        return (NowMs() - t0) / frames;
    }

    // Scales *iters (the count time_it measures) until the pass costs about target_ms.
    template <class F> void Calibrate(const char *what, double target_ms, UINT *iters, F time_it)
    {
        double ms = 0.0;
        for (int round = 0; round < 12; ++round)
        {
            ms = time_it();
            if (ms <= 0.0) break;
            const double ratio = target_ms / ms;
            if ((ratio > 0.97 && ratio < 1.03) || round == 11) break;
            // At most 4x per round, so one bad measurement cannot run the next round into a
            // device-removal timeout.
            double next = *iters * (ratio > 4.0 ? 4.0 : ratio);
            if (next < 1) next = 1;
            if (next > 1u << 16) next = 1u << 16;
            *iters = static_cast<UINT>(next);
        }
        Print("  %-9s %5u iterations -> %6.2f ms\n", what, *iters, ms);
    }

    struct Result { double ms_per_frame; double cpu_ms_per_frame; };

    Result RunPipeline(xapi::Mode mode, int frames)
    {
        xapi::D3D11ToD3D12Pipeline pipe;
        CHECK(pipe.Init(dev11, ctx, dev12, queue, mode));
        Drain11();
        DrainOwn();
        for (auto &v : alloc_value) v = 0;

        const int warmup = 30;
        double t0 = 0.0, cpu = 0.0;
        for (int n = 0; n < warmup + frames; ++n)
        {
            if (n == warmup) { t0 = NowMs(); cpu = 0.0; }
            Throttle(n);
            const double c0 = NowMs();

            GamePass(static_cast<UINT>(n));                    // the game's frame n
            const bool carry = pipe.BeginFrame();              // Pipelined: wait for pass n-1
            ctx->CopyResource(in11, game_tex);                 // copy-in n
            if (carry) ctx->CopyResource(home_tex, out11);     // Pipelined: result n-1 goes home
            CHECK(pipe.HandOff());

            alloc_slot = n % kAllocs;
            WaitAllocator(pipe.Fence12(), own_event);
            ConsumerPass(static_cast<UINT>(n), true);
            const bool home_now = pipe.EndFrame(true);
            alloc_value[alloc_slot] = pipe.LastValue();
            if (home_now) ctx->CopyResource(home_tex, out11);  // Serial: result n goes home

            ctx->End(throttle[n % opt.latency]);               // "present"
            ctx->Flush();
            cpu += NowMs() - c0;
        }
        Drain11();
        pipe.Drain();
        const double ms = (NowMs() - t0) / frames;
        for (auto &v : alloc_value) v = 0;
        return { ms, cpu / frames };
    }
};

bool ParseArgs(int argc, char **argv, Options *o)
{
    for (int i = 1; i < argc; i += 2)
    {
        const char *a = argv[i];
        const char *v = i + 1 < argc ? argv[i + 1] : nullptr;
        if (v == nullptr) return false;
        if      (!strcmp(a, "--game-ms"))     o->game_ms     = atof(v);
        else if (!strcmp(a, "--consumer-ms")) o->consumer_ms = atof(v);
        else if (!strcmp(a, "--frames"))      o->frames      = atoi(v);
        else if (!strcmp(a, "--width"))       o->width       = static_cast<UINT>(atoi(v));
        else if (!strcmp(a, "--height"))      o->height      = static_cast<UINT>(atoi(v));
        else if (!strcmp(a, "--latency"))     o->latency     = atoi(v);
        else if (!strcmp(a, "--adapter"))     o->adapter     = static_cast<UINT>(atoi(v));
        else return false;
    }
    if (o->latency < 1) o->latency = 1;
    if (o->latency > 8) o->latency = 8;
    return o->frames > 0 && o->width > 0 && o->height > 0 && o->game_ms > 0 && o->consumer_ms > 0;
}

} // namespace

int main(int argc, char **argv)
{
    char path[MAX_PATH] = {};
    GetModuleFileNameA(nullptr, path, MAX_PATH);
    if (char *slash = strrchr(path, '\\')) strcpy(slash + 1, "xapi_bench_results.txt");
    g_out = fopen(path, "w");

    Bench b;
    if (!ParseArgs(argc, argv, &b.opt))
    {
        Print("usage: xapi_bench.exe [--game-ms 5] [--consumer-ms 7] [--frames 600] [--width 2560] "
              "[--height 1440] [--latency 2] [--adapter 0]\n");
        return 2;
    }
    b.Init();
    Print("%ux%u, latency %d, %d frames per run\n", b.opt.width, b.opt.height, b.opt.latency, b.opt.frames);

    Print("calibrating (GPU-bound, each side alone):\n");
    b.Calibrate("game", b.opt.game_ms, &b.game_iters, [&] { return b.TimeGameOnly(60); });
    b.Calibrate("consumer", b.opt.consumer_ms, &b.consumer_iters, [&] { return b.TimeConsumerOnly(60); });
    Print("measuring each side alone...\n");
    const double game_ms     = b.TimeGameOnly(b.opt.frames / 2);
    const double consumer_ms = b.TimeConsumerOnly(b.opt.frames / 2);

    Print("running Serial...\n");
    const auto serial    = b.RunPipeline(xapi::Mode::Serial, b.opt.frames);
    Print("running Pipelined...\n");
    const auto pipelined = b.RunPipeline(xapi::Mode::Pipelined, b.opt.frames);

    const double sum = game_ms + consumer_ms;
    Print("\n%-34s %8s %8s\n", "", "ms/frame", "fps");
    Print("%-34s %8.2f %8.1f\n", "game pass alone (D3D11)", game_ms, 1000.0 / game_ms);
    Print("%-34s %8.2f %8.1f\n", "consumer pass alone (D3D12)", consumer_ms, 1000.0 / consumer_ms);
    Print("%-34s %8.2f %8.1f\n", "sum of both (no overlap, no stall)", sum, 1000.0 / sum);
    Print("%-34s %8.2f %8.1f   CPU %.2f ms/frame\n", "Serial    (result n home in n)", serial.ms_per_frame,
          1000.0 / serial.ms_per_frame, serial.cpu_ms_per_frame);
    Print("%-34s %8.2f %8.1f   CPU %.2f ms/frame\n", "Pipelined (result n-1 home in n)", pipelined.ms_per_frame,
          1000.0 / pipelined.ms_per_frame, pipelined.cpu_ms_per_frame);
    Print("\nhandoff overhead, Serial:    %+.2f ms/frame over the sum\n", serial.ms_per_frame - sum);
    Print("handoff overhead, Pipelined: %+.2f ms/frame over the sum\n", pipelined.ms_per_frame - sum);
    Print("Pipelined speed-up: %.2fx\n", serial.ms_per_frame / pipelined.ms_per_frame);

    if (g_out != nullptr) fclose(g_out);
    return 0;
}
