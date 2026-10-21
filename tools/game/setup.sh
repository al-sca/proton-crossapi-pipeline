#!/usr/bin/env bash
# One-time setup of a game for testing: d3dcompiler_47 in its Proton prefix (protontricks),
# the patched DLSS5-Feeder with async_home=1, and a check of everything else.
#
#   tools/game/setup.sh <steam-appid> [--exe <path/to/game.exe>]
#
# The app id is the one protontricks lists (`protontricks -l`) and Steam shows in the store URL.
# DLSS 5 itself is installed by dlss5-enabler; with --exe this runs that installer for you when
# the game does not have it yet:  uvx dlss5-enabler@latest install <exe>
set -euo pipefail
. "$(dirname "$0")/lib.sh"
resolve_game "${1:-}"; shift || true
EXE_ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --exe) EXE_ARG="${2:?--exe needs a path}"; shift 2 ;;
    *) die "unknown option $1" ;;
  esac
done
info "$GAME_NAME (app $APPID) in $GAME_ROOT"
game_pid >/dev/null && die "the game is running -- quit it first"

# 1. DLSS 5 (dlss5-enabler)
if [ -z "$GAME_DIR" ]; then
  if [ -z "$EXE_ARG" ]; then
    echo "DLSS5-Feeder is not installed for this game. Pick the game's exe and run again with --exe:"
    find "$GAME_ROOT" -maxdepth 4 -iname '*.exe' -size +2M \
      ! -iname '*unins*' ! -iname '*crash*' ! -iname '*redist*' ! -iname 'vc_*' ! -iname '*setup*' \
      -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -6 | cut -f2 | sed 's/^/  /'
    exit 1
  fi
  [ -f "$EXE_ARG" ] || die "$EXE_ARG does not exist"
  command -v uvx >/dev/null || die "uvx (from uv) is needed to run dlss5-enabler"
  info "installing DLSS 5 with dlss5-enabler"
  uvx dlss5-enabler@latest install "$EXE_ARG"
  resolve_game "$APPID"
  need_feeder
fi

# 2. d3dcompiler_47 in the prefix (ReShade compiles its effects with it)
if [ ! -d "$COMPAT/pfx" ]; then
  warn "no Proton prefix yet: start the game once through Steam, quit, and run setup again for d3dcompiler_47"
elif [ -f "$COMPAT/pfx/winetricks.log" ] && grep -qx d3dcompiler_47 "$COMPAT/pfx/winetricks.log"; then
  ok "d3dcompiler_47 already in the prefix"
else
  if command -v protontricks >/dev/null; then PT=(protontricks)
  elif flatpak info com.github.Matoking.protontricks >/dev/null 2>&1; then PT=(flatpak run com.github.Matoking.protontricks)
  else die "protontricks is not installed"; fi
  info "installing d3dcompiler_47 with protontricks (takes a minute)"
  "${PT[@]}" "$APPID" -q d3dcompiler_47
  grep -qx d3dcompiler_47 "$COMPAT/pfx/winetricks.log" 2>/dev/null && ok "d3dcompiler_47 installed" \
    || die "protontricks finished but d3dcompiler_47 is not in $COMPAT/pfx/winetricks.log"
fi

# 3. the patched Feeder, pipelining on
if [ -f "$CFG" ]; then
  "$(dirname "$0")/enable.sh" "$APPID"
else
  warn "dlss5-feed.cfg does not exist yet: start the game once with DLSS 5, quit, then run tools/game/enable.sh $APPID"
fi

# 4. what is left to do by hand
echo
"$(dirname "$0")/status.sh" "$APPID" || true
cat <<EOF

${B}Next${N}
  - If launch options are flagged above, paste the suggested line into Steam > Properties.
  - First start: press Home, enable the motion-vector effect (e.g. LUMENITE: Kernel) and
    "DLSS 5 Feed", in that order, at the top of the list (dlss5-enabler's last step).
  - Benchmark: tools/game/bench.sh $APPID
EOF
