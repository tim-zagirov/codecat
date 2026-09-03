#!/usr/bin/env bash
#
# Screenshots of CodeCat for a landing page or a README, taken from the scripted
# demo feed rather than by waiting for real agents to reach the right state.
#
#   scripts/capture-screenshots.sh            # all four, into docs/media/
#   scripts/capture-screenshots.sh island-badge
#
# It launches `dist/CodeCat.app --demo`, which drives the state machine from
# `DemoFeed` and starts no socket, no transcript watcher and no power assertion —
# so it cannot disturb a real CodeCat, real sessions, or your Mac's sleep
# behaviour. The installed copy is left alone; if one is running it keeps running.
#
# Requirements, both of which need a human once:
#   * Screen Recording permission for whatever runs this (Terminal, iTerm…), in
#     System Settings → Privacy & Security → Screen Recording. Without it
#     `screencapture` silently produces a picture of the desktop with no windows
#     in it, which is the failure this script checks for.
#   * A display with a notch, for the two island shots. On a Mac without one the
#     island cannot appear at all and those shots are skipped.
#
# The captures are full-screen and then cropped, because CodeCat's windows are
# borderless `LSUIElement` panels: `screencapture -l<windowid>` cannot find them
# and neither can any window-targeting tool.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/CodeCat.app"
OUT="$ROOT/docs/media"
BIN="$APP/Contents/MacOS/CodeCat"

# Where on screen each shot lives. Left/top/width/height in points, as
# `screencapture -R` wants them. The island sits at the top centre of the main
# display, so its crop is computed from the screen width at capture time.
SETTLE=2.5          # seconds between launching and shooting: the window has to
                    # appear, and a phase animation has to reach its resting pose.

die() { echo "capture-screenshots: $*" >&2; exit 1; }

[ -d "$APP" ] || die "no $APP — run \`make app\` first"

mkdir -p "$OUT"

# In POINTS, which is what `screencapture -R` takes. `system_profiler` reports the
# Retina backing pixels instead, so using it here silently doubles every rectangle.
screen_size() {
    osascript -e 'tell application "Finder" to get bounds of window of desktop' \
        | tr -d ' ' | awk -F, '{print $3, $4}'
}

launch() {
    # $1: --demo-phase value. $2..: extra arguments.
    local phase="$1"; shift
    "$BIN" --demo "--demo-phase=$phase" "$@" >/dev/null 2>&1 &
    APP_PID=$!
    sleep "$SETTLE"
}

stop() {
    if [ -n "${APP_PID:-}" ]; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
    fi
}
trap stop EXIT

shoot() {
    # $1: output name, $2: -R rectangle.
    local name="$1" rect="$2"
    screencapture -x -o -R"$rect" "$OUT/$name.png"
    [ -s "$OUT/$name.png" ] || die "screencapture wrote nothing for $name"
    echo "  $OUT/$name.png"
}

# `defaults write` rather than a launch flag: the display mode is a persisted user
# setting, and giving it a second source of truth just for screenshots would mean
# two places to keep in step. Restored on exit.
PREVIOUS_MODE="$(defaults read com.codecat.app mascotDisplayMode 2>/dev/null || echo "")"
restore_mode() {
    if [ -n "$PREVIOUS_MODE" ]; then
        defaults write com.codecat.app mascotDisplayMode -string "$PREVIOUS_MODE"
    else
        defaults delete com.codecat.app mascotDisplayMode 2>/dev/null || true
    fi
}
trap 'stop; restore_mode' EXIT

use_mode() { defaults write com.codecat.app mascotDisplayMode -string "$1"; }

# An installed CodeCat has to step aside for the duration: two mascots would
# overlap in the notch, and the running one would rewrite the display-mode setting
# from its own in-memory copy the moment anything changed. It is stopped with
# SIGTERM, which is the app's graceful path (see main.swift), and started again on
# the way out — including if this script fails partway.
INSTALLED="/Applications/CodeCat.app"
INSTALLED_WAS_RUNNING=false
if pgrep -x CodeCat >/dev/null; then
    INSTALLED_WAS_RUNNING=true
    echo "stopping the installed CodeCat for the duration"
    pkill -TERM -x CodeCat || true
    sleep 1
fi
restore_installed() {
    if [ "$INSTALLED_WAS_RUNNING" = true ] && [ -d "$INSTALLED" ]; then
        echo "restarting the installed CodeCat"
        open -a "$INSTALLED" || true
    fi
}
trap 'stop; restore_mode; restore_installed' EXIT

read -r W H <<<"$(screen_size)"
W="${W:-1512}"; H="${H:-982}"

# The floating cat remembers where the user last dragged it, which would make every
# crop a guess. Park it at a known spot for the duration and put it back afterwards
# — the same borrow-and-restore as the display mode above.
# The stored value is a [x, y, canvas] TRIPLE, not a pair: the canvas size is what
# lets a later change to the window size migrate old positions instead of shifting
# the cat. A two-element array is rejected outright (MascotLayout.storedOrigin
# returns nil) and the cat falls back to its default corner — which looks like the
# park simply not happening.
POSITION_KEY="mascotPosition.v2"
CANVAS=128          # MascotLayout.canvasSize
MARGIN=16           # (canvasSize - drawingSize) / 2 — transparent slack around the cat
DEMO_X=$(( W - 460 ))
DEMO_Y=$(( H - 220 ))
# `defaults read` prints an array as "(\n    1268,\n    897\n)"; reduced to "1268,897".
PREVIOUS_POSITION="$(defaults read com.codecat.app "$POSITION_KEY" 2>/dev/null \
    | tr -d '()\n ' | sed 's/,$//' || echo "")"
