#!/usr/bin/env bash
#
# The README / Reddit demo: one 16-second loop of the four mascot states, island
# on top and the floating cat below, as docs/media/demo.mp4 and demo.gif.
#
#   scripts/capture-demo-gif.sh
#
# Same approach as capture-screenshots.sh — `dist/CodeCat.app --demo`, a full-
# screen `screencapture` cropped to the mascot — with two additions:
#   * The floating cat is recorded over a plain window of a known colour, because
#     it is a transparent panel and whatever is behind it ends up in the file.
#   * Both recordings run long (40s), and the phase boundaries are found
#     afterwards from the badge colour, so the loop can start on "idle" and both
#     halves can be cut at the same phase. Recording exactly 16 seconds from a
#     guessed launch offset never lined up.
#
# Needs: Screen Recording permission for the shell that runs this, a display
# with a notch (for the island half), ffmpeg, swiftc, and python3 with Pillow.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/CodeCat.app"
BIN="$APP/Contents/MacOS/CodeCat"
OUT="$ROOT/docs/media"
WORK="$(mktemp -d)"
KEY=com.codecat.app
SETTLE=2.5
DUR=40
BG=16181d           # the colour under the floating cat; also the pad colour below

die() { echo "capture-demo-gif: $*" >&2; exit 1; }
[ -d "$APP" ] || die "no $APP — run \`make app\` first"
for tool in ffmpeg swiftc python3; do command -v "$tool" >/dev/null || die "$tool not found"; done
python3 -c 'import PIL' 2>/dev/null || die "python3 needs Pillow (pip3 install Pillow)"

read -r W H <<<"$(osascript -e 'tell application "Finder" to get bounds of window of desktop' \
    | tr -d ' ' | awk -F, '{print $3, $4}')"

# --- borrow the user's settings, put them back on exit ------------------------
PREV_MODE="$(defaults read $KEY mascotDisplayMode 2>/dev/null || echo "")"
PREV_POS="$(defaults read $KEY mascotPosition.v2 2>/dev/null | tr -d '()\n ' | sed 's/,$//' || echo "")"
APP_PID=""; BG_PID=""
WAS_RUNNING=false
if pgrep -x CodeCat >/dev/null; then WAS_RUNNING=true; pkill -TERM -x CodeCat || true; sleep 1; fi

stop() {
    for pid in "$APP_PID" "$BG_PID"; do
        [ -n "$pid" ] && { kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; }
    done
    APP_PID=""; BG_PID=""
}
restore() {
    stop
    if [ -n "$PREV_MODE" ]; then defaults write $KEY mascotDisplayMode -string "$PREV_MODE"
    else defaults delete $KEY mascotDisplayMode 2>/dev/null || true; fi
    if [ -n "$PREV_POS" ]; then
        local args=(); local IFS=,
        for v in $PREV_POS; do args+=(-float "$v"); done
        defaults write $KEY mascotPosition.v2 -array "${args[@]}"
    else defaults delete $KEY mascotPosition.v2 2>/dev/null || true; fi
    [ "$WAS_RUNNING" = true ] && open -a /Applications/CodeCat.app || true
    rm -rf "$WORK"
}
trap restore EXIT

# --- a plain window to record the floating cat against ------------------------
cat >"$WORK/bgwin.swift" <<EOF
import AppKit
let a = CommandLine.arguments
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let r = NSRect(x: Double(a[1])!, y: Double(a[2])!, width: Double(a[3])!, height: Double(a[4])!)
let win = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
win.backgroundColor = NSColor(red: 0x16/255.0, green: 0x18/255.0, blue: 0x1d/255.0, alpha: 1)
win.level = .normal
win.hasShadow = false
win.orderFrontRegardless()
app.run()
EOF
swiftc -O -o "$WORK/bgwin" "$WORK/bgwin.swift"

