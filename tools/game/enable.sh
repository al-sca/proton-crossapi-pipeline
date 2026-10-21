#!/usr/bin/env bash
# Turns the pipelined handoff on for one game: installs the patched dlss5-feed.addon64 (the
# official one is kept as dlss5-feed.addon64.official.bak) and sets async_home=1.
#
#   tools/game/enable.sh <steam-appid> [--force]
#
# --force installs the patched build even when the game's official add-on is a different
# Feeder version (e.g. after dlss5-enabler updated it). Rebuild the patch on that version instead
# if you can.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
resolve_game "${1:-}"; shift || true
FORCE=0; [ "${1:-}" = "--force" ] && FORCE=1
need_feeder

[ -f "$XAPI_ADDON" ] || die "patched add-on not found at $XAPI_ADDON -- build it with tools/build-dlss5-feeder.sh (or set XAPI_ADDON)"
is_patched "$XAPI_ADDON" || die "$XAPI_ADDON is not the patched build (no '$XAPI_MARKER' in it)"
info "$GAME_NAME ($APPID): $GAME_DIR"

if ! is_patched "$ADDON"; then
  have="$(feed_version "$ADDON")"; want="$(feed_version "$XAPI_ADDON")"
  if [ -n "$have" ] && [ -n "$want" ] && [ "$have" != "$want" ] && [ $FORCE = 0 ]; then
    die "the game has DLSS5-Feeder $have, the patched build is $want. Rebase the patch on $have and rebuild, or pass --force"
  fi
  same=""
  for b in "$GAME_DIR"/dlss5-feed.addon64.official*.bak; do
    [ -f "$b" ] && cmp -s "$b" "$ADDON" && same="$b"
  done
  if [ -n "$same" ]; then
    ok "official add-on ($have) already backed up as $(basename "$same")"
  else
    bak="$GAME_DIR/dlss5-feed.addon64.official.bak"
    [ -f "$bak" ] && mv "$bak" "$bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$ADDON" "$bak"
    ok "official add-on ($have) backed up as $(basename "$bak")"
  fi
fi
if ! cmp -s "$XAPI_ADDON" "$ADDON"; then
  cp "$XAPI_ADDON" "$ADDON"
  ok "patched add-on installed ($(feed_version "$ADDON"), $(sha256sum "$ADDON" | cut -c1-12))"
else
  ok "patched add-on already installed"
fi

backup_cfg_once
cfg_set async_home 1
cfg_set sync_home 0
cfg_set buffer_home 1
ok "dlss5-feed.cfg: async_home=1 sync_home=0 buffer_home=1"
[ -z "${XAPI_QUIET:-}" ] && game_pid >/dev/null && warn "the game is running: the change takes effect at its next start"
exit 0
