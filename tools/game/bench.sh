#!/usr/bin/env bash
# Before/after benchmark of the pipelined handoff for one game, in ONE game session.
#
#   tools/game/bench.sh <steam-appid> [ab|before|after] [options]
#
#   ab       (default) "before" (async_home=0), then "after" (async_home=1), then the report
#   before   only the async_home=0 run   (the patched add-on then runs the official code path)
#   after    only the async_home=1 run
#
#   --seconds N   length of each recording, default 45
#   --delay N     seconds between pressing Enter and the first switch, default 10
#   --tag NAME    store as before-NAME / after-NAME, e.g. --tag dlss-off or --tag city
#   --no-launch   do not start the game through Steam, wait for you to start it
#   --no-prompt   do not wait for Enter: start as soon as the game runs and --delay has passed
#
# The Feeder re-reads dlss5-feed.cfg every 60 frames and rebuilds when async_home changes, so
# the script flips it while you stand still at the test spot: no restart, same scene for both
# runs. Each run: switch async_home, wait until the Feeder logged the change, let it settle,
# wait for the start of a fresh 30 s RenoDX telemetry window, record. A sound marks the start
# and end of each recording. Do not pause the game or open a menu while it runs.
#
# Output: results/games/<slug>/<label>.txt (summary, committed) and
#         results/games/<slug>/raw/<label>/ (nvidia-smi, top and log excerpts, git-ignored).
set -euo pipefail
HERE="$(dirname "$0")"
. "$HERE/lib.sh"
resolve_game "${1:-}"; shift || true
MODE=ab; SECONDS_REC=45; DELAY=10; TAG=""; LAUNCH=1; PROMPT=1; SETTLE=8
while [ $# -gt 0 ]; do
  case "$1" in
    ab|before|after) MODE="$1"; shift ;;
    --seconds) SECONDS_REC="${2:?}"; shift 2 ;;
    --delay) DELAY="${2:?}"; shift 2 ;;
    --tag) TAG="-${2:?}"; shift 2 ;;
    --no-launch) LAUNCH=0; shift ;;
    --no-prompt) PROMPT=0; shift ;;
    *) die "unknown argument $1 (see the header of $0)" ;;
  esac
done
need_feeder
[ -n "$EXE_NAME" ] || die "the game exe is unknown -- run tools/game/setup.sh $APPID first"
is_patched "$ADDON" || is_patched "$XAPI_ADDON" || die "no patched add-on to test with -- see tools/game/enable.sh"
OUTDIR="$XAPI_REPO/results/games/$SLUG"
mkdir -p "$OUTDIR"

telemetry_count() { local n=""; [ -f "$RESHADELOG" ] && n="$(grep -a -c 'telemetry t=' "$RESHADELOG" 2>/dev/null || true)"; echo "${n:-0}"; }

countdown() {   # countdown <seconds> <text>
  local i
  for ((i = $1; i > 0; i--)); do
    game_pid >/dev/null || { echo; die "the game exited"; }
    printf '\r%s %3d s ' "$2" "$i"; sleep 1
  done
  printf '\r%*s\r' 40 ''
}

# switch_to <0|1>: write async_home and wait until the running Feeder has applied it.
switch_to() {
  local want="$1" n0 i
  n0="$(feed_config_lines)"
  if [ "$want" = 1 ]; then XAPI_QUIET=1 "$HERE/enable.sh" "$APPID" >/dev/null
  else XAPI_QUIET=1 "$HERE/disable.sh" "$APPID" >/dev/null; fi
  [ "$(feed_session_async)" = "$want" ] && return 0
  for ((i = 0; i < 120; i++)); do
    if [ "$(feed_config_lines)" -gt "$n0" ] && [ "$(feed_session_async)" = "$want" ]; then
      echo "Feeder switched to async_home=$want"; countdown "$SETTLE" "settling"; return 0
    fi
    game_pid >/dev/null || die "the game exited"
    sleep 0.25
  done
  die "the Feeder did not pick up async_home=$want within 30 s -- is the game paused or minimised?"
}

# wait for a new RenoDX telemetry line: the recording then covers one whole 30 s window
align_telemetry() {
  local n0 i; n0="$(telemetry_count)"
  printf 'waiting for the next telemetry window ...'
  for ((i = 0; i < 160; i++)); do
    [ "$(telemetry_count)" -gt "$n0" ] && { printf '\r%*s\r' 50 ''; return 0; }
    game_pid >/dev/null || { echo; die "the game exited"; }
    sleep 0.25
  done
  echo; warn "no RenoDX telemetry in ReShade.log -- fps will come from the Feeder's own stats"
}

