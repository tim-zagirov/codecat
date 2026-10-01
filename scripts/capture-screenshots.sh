#!/usr/bin/env bash
#
# The README's pictures of CodeCat, taken from the scripted demo feed rather than
# by waiting for real agents to reach the right state.
#
#   scripts/capture-screenshots.sh            # all of them, into docs/media/
#   scripts/capture-screenshots.sh island-peek
#
#   island          the closed island, an agent waiting       island.png
#   island-list     the open island, every kind of card       island-list.png
#   island-peek     the island opening itself for a question  island-peek.png
#   floating        the floating cat on its capsule, and      floating.png
#                   the list it opens                         floating-list.png
#   settings        the Settings window, General and Cat      settings-general.png
#                                                             settings-cat.png
#
# It runs the release binary, `.build/release/CodeCatApp --demo` (build it with
# `swift build -c release`), not an installed app. A binary outside a bundle keeps
# its settings in its own `CodeCatApp` defaults domain, so the display mode can be
# set for each shot there and the domain deleted on exit; the installed app's
# `com.codecat.app` settings are never read or written. `--demo` drives the state
# machine from `DemoFeed` and starts no socket, no transcript watcher and no power
# assertion, and its Connect… and Remove only say what they would do — it cannot
# disturb real sessions, `~/.claude/settings.json` or the Mac's sleep. `CODEX_HOME`
# points at an empty folder, so pets you imported stay out of the skin grid.
#
# Every picture holds CodeCat's own windows and nothing else. The island and the
# floating cat are recorded with ScreenCaptureKit filtered to the demo's process
# (`scripts/dev/own-windows.swift`) over a flat backdrop, then trimmed to what was
# drawn; the Settings window is shot alone with `screencapture -l`. A rectangle cut
# from the whole screen would carry the menu bar's other items or a window behind
# the cat into a file that gets published.
#
# Requirements, which need a human once:
#   * Screen Recording permission for whatever runs this (Terminal, iTerm…), in
#     System Settings → Privacy & Security → Screen Recording.
#   * A display with a notch, for the three island shots: the demo cannot draw the
#     island anywhere else.
#   * python3 with Pillow, for the trim.
# Keep the pointer away from the notch and the bottom-right corner while it runs:
# a hover there opens what is being photographed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/release/CodeCatApp"
OUT="$ROOT/docs/media"
TOOL="$ROOT/.build/own-windows"
CGEV="$ROOT/.build/cgev"
DOMAIN=CodeCatApp
WORK="$(mktemp -d)"

die() { echo "capture-screenshots: $*" >&2; exit 1; }

[ -x "$BIN" ] || die "no $BIN — run \`swift build -c release\` first"
python3 -c 'import PIL' 2>/dev/null || die "python3 needs Pillow (pip3 install Pillow)"
mkdir -p "$OUT" "$WORK/codex"

# The helpers are compiled on demand, like scripts/dev/island-shot.sh does with cgev.
build_tool() {
    # $1: the binary, $2: its source.
    if [ ! -x "$1" ] || [ "$2" -nt "$1" ]; then
        swiftc -O "$2" -o "$1" || die "could not build $1"
    fi
}
build_tool "$TOOL" "$ROOT/scripts/dev/own-windows.swift"
build_tool "$CGEV" "$ROOT/scripts/dev/cgev.swift"

# An installed CodeCat has to step aside for the duration: two islands would share
# one notch. It is stopped with SIGTERM, the app's graceful path (see main.swift),
# and started again on the way out — including if this script fails partway.
INSTALLED="/Applications/CodeCat.app"
INSTALLED_WAS_RUNNING=false
if pgrep -x CodeCat >/dev/null; then
    INSTALLED_WAS_RUNNING=true
    echo "stopping the installed CodeCat for the duration"
    pkill -TERM -x CodeCat || true
    sleep 1
fi

APP_PID=""
stop() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
    fi
}
cleanup() {
    stop
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    rm -rf "$WORK"
    if [ "$INSTALLED_WAS_RUNNING" = true ] && [ -d "$INSTALLED" ]; then
        echo "restarting the installed CodeCat"
        open -a "$INSTALLED" || true
    fi
}
trap cleanup EXIT

launch() {
    # $1: island | floating — a stored setting, not a flag: the display mode is the
    # user's choice and has one source of truth. $2..: the demo's flags.
    local mode="$1"; shift
    defaults delete "$DOMAIN" >/dev/null 2>&1 || true
    defaults write "$DOMAIN" mascotDisplayMode -string "$mode"
    CODEX_HOME="$WORK/codex" "$BIN" --demo "$@" >/dev/null 2>&1 &
    APP_PID=$!
}

read -r SCREEN_W SCREEN_H <<<"$("$TOOL" screen)"

# A rectangle centred on the notch, from the top of the screen: "x y w h".
NOTCH="$("$CGEV" notch 2>/dev/null || true)"
need_notch() { [ -n "$NOTCH" ] || die "no notch on any screen — the island shots need one"; }
around_notch() {
    local nx ny nw nh
    read -r nx ny nw nh <<<"$NOTCH"
    echo "$(( nx + nw / 2 - $1 / 2 )) 0 $1 $2"
}

