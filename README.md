# proton-crossapi-pipeline

Mods and add-ons that hand every frame of a **D3D11 game** to their own **D3D12 device** (DLSS
or DLSS 5 bridges, NGX feeders, upscalers, denoisers, frame processors) and bring the result
back **in the same frame** lose a large part of the GPU under Wine/Proton. This repo explains
why, shows how to recognise it, and provides the fix: a small header-only library, a
benchmark that reproduces the problem without any game, and a ready patch for
[DLSS5-Feeder](https://github.com/jlrouzies-fr/DLSS5-Feeder).

| Measured on RTX 5070 Ti, Proton Experimental | Same-frame handoff | Pipelined handoff |
|---|---|---|
| Watch Dogs + DLSS 5 (DLSS5-Feeder), 1440p | 48–50 fps, GPU 61 % | **71–72 fps, GPU 98 %** |
| `xapi_bench`, 5 ms game + 7 ms consumer pass | 53.8–56.2 fps | **79.8–80.4 fps** |
| `xapi_bench`, 8 ms game + 3 ms consumer pass | 53.8 fps | **87.8 fps** |

## The problem

```
D3D11 (game) : [game frame n][copy-in][Signal] ........ Wait(result n) [copy home n][present]
D3D12 (mod)  :                           [Wait][   consumer pass on n   ][Signal]
```

The game's queue sits idle for the whole consumer pass, every frame. On Windows that costs
"only" the lost overlap. Under Proton it is much worse: the D3D11 device is DXVK and the D3D12
device is vkd3d-proton, which are **two separate VkDevices**, i.e. two separate GPU contexts
joined by a shared timeline semaphore. Both cross-device waits sit on the frame's critical
path, and in the benchmark they add a **further 5.8–7.5 ms per frame** on top of the two
passes. That is pure waiting, with neither the GPU nor the CPU doing anything.

### How to tell you have it

- Frame time ≈ game + mod GPU cost + several ms, and lowering the mod's quality barely helps.
- GPU utilisation (`nvidia-smi`, MangoHud) well below 100 %, and **no CPU thread near 100 %**
  either. Use `tools/record-game.sh` to check per-thread CPU and GPU usage together.
- `DXVK_HUD=gpuload` reports ~100 % while `nvidia-smi` reports ~60 %. DXVK counts its queue as
  busy while it is blocked on the semaphore.
- DXVK's frame-time graph flips between short and long frames, with
  `VK_PRESENT_MODE_IMMEDIATE_KHR` in the DXVK log (so it is not v-sync).

## The fix: carry frame n-1 home

```
D3D11 (game) : [game n] Wait(result n-1) [copy-in n][copy home n-1][Signal n][present] [game n+1] ...
D3D12 (mod)  :                                                        [Wait][consumer n] <- overlaps game n+1
```

Three rules keep it correct with a **single** set of shared textures:

1. **Wait before overwriting the inputs.** The D3D11 queue waits (GPU-side) for pass n-1 right
   before the copy-in of frame n. By then pass n-1 has normally finished, so the wait is free.
   It also keeps the shared fence monotonic: the next D3D11 Signal can never overtake the
   D3D12 Signal it follows.
2. **Copy home before the Signal.** The copy of result n-1 into the backbuffer is recorded
   before the Signal that hands the shared output back to D3D12 for pass n.
3. **A pass that ran is always owed its wait**, even when its output is discarded (failed
   evaluate). On a resize or rebuild, drain on the CPU and forget the pending value: a fresh
   fence would otherwise be waited on for a value it never reaches.

The cost is **one frame of latency**. In Watch Dogs it was not noticeable, and there were no
artifacts: the whole image, HUD included, is consistently one frame old.

Under Proton the two contexts do not run truly in parallel. They take turns on the GPU, so
pipelined lands near the *sum* of both passes, not the maximum. The gain comes from removing
the waiting between them.

## What's in here

| Path | What |
|---|---|
| `include/crossapi_pipeline.h` | Header-only `xapi::D3D11ToD3D12Pipeline`: shared-fence setup, `BeginFrame` / `HandOff` / `EndFrame`, `Serial` and `Pipelined` modes, CPU fallback when a D3D11 cross-API wait is refused |
| `bench/xapi_bench.cpp` | Headless benchmark: a D3D11 "game" pass and a D3D12 "consumer" pass, each calibrated to a target GPU time, joined like a real add-on (shared textures, shared fence), measured Serial vs Pipelined |
| `patches/dlss5-feeder/` | The fix applied to DLSS5-Feeder 1.19.0's D3D11 transport, enabled with `async_home=1` |
| `tools/game/` | Per-game scripts: `setup.sh`, `enable.sh`, `disable.sh`, `status.sh`, `bench.sh` (before/after benchmark), `report.sh` (results table below) |
| `tools/record-game.sh` | Per-thread CPU and GPU recorder for a running Proton game: is it CPU-bound or waiting? |
| `tools/build-bench.sh`, `tools/build-dlss5-feeder.sh` | Cross-compile both on Linux (clang-cl + lld-link + xwin) |
| `results/` | Benchmark output: `xapi_bench/`, `games/<game>/` from `bench.sh`, the Watch Dogs write-up |

### Using the library

```cpp
#include "crossapi_pipeline.h"

xapi::D3D11ToD3D12Pipeline pipe;
pipe.Init(dev11, immediate_ctx, dev12, queue12, xapi::Mode::Pipelined);

// every frame, on the D3D11 immediate context, after the game rendered frame n:
const bool carry = pipe.BeginFrame();                  // GPU-side wait for pass n-1
ctx->CopyResource(shared_in11, game_frame);            // copy-in n
if (carry) blit(shared_out11 -> backbuffer);           // result n-1 goes home
pipe.HandOff();                                        // D3D11 Signal + Flush, D3D12 Wait
queue12->ExecuteCommandLists(...);                     // consumer pass on n
if (pipe.EndFrame(/*output_valid=*/ok))                // D3D12 Signal
    blit(shared_out11 -> backbuffer);                  // Serial mode only: result n now

// before resizing or recreating the shared textures:
pipe.Drain();
```

`Mode::Serial` is the classic same-frame behaviour, useful for A/B testing and as a fallback.

### Running the benchmark

```sh
tools/build-bench.sh /path/to/xwin-splat      # -> build/xapi_bench.exe
STEAM_COMPAT_DATA_PATH=/tmp/xapi-pfx \
STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam" \
"$HOME/.local/share/Steam/steamapps/common/Proton - Experimental/proton" \
  run build/xapi_bench.exe --game-ms 5 --consumer-ms 7
```

Options: `--game-ms`, `--consumer-ms` (target GPU time of each pass), `--frames`, `--width`,
`--height`, `--latency` (frames the CPU may run ahead), `--adapter`. Results go to stdout and
to `xapi_bench_results.txt` next to the exe. It runs on Windows too, which makes a useful
comparison. Please contribute results from other GPUs, drivers and Proton versions to
`results/`.

### Applying the DLSS5-Feeder patch

```sh
git clone https://github.com/jlrouzies-fr/DLSS5-Feeder && cd DLSS5-Feeder
git am /path/to/proton-crossapi-pipeline/patches/dlss5-feeder/*.patch
# add the NGX SDK and Vulkan headers as described in external/ngx/README.md and external/vulkan/README.md
/path/to/proton-crossapi-pipeline/tools/build-dlss5-feeder.sh . /path/to/xwin-splat
```

Then replace the game's `dlss5-feed.addon64` with `build/dlss5-feed.addon64` (keep a backup)
and set `async_home=1` in `dlss5-feed.cfg`. The first line of `dlss5-feed.log` shows the build
id, and the log says `async_home (D3D11): the blit carries frame n-1 ...` once it is active.

## Testing a game

The scripts in `tools/game/` take the game's **Steam app id** (the number in its store URL, or
`protontricks -l`). They find the install, the Proton prefix and the DLSS 5 files on their own.