measure() {   # measure <label> <async 0|1>
  local label="$1" async="$2" pid raw t0 t1 bg=() i
  echo; info "${B}run '$label'${N}: async_home=$async"
  switch_to "$async"
  if [ "$async" = 1 ] && ! session_pipelining; then
    die "async_home=1 is set but the Feeder never logged '$XAPI_MARKER: ...' -- the D3D11 pipelining is not active in this session"
  fi
  align_telemetry
  pid="$(game_pid)" || die "the game is not running"

  raw="$OUTDIR/raw/$label"; rm -rf "$raw"; mkdir -p "$raw"
  play_cue message
  t0=$(date +%s.%N)
  if command -v nvidia-smi >/dev/null; then
    timeout "$SECONDS_REC" nvidia-smi --query-gpu=timestamp,utilization.gpu,power.draw,clocks.gr \
      --format=csv,noheader,nounits -lms 500 > "$raw/gpu.csv" 2>/dev/null & bg+=($!)
  else
    local busy; busy="$(ls /sys/class/drm/card*/device/gpu_busy_percent 2>/dev/null | head -1)"
    if [ -n "$busy" ]; then
      ( end=$((SECONDS + SECONDS_REC)); while [ $SECONDS -lt $end ]; do
          echo "$(date +%T.%N), $(cat "$busy"),"; sleep 0.5; done ) > "$raw/gpu.csv" & bg+=($!)
    fi
  fi
  top -H -b -d 1 -n "$((SECONDS_REC + 1))" -w 200 -p "$pid" > "$raw/threads.txt" 2>/dev/null & bg+=($!)
  for ((i = SECONDS_REC; i > 0; i--)); do
    kill -0 "$pid" 2>/dev/null || { echo; kill "${bg[@]}" 2>/dev/null; die "the game exited during the recording"; }
    printf '\rrecording %3d s left ' "$i"; sleep 1
  done
  t1=$(date +%s.%N)
  kill "${bg[@]}" 2>/dev/null || true; wait "${bg[@]}" 2>/dev/null || true
  play_cue complete
  printf '\rrecording done.        \n'
  sleep 2   # the Feeder's last stats line may land just after the end

  {
    echo "game=$GAME_NAME"; echo "appid=$APPID"; echo "label=$label"
    echo "date=$(date -d "@${t0%.*}" '+%Y-%m-%d %H:%M')"; echo "seconds=$SECONDS_REC"
    echo "exe=$EXE_NAME"; echo "async_home=$(feed_session_async)"; echo "feeder=$(feed_build)"
    echo "transport=$(feed_transport)"; echo "resolution=$(feed_resolution)"
    echo "proton=$(cat "$COMPAT/version" 2>/dev/null)"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1)"
    echo "cpu=$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
    echo "kernel=$(uname -r)"
    python3 -I "$HERE/analyze.py" "$raw" "$t0" "$t1" "$RESHADELOG" "$FEEDLOG"
  } > "$OUTDIR/$label.txt"
  ok "$OUTDIR/$label.txt"
  grep -E '^(fps|frame_p50_ms|frame_p99_ms|gpu_util|gpu_power_w|feed_cpu_ms|top_thread_avg|dlss5|stalls|fps_source)=' \
    "$OUTDIR/$label.txt" | sed 's/^/    /'
}

if ! game_pid >/dev/null; then
  XAPI_QUIET=1 "$HERE/enable.sh" "$APPID" >/dev/null   # the game loads the add-on at startup
  if [ $LAUNCH = 1 ]; then
    info "starting $GAME_NAME through Steam"
    if command -v steam >/dev/null; then steam "steam://rungameid/$APPID" >/dev/null 2>&1 &
    else xdg-open "steam://rungameid/$APPID" >/dev/null 2>&1 & fi
  else
    echo "Start $GAME_NAME now."
  fi
fi
if [ $PROMPT = 1 ]; then
  cat <<EOF
Load your test save, go to the test spot, wait until shaders and streaming have settled, then
come back here and press ${B}Enter${N}. Switch back to the game within ${DELAY} s and stand still
(do not pause or open a menu). Each run takes about $((SECONDS_REC + 20))-$((SECONDS_REC + 50)) s; a sound marks the start
and the end of every recording. Stay in the game until the last sound.
EOF
  read -r _ </dev/tty
else
  until game_pid >/dev/null; do sleep 2; done
fi
game_pid >/dev/null || die "the game is not running"
session_patched || die "the running game loaded Feeder $(feed_build), not the patched build. Quit it and run bench.sh again: it installs the patched add-on before starting the game."
countdown "$DELAY" "first run in"

case "$MODE" in
  before) measure "before$TAG" 0 ;;
  after)  measure "after$TAG" 1 ;;
  ab)     measure "before$TAG" 0; measure "after$TAG" 1 ;;
esac
# leave the game with the fix on (the running session switches too)
XAPI_QUIET=1 "$HERE/enable.sh" "$APPID" >/dev/null
play_cue bell
echo; "$HERE/report.sh" "$APPID"