# The union of the demo's windows below the status-bar level, 40 pt of air round it,
# kept on screen: the floating cat sits wherever its layout puts it, and the list
# opens above or below it depending on the room.
around_windows() {
    "$TOOL" windows "$APP_PID" | awk -v sw="$SCREEN_W" -v sh="$SCREEN_H" '
        $2 != 25 { r = $3 + $5; b = $4 + $6
                   if (n++ == 0) { x0 = $3; y0 = $4; x1 = r; y1 = b; next }
                   if ($3 < x0) x0 = $3; if ($4 < y0) y0 = $4; if (r > x1) x1 = r; if (b > y1) y1 = b }
        END { if (n == 0) exit 1
              x0 -= 40; y0 -= 40; x1 += 40; y1 += 40
              if (x0 < 0) x0 = 0; if (y0 < 0) y0 = 0; if (x1 > sw) x1 = sw; if (y1 > sh) y1 = sh
              print x0, y0, x1 - x0, y1 - y0 }'
}

# Records half a second of the rect and keeps the last frame, trimmed to what was
# drawn on the backdrop plus 24 pt — a phase's tone cross-fade has settled by then,
# and the trim makes every picture fit its content however tall the list grew.
shoot() {
    # $1: output name, $2: "x y w h".
    local name="$1" x y w h
    read -r x y w h <<<"$2"
    rm -rf "$WORK/$name"
    "$TOOL" record "$APP_PID" 0.5 "$WORK/$name" "$x" "$y" "$w" "$h" >/dev/null \
        || die "nothing recorded for $name (Screen Recording permission? a locked screen?)"
    python3 - "$WORK/$name" "$OUT/$name.png" <<'EOF'
import glob, sys
from PIL import Image, ImageChops
frames = sorted(glob.glob(sys.argv[1] + '/f-*.png'))
image = Image.open(frames[-1]).convert('RGB')
corners = [image.getpixel((x, y)) for x in (0, image.width - 1) for y in (0, image.height - 1)]
backdrop = Image.new('RGB', image.size, max(set(corners), key=corners.count))
drawn = ImageChops.difference(image, backdrop).convert('L').point(lambda v: 255 if v > 6 else 0).getbbox()
if drawn is None: sys.exit(f'{sys.argv[2]}: nothing but the backdrop — CodeCat drew nothing there')
pad = 48   # 24 pt at Retina scale
l, t, r, b = drawn
image.crop((max(l - pad, 0), max(t - pad, 0), min(r + pad, image.width), min(b + pad, image.height))).save(sys.argv[2])
EOF
    echo "  $OUT/$name.png"
}

capture_island() {
    need_notch
    echo "the closed island, an agent waiting:"
    launch island --demo-phase=waiting
    sleep 4
    shoot island "$(around_notch 560 90)"
    stop
}

capture_island_list() {
    need_notch
    echo "the open island:"
    launch island --demo-phase=showcase --demo-expanded
    sleep 4
    shoot island-list "$(around_notch 560 760)"
    stop
}

capture_island_peek() {
    need_notch
    echo "the island peeking for a question:"
    launch island --demo-peek=waiting
    # The peek starts 1.5 s after launch and holds for 3 s; the frame kept is the last
    # of half a second recorded from 1.9 s, so 2.4 s in: open, its line in, most of
    # the hold still to run.
    sleep 1.9
    shoot island-peek "$(around_notch 560 130)"
    stop
}

capture_floating() {
    echo "the floating cat, and its list:"
    local rect
    launch floating --demo-phase=waiting
    sleep 4
    rect="$(around_windows)" || die "no floating cat on screen"
    shoot floating "$rect"
    stop
    launch floating --demo-phase=waiting --demo-expanded
    sleep 4
    rect="$(around_windows)" || die "no floating list on screen"
    shoot floating-list "$rect"
    stop
}

capture_settings() {
    echo "the Settings window:"
    local pane id
    for pane in general cat; do
        launch island "--demo-settings=$pane"
        sleep 3
        # The Settings window is the demo's only titled window: 720 pt wide, layer 0.
        id="$("$TOOL" windows "$APP_PID" | awk '$2 == 0 && $5 == 720 { print $1; exit }')"
        [ -n "$id" ] || die "no Settings window on screen"
        screencapture -x -l"$id" "$OUT/settings-$pane.png"
        [ -s "$OUT/settings-$pane.png" ] || die "screencapture wrote nothing for settings-$pane"
        echo "  $OUT/settings-$pane.png"
        stop
    done
}

case "${1:-all}" in
    all)
        capture_island
        capture_island_list
        capture_island_peek
        capture_floating
        capture_settings
        ;;
    island)       capture_island ;;
    island-list)  capture_island_list ;;
    island-peek)  capture_island_peek ;;
    floating)     capture_floating ;;
    settings)     capture_settings ;;
    *) die "unknown shot '$1' (island | island-list | island-peek | floating | settings | all)" ;;
esac
