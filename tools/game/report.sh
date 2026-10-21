#!/usr/bin/env bash
# Compares the before/after runs and rebuilds the results table in README.md (between the
# <!-- games:begin --> and <!-- games:end --> markers) from every results/games/*/ folder.
#
#   tools/game/report.sh [<steam-appid>]     # with an app id, also prints that game's details
set -euo pipefail
. "$(dirname "$0")/lib.sh"
SLUG_ARG=""
if [ -n "${1:-}" ]; then resolve_game "$1"; SLUG_ARG="$SLUG"; fi

python3 -I - "$XAPI_REPO" "$SLUG_ARG" <<'EOF'
import glob, os, re, sys
repo, only = sys.argv[1], sys.argv[2]

def load(p):
    d = {}
    for ln in open(p, encoding="utf-8"):
        k, _, v = ln.rstrip("\n").partition("=")
        if k: d[k] = v
    return d

def num(d, k):
    try: return float(d.get(k, ""))
    except ValueError: return None

rows, details = [], []
for gdir in sorted(glob.glob(os.path.join(repo, "results/games/*/"))):
    slug = os.path.basename(gdir.rstrip("/"))
    for bpath in sorted(glob.glob(gdir + "before*.txt")):
        tag = os.path.basename(bpath)[len("before"):-len(".txt")]
        apath = gdir + "after" + tag + ".txt"
        if not os.path.exists(apath):
            continue
        b, a = load(bpath), load(apath)
        fb, fa = num(b, "fps"), num(a, "fps")
        gain = f"**{fa / fb:.2f}x**" if fb and fa else "?"
        def cell(d):
            s = f"{d.get('fps', '?')} fps"
            if d.get("frame_p50_ms"): s += f", p50 {d['frame_p50_ms']} ms"
            if d.get("gpu_util"): s += f", GPU {d['gpu_util']} %"
            return s
        warn = []
        if b.get("dlss5") and a.get("dlss5") and b["dlss5"] != a["dlss5"]: warn.append("DLSS 5 state differs")
        if b.get("resolution") != a.get("resolution"): warn.append("resolution differs")
        if b.get("async_home") == a.get("async_home"): warn.append("same async_home in both runs")
        # a frame cap, not the GPU, limits the "after" run: the gain is a lower bound
        ga = num(a, "gpu_util")
        for cap in (30, 60, 120, 144):
            if fa and abs(fa - cap) < 1.0 and ga is not None and ga < 85:
                warn.append(f"after run sits at the game's {cap} fps cap (GPU {ga:.0f} %)")
        note = os.path.join(gdir, "note" + tag + ".txt")
        if os.path.exists(note):
            warn.append(" ".join(open(note, encoding="utf-8").read().split()))
        name = a.get("game", slug).strip() + (f" ({tag.lstrip('-')})" if tag else "")
        rows.append((name, a.get("resolution", ""), a.get("dlss5", "?"), cell(b), cell(a), gain,
                     a.get("date", "")[:10], f"results/games/{slug}/", "; ".join(warn)))
        if slug == only:
            details.append((name, b, a, warn))

for name, b, a, warn in details:
    print(f"\n{name}")
    keys = ["fps", "frame_p50_ms", "frame_p99_ms", "frame_max_ms", "gpu_util", "gpu_power_w",
            "feed_gpu_ms", "feed_cpu_ms", "process_cpu", "top_thread_avg", "top_thread_max", "stalls",
            "dlss5", "async_home", "feeder", "resolution", "fps_source"]
    print(f"  {'':16} {'before':>28} {'after':>28}")
    for k in keys:
        if k in b or k in a:
            print(f"  {k:16} {b.get(k, '-'):>28} {a.get(k, '-'):>28}")
    for w in warn:
        print(f"  WARNING: {w}")

table = ["| Game | Resolution | DLSS 5 | Before (`async_home=0`) | After (`async_home=1`) | Change | Date |",
         "|---|---|---|---|---|---|---|"]
for name, res, dl, bc, ac, gain, date, link, warn in rows:
    table.append(f"| [{name}]({link}) | {res} | {dl} | {bc} | {ac} | {gain}{' ⚠ ' + warn if warn else ''} | {date} |")
readme = os.path.join(repo, "README.md")
text = open(readme, encoding="utf-8").read()
new = re.sub(r"(<!-- games:begin -->\n).*?(<!-- games:end -->)",
             lambda m: m.group(1) + "\n".join(table) + "\n" + m.group(2), text, flags=re.S)
if new == text and "<!-- games:begin -->" not in text:
    print("README.md has no <!-- games:begin --> / <!-- games:end --> markers; table not written")
elif new != text:
    open(readme, "w", encoding="utf-8").write(new)
    print(f"\nREADME.md: games table updated ({len(rows)} rows)")
else:
    print(f"\nREADME.md: games table unchanged ({len(rows)} rows)")
EOF