```sh
tools/game/setup.sh 307690                 # once: d3dcompiler_47, patched Feeder, async_home=1, checks
tools/game/bench.sh 307690                 # before/after benchmark, updates the table below
tools/game/status.sh 307690                # what is installed and set
tools/game/disable.sh 307690 [--official]  # async_home=0 (--official: also put the official add-on back)
tools/game/enable.sh 307690                # patched add-on + async_home=1
```

- **`setup.sh`** installs `d3dcompiler_47` with protontricks (skipped if it is already there),
  installs the patched add-on with `async_home=1`, and shows what is still missing, such as a
  launch-option DLL override. If the game has no DLSS 5 yet, `--exe <game.exe>` runs
  `uvx dlss5-enabler@latest install` for it first. Without `--exe` it lists exe candidates.
- **`enable.sh`** keeps the official add-on as `dlss5-feed.addon64.official.bak` and refuses to
  install the patched build on top of a different Feeder version (`--force` overrides). The
  patched build comes from `build/dlss5-feed.addon64`, which `tools/build-dlss5-feeder.sh`
  writes, or from `$XAPI_ADDON`.
- **`bench.sh`** runs "before" (`async_home=0`) and "after" (`async_home=1`) **in one game
  session**. The Feeder re-reads `dlss5-feed.cfg` every 60 frames and rebuilds when
  `async_home` changes, so the script flips it while you stand at the test spot: no restart,
  same scene for both runs. With `async_home=0` the patched add-on runs exactly the official
  code path. It starts the game through Steam if needed and waits for you to press Enter;
  switch back to the game within 10 s and stand still (no pause, no menu). Per run it waits
  until the Feeder has applied the switch, lets it settle, starts at a fresh telemetry window,
  and records 45 s; a sound marks each start and end. Frame rate and frame times come from the
  RenoDX DLSS 5 add-on's 30 s telemetry in `ReShade.log` and the Feeder's own stats, GPU from
  `nvidia-smi`, CPU threads from `top`, so no launch options or overlays are needed. Options:
  `before|after` for a single run, `--tag dlss-off` (DLSS 5 toggled off in game, F6) or
  `--tag city` for more pairs, `--seconds`, `--delay`, `--no-launch`, `--no-prompt`.
