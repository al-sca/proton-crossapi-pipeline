#!/usr/bin/env python3
"""Summarises one bench.sh recording as key=value lines on stdout.

    analyze.py <raw dir> <start epoch> <end epoch> <ReShade.log> <dlss5-feed.log>

Frame rate and frame times come from the RenoDX DLSS 5 add-on's telemetry in ReShade.log (one
line per 30 s window); only windows entirely inside the recording count. The Feeder's own
"600 frames" lines add its CPU/GPU cost and are the frame-rate fallback when RenoDX did not log.
GPU utilisation comes from gpu.csv, per-thread CPU from threads.txt (both written by bench.sh).
The matching log lines are copied into the raw dir for reference.
"""
import datetime as dt
import os
import re
import statistics as st
import sys

raw, t0, t1, reshade_log, feed_log = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5]
day0 = dt.datetime.fromtimestamp(t0)


def epoch_of(h, m, s, ms):
    """Log lines carry only a time of day; place it on the day nearest the recording."""
    t = day0.replace(hour=int(h), minute=int(m), second=int(s), microsecond=int(ms) * 1000)
    e = t.timestamp()
    if e < t0 - 43200:
        e += 86400
    elif e > t0 + 43200:
        e -= 86400
    return e


def lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            yield from f
    except OSError:
        return


out = {}

# --- RenoDX telemetry --------------------------------------------------------------------
tel_re = re.compile(r"^(\d\d):(\d\d):(\d\d):(\d{3}) .*telemetry t=[\d.]+s win=([\d.]+)s presents=(\d+) "
                    r"ticks=\d+ fps=([\d.]+) frame_ms\[avg=([\d.]+) p50=([\d.]+) p99=([\d.]+) max=([\d.]+)\]"
                    r"(?: nr\[evals=(\d+))?")
wins, keep = [], []
for ln in lines(reshade_log):
    m = tel_re.search(ln)
    if not m:
        continue
    end = epoch_of(*m.group(1, 2, 3, 4))
    win = float(m.group(5))
    if end - win >= t0 - 1 and end <= t1 + 2:
        presents = int(m.group(6))
        evals = int(m.group(12)) if m.group(12) else None
        wins.append(dict(win=win, presents=presents, fps=float(m.group(7)), p50=float(m.group(9)),
                         p99=float(m.group(10)), max=float(m.group(11)), evals=evals))
        keep.append(ln[: ln.find("] nr[") + 1] if "] nr[" in ln else ln.rstrip())
with open(os.path.join(raw, "telemetry.txt"), "w") as f:
    f.write("\n".join(keep) + ("\n" if keep else ""))

# --- Feeder 600-frame stats and stalls ---------------------------------------------------
feed_re = re.compile(r"^(\d\d):(\d\d):(\d\d)\.(\d{3})\s+\[feed\] (\d+) frames: feed CPU ([\d.]+) ms/frame \| "
                     r"frame interval ([\d.]+) ms \(([\d.]+) fps\).*?feed GPU ([\d.]+) ms/frame")
stall_re = re.compile(r"^(\d\d):(\d\d):(\d\d)\.(\d{3})\s+\[feed\] STALL frame")
feeds, stalls, fkeep = [], 0, []
for ln in lines(feed_log):
    m = feed_re.search(ln)
    if m:
        end = epoch_of(*m.group(1, 2, 3, 4))
        span = int(m.group(5)) * float(m.group(7)) / 1000.0
        if end - span >= t0 - 1 and end <= t1 + 2:
            feeds.append(dict(cpu=float(m.group(6)), interval=float(m.group(7)), fps=float(m.group(8)),
                              gpu=float(m.group(9))))
            fkeep.append(ln.rstrip())
        continue
    m = stall_re.search(ln)
    if m and t0 <= epoch_of(*m.group(1, 2, 3, 4)) <= t1 + 2:
        stalls += 1
        fkeep.append(ln.rstrip())
with open(os.path.join(raw, "feed.txt"), "w") as f:
    f.write("\n".join(fkeep) + ("\n" if fkeep else ""))

if wins:
    total_t = sum(w["win"] for w in wins)
    out["fps"] = f"{sum(w['presents'] for w in wins) / total_t:.1f}"
    out["frame_p50_ms"] = f"{st.mean(w['p50'] for w in wins):.2f}"
    out["frame_p99_ms"] = f"{st.mean(w['p99'] for w in wins):.2f}"
    out["frame_max_ms"] = f"{max(w['max'] for w in wins):.1f}"
    out["fps_source"] = f"RenoDX telemetry, {len(wins)} x {wins[0]['win']:.0f} s windows"
    ev = [w for w in wins if w["evals"] is not None]
    if ev:
        on = [w["evals"] >= 0.5 * w["presents"] for w in ev]
        out["dlss5"] = "on" if all(on) else "off" if not any(on) else "mixed"
elif feeds:
    out["fps"] = f"{1000.0 / st.mean(f['interval'] for f in feeds):.1f}"
    out["frame_avg_ms"] = f"{st.mean(f['interval'] for f in feeds):.2f}"
    out["fps_source"] = f"Feeder stats, {len(feeds)} x 600 frames (no RenoDX telemetry)"
else:
    out["fps_source"] = "none -- no telemetry inside the recording (record longer than 60 s)"
if feeds:
    out["feed_gpu_ms"] = f"{st.mean(f['gpu'] for f in feeds):.2f}"
    out["feed_cpu_ms"] = f"{st.mean(f['cpu'] for f in feeds):.2f}"
out["stalls"] = str(stalls)

# --- GPU ---------------------------------------------------------------------------------
util, power = [], []
for ln in lines(os.path.join(raw, "gpu.csv")):
    p = [x.strip() for x in ln.split(",")]
    try:
        util.append(float(p[1]))
        if len(p) > 2 and p[2] not in ("", "[N/A]"):
            power.append(float(p[2]))
    except (ValueError, IndexError):
        pass
if util:
    out["gpu_util"] = f"{st.mean(util):.0f}"
if power:
    out["gpu_power_w"] = f"{st.mean(power):.0f}"

# --- CPU threads (top -H blocks; %CPU 100 = one core) ------------------------------------
blocks, cur = [], None
for ln in lines(os.path.join(raw, "threads.txt")):
    if ln.startswith("top - "):
        cur = {}
        blocks.append(cur)
        continue
    p = ln.split()
    if cur is not None and len(p) >= 12 and p[0].isdigit():
        try:
            cur[f"{p[0]} {' '.join(p[11:])}"] = float(p[8].replace(",", "."))
        except ValueError:
            pass
blocks = blocks[1:] or blocks   # top's first sample covers the time before the recording
if blocks:
    acc = {}
    for b in blocks:
        for k, v in b.items():
            acc.setdefault(k, []).append(v)
    k = max(acc, key=lambda k: sum(acc[k]) / len(blocks))
    out["top_thread"] = k.split(" ", 1)[1]
    out["top_thread_avg"] = f"{sum(acc[k]) / len(blocks):.0f}"
    out["top_thread_max"] = f"{max(acc[k]):.0f}"
    out["process_cpu"] = f"{st.mean(sum(b.values()) for b in blocks):.0f}"

for k, v in out.items():
    print(f"{k}={v}")
