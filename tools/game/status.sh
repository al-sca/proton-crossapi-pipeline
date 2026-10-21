#!/usr/bin/env bash
# Shows everything the other scripts look at for one game, and what is missing.
#
#   tools/game/status.sh <steam-appid>
set -uo pipefail
. "$(dirname "$0")/lib.sh"
resolve_game "${1:-}"

row() { printf '  %-18s %s\n' "$1" "$2"; }
echo "${B}$GAME_NAME${N} (app $APPID, results slug '$SLUG')"
row "install" "$GAME_ROOT"
row "exe" "${GAME_EXE:-${Y}unknown${N} (not in the dlss5-enabler install index, no Feeder log yet)}"
row "Proton prefix" "$( [ -d "$COMPAT/pfx" ] && echo "$COMPAT/pfx (Proton $(cat "$COMPAT/version" 2>/dev/null))" || echo "${Y}none yet${N} -- start the game once through Steam")"
if [ -f "$COMPAT/pfx/winetricks.log" ] && grep -qx d3dcompiler_47 "$COMPAT/pfx/winetricks.log"; then
  row "d3dcompiler_47" "${G}installed${N}"
else
  row "d3dcompiler_47" "${Y}missing${N} -- tools/game/setup.sh $APPID installs it"
fi

if [ -z "$GAME_DIR" ]; then
  row "DLSS5-Feeder" "${R}not installed${N} -- uvx dlss5-enabler@latest install \"<game.exe>\""
  exit 1
fi
row "game folder" "$GAME_DIR"
if is_patched "$ADDON"; then a="${G}patched${N}"; else a="${Y}official${N}"; fi
row "add-on" "$a, Feeder $(feed_version "$ADDON") ($(sha256sum "$ADDON" | cut -c1-12))"
bak="$(official_backup)"; [ -n "$bak" ] && row "official backup" "$(basename "$bak") ($(feed_version "$bak"))"
row "cfg" "async_home=$(cfg_get async_home) sync_home=$(cfg_get sync_home) buffer_home=$(cfg_get buffer_home) mode=$(cfg_get mode)"
if is_patched "$ADDON" && [ "$(cfg_get async_home)" = 1 ] && [ "$(cfg_get sync_home)" = 0 ]; then
  row "pipelining" "${G}ON${N} at the next start"
else
  row "pipelining" "OFF at the next start"
fi

t="$(feed_transport)"
case "$t" in
  "")              row "transport" "unknown until the game ran once with DLSS 5" ;;
  "D3D11 cross-API"*) row "transport" "$t -- ${G}the patch applies${N}" ;;
  *Vulkan*)        row "transport" "$t -- the official build already pipelines this with async_home=1" ;;
  *)               row "transport" "$t -- ${Y}the patch only changes the D3D11 cross-API transport${N}" ;;
esac
[ -n "$(feed_build)" ] && row "last session" "Feeder $(feed_build), async_home=$(feed_session_async), output $(feed_resolution)"

# Each proxy DLL in the game folder must load as native: from the launch options or from the
# prefix registry (dlss5-enabler writes the latter).
need="$(proxy_dlls)"; lo="$(steam_launch_options)"
row "launch options" "${lo:-(none)}"
missing="" via=""
for d in $need; do
  if grep -q "$d=n" <<<"$lo"; then via+=" $d(launch)"
  elif [[ "$(reg_override "$d")" == native* ]]; then via+=" $d(registry)"
  else missing+=" $d"; fi
done
[ -n "$via" ] && row "native overrides" "${via# }"
if [ -n "$missing" ]; then
  ov="$(for d in $need; do printf '%s=n,b;' "$d"; done)"
  row "" "${Y}no native override for:${missing}${N} -- Steam > Properties > Launch Options:"
  row "" "WINEDLLOVERRIDES=\"${ov%;}\" %command%"
fi
pid="$(game_pid)" && row "running" "pid $pid"
exit 0
