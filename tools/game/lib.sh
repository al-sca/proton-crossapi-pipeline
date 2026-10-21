# Shared helpers for the per-game scripts in tools/game/. Sourced, not run.
#
# A game is addressed by its Steam app id (the same id protontricks uses). From it:
#   GAME_NAME, INSTALLDIR, SLUG     from steamapps/appmanifest_<id>.acf
#   GAME_ROOT                       <library>/steamapps/common/<installdir>
#   COMPAT                          <library>/steamapps/compatdata/<id>  (Proton prefix in pfx/)
#   GAME_EXE                        from dlss5-enabler's installs.json, if it was installed there
#   GAME_DIR                        the folder holding dlss5-feed.addon64 (and ReShade, its logs)

XAPI_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
XAPI_ADDON="${XAPI_ADDON:-$XAPI_REPO/build/dlss5-feed.addon64}"
XAPI_MARKER='async_home (D3D11)'      # string only the patched add-on contains

if [ -t 1 ]; then B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; N=$'\e[0m'; else B= R= G= Y= N=; fi
die()  { echo "${R}error:${N} $*" >&2; exit 1; }
warn() { echo "${Y}warning:${N} $*" >&2; }
info() { echo "${B}::${N} $*"; }
ok()   { echo "${G}ok${N}  $*"; }

steam_root() {
  local d
  for d in "${STEAM_ROOT:-}" "$HOME/.local/share/Steam" "$HOME/.steam/steam" \
           "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam"; do
    [ -n "$d" ] && [ -f "$d/steamapps/libraryfolders.vdf" ] && { echo "$d"; return; }
  done
  die "no Steam installation found (set STEAM_ROOT)"
}

steam_libraries() {
  local root; root="$(steam_root)"
  { echo "$root"
    sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$root/steamapps/libraryfolders.vdf"
  } | awk '!seen[$0]++'
}

acf_value() { sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*\"\(.*\)\"[[:space:]]*$/\1/p" "$1" | head -1; }

# resolve_game <appid>: sets the variables listed at the top.
resolve_game() {
  APPID="${1:?steam app id (as protontricks shows it)}"
  [[ "$APPID" =~ ^[0-9]+$ ]] || die "'$APPID' is not a Steam app id"
  local lib acf=""
  while IFS= read -r lib; do
    [ -f "$lib/steamapps/appmanifest_$APPID.acf" ] && { acf="$lib/steamapps/appmanifest_$APPID.acf"; LIBRARY="$lib"; break; }
  done < <(steam_libraries)
  [ -n "$acf" ] || die "app $APPID is not installed in any Steam library"
  GAME_NAME="$(acf_value "$acf" name | sed 's/[[:space:]]*$//')"
  INSTALLDIR="$(acf_value "$acf" installdir)"
  GAME_ROOT="$LIBRARY/steamapps/common/$INSTALLDIR"
  COMPAT="$LIBRARY/steamapps/compatdata/$APPID"
  SLUG="$(echo "$INSTALLDIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9\n' '_' | sed 's/__*/_/g; s/^_//; s/_$//')"

  GAME_EXE="$(python3 -I - "$GAME_ROOT" <<'EOF' 2>/dev/null
import json, os, sys
root = os.path.realpath(sys.argv[1]) + os.sep
try:
    recs = json.load(open(os.path.expanduser("~/.local/share/dlss5-enabler/installs.json")))
except Exception:
    recs = []
for r in recs:
    exe = r.get("game_exe", "")
    if os.path.realpath(exe).startswith(root):
        print(exe)
EOF
)"
  GAME_EXE="$(tail -1 <<<"$GAME_EXE")"

  GAME_DIR=""
  if [ -n "$GAME_EXE" ] && [ -f "$(dirname "$GAME_EXE")/dlss5-feed.addon64" ]; then
    GAME_DIR="$(dirname "$GAME_EXE")"
  else
    local hit; hit="$(find "$GAME_ROOT" -maxdepth 4 -name dlss5-feed.addon64 -print -quit 2>/dev/null)"
    [ -n "$hit" ] && GAME_DIR="$(dirname "$hit")"
  fi
  if [ -z "$GAME_EXE" ] && [ -n "$GAME_DIR" ] && [ -f "$GAME_DIR/dlss5-feed.log" ]; then
    local host; host="$(sed -n 's/^.*host: .*\\\([^\\]*\.exe\)\r\{0,1\}$/\1/p' "$GAME_DIR/dlss5-feed.log" | head -1)"
    [ -n "$host" ] && GAME_EXE="$GAME_DIR/$host"
  fi
  ADDON="$GAME_DIR/dlss5-feed.addon64"
  CFG="$GAME_DIR/dlss5-feed.cfg"
  FEEDLOG="$GAME_DIR/dlss5-feed.log"
  RESHADELOG="$GAME_DIR/ReShade.log"
  EXE_NAME="$(basename "${GAME_EXE:-}")"
}

need_feeder() {
  [ -n "$GAME_DIR" ] && [ -f "$ADDON" ] || die "no dlss5-feed.addon64 under $GAME_ROOT -- install DLSS 5 with dlss5-enabler first (tools/game/setup.sh $APPID --exe <game.exe> does that)"
}

is_patched()   { [ -f "$1" ] && grep -a -q "$XAPI_MARKER" "$1"; }
feed_version() { strings -a "$1" 2>/dev/null | sed -n 's/^DLSS 5 Feed \([0-9][0-9.]*\)$/\1/p' | head -1; }
official_backup() { ls -t "$GAME_DIR"/dlss5-feed.addon64.official*.bak 2>/dev/null | head -1; }

