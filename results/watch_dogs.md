# Watch Dogs (2014) + DLSS 5 via DLSS5-Feeder

The game that surfaced the problem. All runs at the same spot in the city, 2560x1440, the
game's own settings unchanged between runs.

## System

| | |
|---|---|
| GPU | NVIDIA GeForce RTX 5070 Ti (16 GB), driver 610.57.04 |
| CPU | AMD Ryzen 7 7800X3D (8 cores) |
| OS | CachyOS, Linux 7.2, KDE Plasma (Wayland), 75 Hz monitor without VRR |
| Proton | Proton Experimental (11.0-100), DXVK v3.1.1-97, vkd3d-proton |
| Stack | ReShade 6.8.0 (`dxgi.dll`), DLSS5-Feeder 1.19.0 (D3D11 cross-API transport), RenoDX DLSS 5 add-on 8.5.0-rc10, LumeniteFX motion vectors |

## Before: official DLSS5-Feeder 1.19.0

| | DLSS 5 on | DLSS 5 off (F6) |
|---|---|---|
| fps | 48–50 | 73–77 (held at ~75) |
| frame time p50 / p99 | 22.5 / 25–28 ms | 13.5 ms |
| GPU utilisation (nvidia-smi) | 61 % (210 W) | 40 % (133 W) |
| busiest CPU thread (avg / peak) | 15 % / 20 % of one core | 21 % / 29 % |
| DXVK HUD `gpuload` | 100 % | |

- No CPU thread anywhere near saturation, the GPU idle ~40 % of the time.
- DXVK's HUD says 100 % while nvidia-smi says ~60 %: DXVK counts its queue as busy while it
  sits blocked on the cross-device semaphore.
- Frame time added by DLSS 5 (~7 ms) equals its GPU cost (7.2 ms): nothing overlaps.
- DXVK frame-time graph alternates between ~12.5 ms and ~23 ms frames; present mode was
  `VK_PRESENT_MODE_IMMEDIATE_KHR`, so this is not v-sync quantisation.
- `async_home=1` had no effect: in 1.19.0 it only applies to the Vulkan transport.
- Lowering the DLSS 5 resolution scale to 0.85 removed 1.4 ms of GPU work but only ~0.7 ms of
  frame time.

## After: DLSS5-Feeder + `patches/dlss5-feeder` with `async_home=1`

| | DLSS 5 on | DLSS 5 off (F6) |
|---|---|---|
| fps | **71–72** (up to 96 in lighter views) | **~175** |
| frame time p50 / p99 | **13.75–14.25 / ~17 ms** | 5.75 ms |
| GPU utilisation (nvidia-smi) | **98 %** (289 W) | 95 % (246 W) |
| long frames in gameplay | 1 (52 ms) | |

- No visual artifacts, flashing, stale frames or HUD lag observed by the player; no tearing
  visible at ~175 fps on the 75 Hz panel (KDE compositor, borderless).
- The DLSS 5 add-on's own "NR cost" meter rises from 7.2 to ~12 ms. That is not a slowdown:
  its GPU timestamps now span time-sliced work of the game running at the same moment.
- With DLSS 5 off the game left its old ~75 fps ceiling, without any setting changing. The
  ceiling apparently came from the synchronous handoff (the DLAA pass of the feeder still
  runs with DLSS 5 off), not from the monitor. The exact mechanism is not pinned down.
