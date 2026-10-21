#!/usr/bin/env bash
# Turns the pipelined handoff off for one game: async_home=0. The patched add-on then runs the
# exact code path of the official build, which makes it the right "before" for an A/B test.
#
#   tools/game/disable.sh <steam-appid> [--official]
#
# --official also puts the official dlss5-feed.addon64 back (from the .official.bak backup).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
resolve_game "${1:-}"; shift || true
need_feeder
info "$GAME_NAME ($APPID): $GAME_DIR"

cfg_set async_home 0
ok "dlss5-feed.cfg: async_home=0"

if [ "${1:-}" = "--official" ]; then
  bak="$(official_backup)"
  [ -n "$bak" ] || die "no official backup (dlss5-feed.addon64.official*.bak) in $GAME_DIR"
  is_patched "$bak" && die "$bak is itself a patched build"
  cp -p "$bak" "$ADDON"
  ok "official add-on restored from $(basename "$bak") ($(feed_version "$ADDON"))"
fi
[ -z "${XAPI_QUIET:-}" ] && game_pid >/dev/null && warn "the game is running: the change takes effect at its next start"
exit 0