# dlss5-feed.cfg is CRLF; keep whatever line ending the file uses.
cfg_get() { [ -f "$CFG" ] && sed -n "s/^$1=\([^\r]*\)\r\{0,1\}$/\1/p" "$CFG" | tail -1; }
cfg_set() {
  local key="$1" val="$2"
  [ -f "$CFG" ] || die "$CFG missing -- start the game once with DLSS 5 so the Feeder writes it"
  if grep -q "^$key=" "$CFG"; then
    sed -i -E "s/^$key=[^\r]*(\r?)$/$key=$val\1/" "$CFG"
  elif grep -q $'\r$' "$CFG"; then
    printf '%s=%s\r\n' "$key" "$val" >> "$CFG"
  else
    printf '%s=%s\n' "$key" "$val" >> "$CFG"
  fi
}
backup_cfg_once() {
  ls "$CFG".pre-xapi-*.bak >/dev/null 2>&1 || cp -p "$CFG" "$CFG.pre-xapi-$(date +%Y%m%d-%H%M%S).bak"
}

# PID of the running game: the process whose own executable (argv[0], Proton renames comm) is
# the game exe. Launchers and wrappers that only carry the exe path as an argument (Steam,
# Proton, EA's EASteamProxy.exe, ...) do not match.
game_pid() {
  [ -n "$EXE_NAME" ] || return 1
  local p a0 re want; re="$(sed 's/[][\.*^$+?(){}|]/\\&/g' <<<"$EXE_NAME")"
  want="${EXE_NAME,,}"
  for p in $(pgrep -f -i "$re" 2>/dev/null); do
    a0=$(tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | head -1) || continue
    a0="${a0##*[\\/]}"
    [ "${a0,,}" = "$want" ] && { echo "$p"; return 0; }
  done
  return 1
}

# What the Feeder log says about the current/last session. Each prints nothing (and succeeds)
# when the log does not have the line.
feed_grep() { [ -f "$FEEDLOG" ] && grep -a "$@" "$FEEDLOG" 2>/dev/null; return 0; }
feed_transport() { feed_grep -o 'NGX init: transport [A-Za-z0-9 -]*' | tail -1 | sed 's/NGX init: transport //; s/ *$//'; }
feed_build()     { feed_grep 'attached\.' | sed -n 's/^.*dlss5-feed \([0-9.]*\) commit \([^ ]*\) .*/\1 \2/p' | tail -1; }
feed_resolution() { feed_grep -o 'Output [0-9]*x[0-9]*' | tail -1 | sed 's/Output //'; }
# The Feeder re-reads dlss5-feed.cfg every 60 frames and logs a "config:" line only when the
# values differ from what it ran with -- at startup that means from its defaults (async_home=0).
feed_session_async() {
  local v; v="$(feed_grep -o 'config: enabled=.* async_home=[0-9]' | tail -1 | sed 's/.*async_home=//')"
  echo "${v:-0}"
}
feed_config_lines() { feed_grep -c 'config: enabled=' || true; }
# Did the running session load the patched add-on? Its build id is compiled into the binary;
# the line below is logged once the D3D11 pipelining is active.
session_patched() {
  local c; c="$(feed_build | awk '{print $2}')"
  [ -n "$c" ] || return 1
  local f
  for f in "$XAPI_ADDON" "$ADDON"; do
    is_patched "$f" && grep -a -q -F "$c" "$f" && return 0
  done
  return 1
}
session_pipelining() { [ -n "$(feed_grep -m1 "$XAPI_MARKER")" ]; }

# The DLLs Wine must load from the game folder instead of its own (ReShade's proxy, dgVoodoo).
proxy_dlls() {
  local d out=()
  for d in dxgi d3d9 d3d11 d3d12 d3d8 ddraw dinput8 opengl32 winmm version; do
    [ -f "$GAME_DIR/$d.dll" ] && out+=("$d")
  done
  echo "${out[*]}"
}

# reg_override <dll>: the prefix's [Software\Wine\DllOverrides] value for it, e.g. native,builtin
reg_override() {
  [ -f "$COMPAT/pfx/user.reg" ] || return 0
  awk -v k="\"$1\"" '/^\[Software\\\\Wine\\\\DllOverrides\]/ { f = 1; next } /^\[/ { f = 0 }
    f && index($0, k "=") == 1 { v = substr($0, length(k) + 2); gsub(/"/, "", v); print v }' "$COMPAT/pfx/user.reg"
}

steam_launch_options() {
  python3 -I - "$(steam_root)" "$APPID" <<'EOF' 2>/dev/null
import glob, re, sys
root, appid = sys.argv[1], sys.argv[2]
tok_re = re.compile(r'"((?:[^"\\]|\\.)*)"|([{}])')
def parse(toks, i):
    d = {}
    while i < len(toks):
        s, b = toks[i]
        if b == '}':
            return d, i + 1
        if toks[i + 1][1] == '{':
            v, i = parse(toks, i + 2)
            if isinstance(d.get(s), dict): d[s].update(v)
            else: d[s] = v
        else:
            d[s] = toks[i + 1][0]; i += 2
    return d, i
for f in glob.glob(root + "/userdata/*/config/localconfig.vdf"):
    try:
        t = open(f, encoding="utf-8", errors="replace").read()
        d, _ = parse(tok_re.findall(t), 0)
        app = d["UserLocalConfigStore"]["Software"]["Valve"]["Steam"]["apps"].get(appid, {})
        if "LaunchOptions" in app:
            print(app["LaunchOptions"].replace('\\"', '"')); break
    except Exception:
        pass
EOF
}

play_cue() {
  local s=/usr/share/sounds/freedesktop/stereo/$1.oga
  [ -f "$s" ] || return 0
  if command -v pw-play >/dev/null; then pw-play "$s" >/dev/null 2>&1 &
  elif command -v paplay >/dev/null; then paplay "$s" >/dev/null 2>&1 & fi
}