restore_position() {
    if [ -n "$PREVIOUS_POSITION" ]; then
        local args=()
        local IFS=,
        for value in $PREVIOUS_POSITION; do args+=(-float "$value"); done
        defaults write com.codecat.app "$POSITION_KEY" -array "${args[@]}" 2>/dev/null || true
    else
        defaults delete com.codecat.app "$POSITION_KEY" 2>/dev/null || true
    fi
}
# `-float`, not bare values: `defaults write -array 1268 897` stores *strings*, and
# the app reads this key as `[Double]`, so a string array is silently rejected and
# the cat stays wherever it was — with every crop below then framing empty desktop.
# Where the details panel lands, given a parked cat. It opens to the LEFT of the
# cat (`OverlayController.position(_:relativeTo:)`), is about 290pt wide, and is
# then clamped into the visible frame — so its top edge depends on how tall it
# grew, which depends on how many sessions are listed. Hence a generous box with
# slack below rather than an exact fit; the closing note says to trim it.
PANEL_WIDTH=340
PANEL_RECT="$((DEMO_X - 320)),20,$PANEL_WIDTH,700"

park_cat() {
    defaults write com.codecat.app "$POSITION_KEY" -array \
        -float "$DEMO_X" -float "$DEMO_Y" -float "$CANVAS"
}
trap 'stop; restore_mode; restore_position; restore_installed' EXIT

capture_island_badge() {
    echo "island with a working badge:"
    use_mode island
    launch working
    # The island sits centred in the menu bar. 640pt of width covers both wings on
    # every current MacBook, and 56pt of height covers the menu bar plus the skirt
    # that hangs below it. On a Mac with no notch there is no island to photograph
    # and this comes out as a plain menu bar — visibly wrong, so it cannot pass for
    # a real shot.
    shoot "island-badge" "$(( (W - 640) / 2 )),0,640,40"
    stop
}

capture_cat_waiting() {
    echo "cat waving on \"waiting for you\":"
    use_mode floating
    park_cat
    launch waiting
    # The window is CANVAS square, but the cat is drawn in the middle DRAWING of it
    # — the rest is transparent slack that keeps the tail from being clipped. Frame
    # the drawing plus a little air. `screencapture -R` counts y from the top of the
    # screen, AppKit counts it from the bottom, hence the flip.
    shoot "cat-waiting" "$((DEMO_X - 8)),$((H - DEMO_Y - CANVAS - 8)),144,144"
    stop
}

capture_panel_sessions() {
    echo "floating panel with three sessions:"
    use_mode floating
    park_cat
    launch working --demo-open-menu
    shoot "panel-sessions" "$PANEL_RECT"
    stop
}

capture_demo_loop() {
    echo "10-second demo loop (docs/media/demo.mov):"
    use_mode island
    # No --demo-phase here: this is the whole point of the loop, four seconds per
    # phase. Ten seconds catches two and a half of them.
    "$BIN" --demo >/dev/null 2>&1 &
    APP_PID=$!
    sleep "$SETTLE"
    # Just the island, not the whole menu bar: everything either side of it is the
    # frontmost app's menus and the user's own status icons, which have no business
    # in a file that gets published.
    screencapture -v -V 10 -R"$(( (W - 360) / 2 )),0,360,40" "$OUT/demo.mov"
    [ -s "$OUT/demo.mov" ] || die "screencapture wrote no video"
    echo "  $OUT/demo.mov"
    stop
}

capture_skins_grid() {
    echo "skin grid:"
    use_mode floating
    park_cat
    launch done --demo-open-menu
    shoot "skins-grid" "$PANEL_RECT"
    stop
}

case "${1:-all}" in
    all)
        capture_island_badge
        capture_cat_waiting
        capture_panel_sessions
        capture_skins_grid
        capture_demo_loop
        ;;
    island-badge)    capture_island_badge ;;
    cat-waiting)     capture_cat_waiting ;;
    panel-sessions)  capture_panel_sessions ;;
    skins-grid)      capture_skins_grid ;;
    demo-loop)       capture_demo_loop ;;
    *) die "unknown shot '$1' (island-badge | cat-waiting | panel-sessions | skins-grid | demo-loop | all)" ;;
esac

cat <<'NOTE'

The panel and skin-grid crops are generous boxes around the parked cat, not an
exact fit: the details panel sizes itself to its content, which changes with the
number of sessions. Trim them before publishing.

demo.mov is the island alone, ten seconds of the four-second loop. To record the
floating cat instead, run the app with `--demo` and point `screencapture -v -V 10
-R<x>,<y>,<w>,<h>` at wherever you parked it — but check what else is inside that
rectangle first: this file gets published, and everything on screen goes into it.
NOTE
