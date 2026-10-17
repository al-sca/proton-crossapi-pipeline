#!/usr/bin/env bash
# Records per-thread CPU (1 s) and NVIDIA GPU usage (0.5 s) of a Proton/Wine game until it
# exits. Start it before (or while) launching the game.
#
#   tools/record-game.sh 'watch_dogs\.exe' ./rec-watchdogs
#
# The first argument is a regex for the game's Windows exe as it appears in the command line.
# Under Proton the process name (comm) is renamed after the game's main thread, so the
# command line is what is matched; Steam/Proton wrapper processes that carry the exe path as
# an argument are skipped, and so are launcher stubs that exit within 30 s.
#
# Afterwards: a thread pegged near 100 % means CPU-bound; every thread well below that while
# the GPU also sits well below 100 % means the frame is waiting on synchronisation.
set -u
EXE_RE="${1:?regex for the game exe, e.g. 'watch_dogs\.exe'}"
OUT="${2:?output dir}"
mkdir -p "$OUT"

find_game() {
  local p cmd
  for p in $(pgrep -f -i "$EXE_RE"); do
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null) || continue
    case "$cmd" in *steam.exe*|*reaper*|*srt-bwrap*|*pv-adverb*|*proton*|*python*|*pgrep*|*record-game*) continue ;; esac
    [ "$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')" -ge 30 ] 2>/dev/null && { echo "$p"; return; }
  done
}

echo "waiting for a process matching '$EXE_RE' ..."
until PID=$(find_game); [ -n "$PID" ]; do sleep 2; done
tr '\0' ' ' < "/proc/$PID/cmdline" > "$OUT/cmdline.txt"
echo "game pid $PID, recording to $OUT"

GPU_PID=""
if command -v nvidia-smi >/dev/null; then
  nvidia-smi --query-gpu=timestamp,utilization.gpu,clocks.gr,power.draw,memory.used \
    --format=csv,noheader -lms 500 > "$OUT/gpu.csv" &
  GPU_PID=$!
fi

# One block per second, prefixed with a wall-clock timestamp, top 15 threads.
top -H -b -d 1 -w 200 -p "$PID" | awk '
  /^top - / { print "### " strftime("%H:%M:%S"); n=0; next }
  /^ *PID / { hdr=1; n=0; next }
  hdr && NF && n < 15 { print; n++ }
  !NF { hdr=0 }
' > "$OUT/threads.txt" &
TOP_PID=$!

while kill -0 "$PID" 2>/dev/null; do sleep 1; done
kill $GPU_PID "$TOP_PID" 2>/dev/null
echo "game exited, recording stopped"

# Per-thread averages over the whole recording (top's %CPU: 100 = one full core).
awk '/^###/ { n++; next } NF >= 12 { k=$1" "$12; s[k]+=$9; if ($9 > m[k]) m[k]=$9 }
     END { for (k in s) printf "%6.1f%% avg %6.1f%% max  %s\n", s[k]/n, m[k], k }' \
  "$OUT/threads.txt" | sort -rn | head -12 > "$OUT/summary_threads.txt"
[ -s "$OUT/gpu.csv" ] && awk '{ g += $3; c++ } END { if (c) printf "GPU utilisation avg %.0f%% over %d samples\n", g/c, c }' \
  "$OUT/gpu.csv" > "$OUT/summary_gpu.txt"
cat "$OUT/summary_threads.txt" "$OUT/summary_gpu.txt" 2>/dev/null