- **`report.sh`** prints the comparison for a game and rewrites the table below from every
  `results/games/*/before*.txt` + `after*.txt` pair. Summaries are committed, the raw recordings
  (`results/games/*/raw/`) are git-ignored.

## Game results

All on the machine in [Limits](#limits-and-open-questions) unless the game's folder says
otherwise. Change = after fps / before fps.

<!-- games:begin -->
| Game | Resolution | DLSS 5 | Before (`async_home=0`) | After (`async_home=1`) | Change | Date |
|---|---|---|---|---|---|---|
| [DARK SOULS™ II: Scholar of the First Sin](results/games/dark_souls_ii_scholar_of_the_first_sin/) | 2560x1440 | on | 54.5 fps, p50 20.00 ms, GPU 53 % | 60.0 fps, p50 16.75 ms, GPU 60 % | **1.10x** ⚠ after run sits at the game's 60 fps cap (GPU 60 %) | 2026-10-21 |
| [DARK SOULS™ III](results/games/dark_souls_iii/) | 2560x1440 | on | 49.1 fps, p50 22.25 ms, GPU 58 % | 77.5 fps, p50 13.00 ms, GPU 98 % | **1.58x** | 2026-10-21 |
| [DARK SOULS™: REMASTERED](results/games/dark_souls_remastered/) | 2560x1440 | on | 55.0 fps, p50 20.00 ms, GPU 52 % | 97.6 fps, p50 10.25 ms, GPU 98 % | **1.77x** | 2026-10-21 |
| [STAR WARS Jedi: Fallen Order™](results/games/jedi_fallen_order/) | 2560x1440 | on | 46.0 fps, p50 23.25 ms, GPU 59 % | 71.9 fps, p50 14.00 ms, GPU 98 % | **1.56x** | 2026-10-21 |
| [Sleeping Dogs: Definitive Edition](results/games/sleepingdogsdefinitiveedition/) | 2560x1440 | on | 53.5 fps, p50 21.25 ms, GPU 59 % | 86.6 fps, p50 11.75 ms, GPU 98 % | **1.62x** | 2026-10-21 |
| [Watch_Dogs](results/games/watch_dogs/) | 2560x1440 | on | 49.0 fps, p50 22.50 ms, GPU 61 % | 71.5 fps, p50 14.00 ms, GPU 98 % | **1.46x** | 2026-10-16 |
<!-- games:end -->

## Building on Linux

Needs `clang-cl`, `lld-link`, `llvm-rc` (LLVM) and the MSVC CRT + Windows SDK, fetched with
[xwin](https://github.com/Jake-Shadle/xwin). This requires accepting Microsoft's license:

```sh
cargo install xwin --locked
xwin --accept-license --arch x86_64 splat --output /path/to/xwin-splat
```

The DLSS5-Feeder build also needs NVIDIA's DLSS SDK (https://github.com/NVIDIA/DLSS, NVIDIA's
license) and the Khronos Vulkan headers. Neither is redistributed here.

## Limits and open questions

- Measured on one machine so far: RTX 5070 Ti, NVIDIA 610.57.04, Proton Experimental 11.0-100,
  DXVK 3.1.1-97. AMD/Intel, other drivers and native Windows are untested.
- Serial mode took exactly 18.59 ms in two benchmark profiles with different pass costs
  (11.95 ms and 11.10 ms of real work). That points at a fixed latency in the cross-device
  fence path (DXVK ↔ vkd3d-proton ↔ driver), which is not pinned down yet. Fixing it upstream
  would help every serial user, but pipelining hides it regardless.
- In Watch Dogs, the game's old ~75 fps ceiling with DLSS 5 *off* also disappeared (~175 fps).
  The feeder's DLAA pass still runs synchronously then, so the same stall was capping it.
- The pattern is the same for the other direction (a D3D12 game feeding a D3D11/Vulkan
  consumer) and for Vulkan-to-D3D12 bridges, but only D3D11 → D3D12 is implemented here.

## License

MIT, see `LICENSE`. The DLSS5-Feeder patch is offered under DLSS5-Feeder's MIT license.