# --- 1. the island ------------------------------------------------------------
echo "recording the island (${DUR}s)"
defaults write $KEY mascotDisplayMode -string island
"$BIN" --demo >/dev/null 2>&1 & APP_PID=$!
sleep "$SETTLE"
screencapture -v -V "$DUR" -R"$(( (W - 360) / 2 )),0,360,40" "$WORK/island.mov"
stop; sleep 1

# --- 2. the floating cat ------------------------------------------------------
echo "recording the floating cat (${DUR}s)"
DEMO_X=$(( W - 460 )); DEMO_Y=$(( H - 220 )); CANVAS=128
defaults write $KEY mascotDisplayMode -string floating
defaults write $KEY mascotPosition.v2 -array -float "$DEMO_X" -float "$DEMO_Y" -float "$CANVAS"
"$WORK/bgwin" $((DEMO_X - 8)) $((DEMO_Y - 8)) 144 144 & BG_PID=$!
sleep 1
"$BIN" --demo >/dev/null 2>&1 & APP_PID=$!
sleep "$SETTLE"
screencapture -v -V "$DUR" -R"$((DEMO_X - 8)),$((H - DEMO_Y - CANVAS - 8)),144,144" "$WORK/cat.mov"
stop

# --- 3. find the phase boundaries from the badge colour -----------------------
# The "waiting" badge is red (cat) / orange (island); it is the only warm colour
# in either frame. The loop is idle→working→waiting→done at 4s each, so idle
# begins 8s after waiting does, and the cut is [idle, idle + one period).
echo "finding the phase boundaries"
mkdir -p "$WORK/fr/cat" "$WORK/fr/isl"
ffmpeg -v error -i "$WORK/cat.mov" -vf fps=20 "$WORK/fr/cat/%04d.png"
ffmpeg -v error -i "$WORK/island.mov" -vf fps=20 "$WORK/fr/isl/%04d.png"
read -r CAT_SS ISL_SS PERIOD <<<"$(python3 - "$WORK/fr" <<'EOF'
import glob, sys
from PIL import Image
root = sys.argv[1]
def warm(path):
    return sum(1 for r, g, b in Image.open(path).convert('RGB').getdata() if r > 190 and g < 160 and b < 90)
out = []
for name in ('cat', 'isl'):
    counts = [warm(f) for f in sorted(glob.glob(f'{root}/{name}/*.png'))]
    starts = [i for i, c in enumerate(counts) if c > 30 and (i == 0 or counts[i-1] <= 30)]
    if len(starts) < 2: sys.exit(f'{name}: fewer than two waiting phases in the recording')
    out.append((starts[0] + 160) / 20.0)               # idle = waiting + 8s
    period = (starts[1] - starts[0]) / 20.0
print(out[0], out[1], period)
EOF
)"
echo "  cat from ${CAT_SS}s, island from ${ISL_SS}s, period ${PERIOD}s"

# --- 4. compose ---------------------------------------------------------------
# Island 360x40pt = 720x80px at Retina; the cat crop is 144pt = 288px, shown at
# 2x with nearest-neighbour (it is pixel art). Padded to the island's width.
ffmpeg -v error -y -ss "$ISL_SS" -t "$PERIOD" -i "$WORK/island.mov" \
                  -ss "$CAT_SS" -t "$PERIOD" -i "$WORK/cat.mov" \
    -filter_complex "[0:v]fps=20,scale=720:80:flags=neighbor[isl];
                     [1:v]fps=20,scale=576:576:flags=neighbor,pad=720:584:72:8:0x$BG[cat];
                     [isl][cat]vstack=inputs=2,format=yuv420p[v]" \
    -map "[v]" -c:v libx264 -crf 20 -movflags +faststart "$OUT/demo.mp4"
ffmpeg -v error -y -i "$OUT/demo.mp4" \
    -filter_complex "[0:v]fps=15,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none" \
    "$OUT/demo.gif"
ls -la "$OUT/demo.mp4" "$OUT/demo.gif"
