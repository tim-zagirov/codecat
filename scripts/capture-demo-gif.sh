#!/usr/bin/env bash
#
# The README / Reddit demo: one 16-second loop of the island — asleep, working,
# an agent asking a question (the island peeks with it), the turns finishing (it
# peeks with what they handed back), asleep again — as docs/media/demo.mp4 and
# demo.gif.
#
#   scripts/capture-demo-gif.sh
#
# Same approach as capture-screenshots.sh: the release binary,
# `.build/release/CodeCatApp --demo`, with its own `CodeCatApp` defaults domain
# (deleted on exit; the installed app's `com.codecat.app` is never touched), recorded
# with ScreenCaptureKit filtered to the demo's own windows over a flat backdrop, so
# nothing else on the screen can end up in the file. The demo's loop opens the
# peeks itself — the waiting phase's question and the done phase's handoffs — so
# one run shows the island through its states and its peeks.
#
# The recording runs long (40 s) and the loop's boundaries are found afterwards
# from the waiting tone (the only orange in the frame), so the cut starts on
# "asleep" and lasts exactly one period. Recording exactly 16 seconds from a guessed
# launch offset never lined up.
#
# Needs: Screen Recording permission for the shell that runs this, a display with a
# notch, ffmpeg, swiftc, and python3 with Pillow. Keep the pointer away from the
# notch while it records: a hover opens the island.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/CodeCatApp"
OUT="$ROOT/docs/media"
TOOL="$ROOT/.build/own-windows"
CGEV="$ROOT/.build/cgev"
DOMAIN=CodeCatApp
WORK="$(mktemp -d)"
SETTLE=2.5
DUR=40
RECT_W=520          # the peek is 420 pt wide, plus its bloom
RECT_H=110          # 78 pt tall, plus its bloom

die() { echo "capture-demo-gif: $*" >&2; exit 1; }
[ -x "$BIN" ] || die "no $BIN — run \`swift build -c release\` first"
for tool in ffmpeg swiftc python3; do command -v "$tool" >/dev/null || die "$tool not found"; done
python3 -c 'import PIL' 2>/dev/null || die "python3 needs Pillow (pip3 install Pillow)"
for pair in "$TOOL:own-windows" "$CGEV:cgev"; do
    bin="${pair%%:*}"; src="$ROOT/scripts/dev/${pair##*:}.swift"
    if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then swiftc -O "$src" -o "$bin" || die "could not build $bin"; fi
done
NOTCH="$("$CGEV" notch 2>/dev/null || true)"
[ -n "$NOTCH" ] || die "no notch on any screen — the island needs one"
read -r NX NY NW NH <<<"$NOTCH"

# --- the installed CodeCat steps aside: two islands would share one notch -------
APP_PID=""
WAS_RUNNING=false
if pgrep -x CodeCat >/dev/null; then WAS_RUNNING=true; pkill -TERM -x CodeCat || true; sleep 1; fi
cleanup() {
    if [ -n "$APP_PID" ]; then kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; fi
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    if [ "$WAS_RUNNING" = true ]; then open -a /Applications/CodeCat.app || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# --- 1. record the loop ---------------------------------------------------------
echo "recording the island (${DUR}s)"
mkdir -p "$WORK/codex"
defaults delete "$DOMAIN" >/dev/null 2>&1 || true
defaults write "$DOMAIN" mascotDisplayMode -string island
CODEX_HOME="$WORK/codex" "$BIN" --demo >/dev/null 2>&1 & APP_PID=$!
sleep "$SETTLE"
OWN_WINDOWS_FPS=20 "$TOOL" record "$APP_PID" "$DUR" "$WORK/frames" \
    $(( NX + NW / 2 - RECT_W / 2 )) 0 "$RECT_W" "$RECT_H" >/dev/null \
    || die "nothing recorded (Screen Recording permission? a locked screen?)"
kill "$APP_PID" 2>/dev/null || true; wait "$APP_PID" 2>/dev/null || true; APP_PID=""

# --- 2. find one period that starts on "asleep" ----------------------------------
# The loop is asleep→working→waiting→done, four seconds each; waiting is the only
# phase with orange in the frame (its dot, its rim, the peek's Open pill). Asleep
# begins half a period after waiting does. Frames arrive only when something moved,
# so each one is held until the next one's time.
echo "finding the loop"
python3 - "$WORK/frames" "$WORK/list.txt" <<'EOF'
import glob, os, sys
from PIL import Image, ImageChops
frames = sorted(glob.glob(sys.argv[1] + '/f-*.png'))
times = [int(os.path.basename(f)[2:-4]) / 1000 for f in frames]
def orange(path):
    r, g, b = Image.open(path).convert('RGB').reduce(2).split()
    mask = ImageChops.multiply(ImageChops.multiply(r.point(lambda v: 255 if v > 200 else 0),
                                                   g.point(lambda v: 255 if 120 < v < 185 else 0)),
                               b.point(lambda v: 255 if v < 70 else 0))
    return mask.histogram()[255]
counts = [orange(f) for f in frames]
starts = [t for i, (t, c) in enumerate(zip(times, counts)) if c > 20 and (i == 0 or counts[i - 1] <= 20)]
starts = [t for t in starts if t > 0.5]          # a phase already under way at the start is not a start
if len(starts) < 2: sys.exit(f'fewer than two waiting phases in the recording: {starts}')
period = starts[1] - starts[0]
begin = starts[0] + period / 2
end = begin + period
if end > times[-1]: sys.exit('the recording ends before the loop does')
picked = [i for i, t in enumerate(times) if begin <= t < end]
# The frame on screen at `begin` is the last one before it.
first = max(i for i, t in enumerate(times) if t <= begin)
picked = sorted(set([first] + picked))
with open(sys.argv[2], 'w') as out:
    for n, i in enumerate(picked):
        start = begin if n == 0 else times[i]
        stop = times[picked[n + 1]] if n + 1 < len(picked) else end
        out.write(f"file '{frames[i]}'\nduration {stop - start:.3f}\n")
    out.write(f"file '{frames[picked[-1]]}'\n")
print(f'  waiting at {starts[0]:.2f}s, period {period:.2f}s, cut {begin:.2f}–{end:.2f}s, {len(picked)} frames')
EOF

# --- 3. compose -----------------------------------------------------------------
# Recorded at Retina scale, 1040×220 px; the GIF is 3/4 of that so it stays small.
ffmpeg -v error -y -f concat -safe 0 -i "$WORK/list.txt" \
    -vf "fps=30,format=yuv420p" -c:v libx264 -crf 18 -movflags +faststart "$OUT/demo.mp4"
ffmpeg -v error -y -i "$OUT/demo.mp4" \
    -filter_complex "[0:v]fps=15,scale=iw*3/4:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];[b][p]paletteuse=dither=none" \
    "$OUT/demo.gif"
ls -la "$OUT/demo.mp4" "$OUT/demo.gif"
