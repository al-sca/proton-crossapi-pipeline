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

More games are in [Game results](#game-results).

## Quick start: use it for your game

From a fresh clone to a before/after benchmark of one Steam game. Everything below goes into one
folder, `~/src` here. Nothing is installed system-wide apart from the packages in step 0 and
`xwin` in `~/.cargo/bin`.

```
~/src/
├── proton-crossapi-pipeline/   this repo: the scripts, and build/dlss5-feed.addon64 at the end
├── DLSS5-Feeder/               the add-on's source, with the patch applied
├── NVIDIA-DLSS/                NVIDIA's DLSS SDK: the NGX headers and import library
├── Vulkan-Headers/             Khronos Vulkan headers
└── xwin-splat/                 Microsoft's C runtime and Windows SDK, for cross-compiling
```

**You need:** Linux, Steam with Proton, an NVIDIA RTX GPU that runs DLSS 5, and a **D3D11** game.
After step 4, `tools/game/status.sh` tells you whether the patch applies to your game.

### 0. Packages

| Tool | Arch / CachyOS | Debian / Ubuntu | Fedora |
|---|---|---|---|
| `git`, `python3`, `cargo` | `git python rust` | `git python3 cargo` | `git python3 cargo` |
| `clang-cl`, `lld-link`, `llvm-rc` | `clang lld llvm` | `clang lld llvm` | `clang lld llvm` |
| `protontricks` (or its Flatpak) | `protontricks` (AUR) | `protontricks` | `protontricks` |
| `uv` (runs dlss5-enabler) | `uv` | [installer](https://docs.astral.sh/uv/getting-started/installation/) | `uv` |

On Debian/Ubuntu the LLVM tools may carry a version suffix (`clang-cl-19`). If so, link them
under the plain names, e.g. `sudo ln -s /usr/bin/clang-cl-19 /usr/local/bin/clang-cl`, and do
the same for `lld-link` and `llvm-rc`. `nvidia-smi` comes with the NVIDIA driver.

### 1. Get the sources

```sh
mkdir -p ~/src && cd ~/src
git clone https://github.com/al-sca/proton-crossapi-pipeline

# DLSS5-Feeder at the commit the patch was made for (1.19.0), then the patch on top
git clone https://github.com/jlrouzies-fr/DLSS5-Feeder
cd DLSS5-Feeder
git checkout 34edfe16626d52a8f66c5996c58d5b7c982d3023
git am ../proton-crossapi-pipeline/patches/dlss5-feeder/*.patch
cd ..
```

`git am` makes a commit, so git needs a name and an email. If it complains, run
`git config --global user.name "..."` and `git config --global user.email "..."` once, then
`git am --abort`, then repeat the `git am` line.

### 2. Put the NVIDIA and Vulkan headers into DLSS5-Feeder

DLSS5-Feeder doesn't ship these two dependencies. Its build expects them in `external/ngx/`
and `external/vulkan/`. Download them (about 45 MB each; the sparse clone fetches only the two
folders needed from NVIDIA's 1.4 GB repository):

```sh
cd ~/src
git clone --depth 1 --filter=blob:none --sparse https://github.com/NVIDIA/DLSS NVIDIA-DLSS
git -C NVIDIA-DLSS sparse-checkout set include lib/Windows_x86_64/x64
git clone --depth 1 https://github.com/KhronosGroup/Vulkan-Headers
```

Copy exactly these files. `mkdir -p` creates the folders that don't exist yet:

```sh
cd ~/src/DLSS5-Feeder
mkdir -p external/ngx/libs external/vulkan/vulkan external/vulkan/vk_video

# NVIDIA: all NGX headers, and the release import library (x64, /MD; not the _dbg or _s ones)
cp ../NVIDIA-DLSS/include/*.h                            external/ngx/
cp ../NVIDIA-DLSS/lib/Windows_x86_64/x64/nvsdk_ngx_d.lib external/ngx/libs/

# Khronos: the Vulkan headers and their video sub-headers
cp ../Vulkan-Headers/include/vulkan/*.h   external/vulkan/vulkan/
cp ../Vulkan-Headers/include/vk_video/*.h external/vulkan/vk_video/
```

To check, list these three files. All must exist; if one is missing, the build stops and names it:

```sh
ls external/ngx/nvsdk_ngx.h external/ngx/libs/nvsdk_ngx_d.lib external/vulkan/vulkan/vulkan_core.h
```

NVIDIA's SDK is under NVIDIA's license and the Vulkan headers under Apache-2.0. Don't commit
them to this repo or to DLSS5-Feeder; they stay in your local copy.

### 3. Build the patched add-on

The add-on is a Windows DLL. `xwin` downloads Microsoft's C runtime and Windows SDK so that
clang can build it on Linux. The `--accept-license` flag accepts Microsoft's license. The
download takes about 1.1 GB in `~/src/.xwin-cache`, which you can delete afterwards; the
result in `~/src/xwin-splat` is about 630 MB.

```sh
cd ~/src
cargo install xwin --locked
~/.cargo/bin/xwin --accept-license --arch x86_64 splat --output ~/src/xwin-splat

~/src/proton-crossapi-pipeline/tools/build-dlss5-feeder.sh ~/src/DLSS5-Feeder ~/src/xwin-splat
```

It ends with `built build/dlss5-feed.addon64 (<commit>)` and
`copied to ~/src/proton-crossapi-pipeline/build/dlss5-feed.addon64`. Compiler warnings along
the way are normal. The scripts below take the add-on from that `build/` folder.

### 4. Set up the game

Find the game's **Steam app id**: it's the number in its store URL, or run `protontricks -l`.
Start the game once through Steam so its Proton prefix exists, then quit it. Then run:

```sh
cd ~/src/proton-crossapi-pipeline
tools/game/setup.sh <appid>
```

- If the game has no DLSS 5 yet, `setup.sh` lists the game's `.exe` candidates. Run it again
  with `--exe "/path/to/Game.exe"` and it installs DLSS 5 with `uvx dlss5-enabler@latest install`.
- It installs `d3dcompiler_47` into the prefix with protontricks, keeps the official add-on as
  `dlss5-feed.addon64.official.bak`, installs the patched one, and sets `async_home=1`.
- It ends with the game's status. If it reports **no native override**, copy the
  `WINEDLLOVERRIDES="..." %command%` line it prints into Steam > the game > Properties >
  Launch Options.
- Start the game once with DLSS 5, then quit. `tools/game/status.sh <appid>` should now say
  **`D3D11 cross-API -- the patch applies`**. With any other transport, the patch changes nothing.

### 5. Benchmark

```sh
tools/game/bench.sh <appid>
```

1. The script starts the game through Steam, with the patched add-on already in place.
2. Load a save and go to a spot where you can stand still. Wait until shader compilation and
   streaming have settled, then press **Enter** in the terminal.
3. Switch back to the game within 10 s and **stand still**. No pause menu, no alt-tab.
4. It records 45 s with `async_home=0` (the official code path), then 45 s with
   `async_home=1`, in the same session and scene. A sound marks each start and end; a bell
   means it's done.

The summaries land in `results/games/<game>/before.txt` and `after.txt`, and the table under
[Game results](#game-results) is rebuilt. `--tag <name>` stores another scene as a separate pair.

The fix stays on afterwards. `tools/game/disable.sh <appid> --official` puts the official
add-on back. To share a result, commit `results/games/<game>/*.txt` and `README.md`, then open
a pull request. The raw recordings in `results/games/*/raw/` stay local.

**If bench.sh stops with an error**

| Message | Meaning, and what to do |
|---|---|
| the running game loaded Feeder ..., not the patched build | The game was already running when the add-on was replaced. Quit it and run `bench.sh` again. |
| the game has DLSS5-Feeder X, the patched build is Y | dlss5-enabler installed a newer Feeder. The patch must be rebased onto that version and rebuilt. |
| the Feeder did not pick up async_home=... within 30 s | The game was paused, minimised or in a menu. Stay in the game while it records. |
| ⚠ after run sits at the game's 60 fps cap (in the results table) | The game's own frame cap limits the result, not the GPU. The gain shown is the most the cap allows. |

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

Step by step, with every download and copy: [Quick start](#quick-start-use-it-for-your-game).

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
