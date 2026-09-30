#!/usr/bin/env bash
#
# Photographs the island from a `--demo` run of the debug build, for comparing
# with the Figma frames. In CodeCat, UI is verified by pictures, not by reading
# code: static review cannot see what a view draws.
#
#   scripts/dev/island-shot.sh NAME [app flags…]
#
#   NAME        output file stem: $SHOTS/NAME.png, or NAME-00.png… with BURST
#   app flags   passed to the app after --demo, e.g. --demo-phase=waiting --demo-expanded
#
# Environment:
#   SHOTS=/tmp/codecat-shots   where the PNGs go
#   CROP="760 96"              width and height in points, centred on the notch,
#                              from the top of the screen. 760×96 is the size of
#                              Figma's compact frames; 760×567 of the full list.
#   SETTLE=2.5                 seconds between launch and the first shot
#   BEFORE='…'                 shell code run after SETTLE and before shooting;
#                              $CGEV and the notch ($NX $NY $NW $NH) are exported
#   BURST=N                    N shots 50 ms apart instead of one
#   CURSOR=1                   draw the cursor into the shots
#   MODE=island                island | floating: which mascot the demo shows
#   AT="x y w h"               an absolute crop in points from the main screen's
#                              top-left corner, instead of CROP around the notch
#
# The installed CodeCat is stopped for the duration — two islands would share one
# notch — and started again from /Applications on exit. The debug binary keeps its
# settings in the `CodeCatApp` defaults domain (not the app's `com.codecat.app`),
# which is deleted on exit.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/.build/debug/CodeCatApp"
CGEV="$ROOT/.build/cgev"
SHOTS="${SHOTS:-/tmp/codecat-shots}"
CROP="${CROP:-760 96}"
SETTLE="${SETTLE:-2.5}"

die() { echo "island-shot: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "usage: island-shot.sh NAME [app flags…]"
NAME="$1"; shift
[ -x "$BIN" ] || die "no $BIN — run \`swift build\` first"
if [ ! -x "$CGEV" ] || [ "$ROOT/scripts/dev/cgev.swift" -nt "$CGEV" ]; then
    swiftc -O "$ROOT/scripts/dev/cgev.swift" -o "$CGEV" || die "could not build cgev"
fi
mkdir -p "$SHOTS"

WAS_RUNNING=false
if pgrep -x CodeCat >/dev/null; then
    WAS_RUNNING=true
    pkill -TERM -x CodeCat || true
    sleep 1
fi
APP_PID=""
cleanup() {
    if [ -n "$APP_PID" ]; then
        kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
    fi
    defaults delete CodeCatApp >/dev/null 2>&1 || true
    if [ "$WAS_RUNNING" = true ]; then open -a /Applications/CodeCat.app || true; fi
}
trap cleanup EXIT

defaults write CodeCatApp mascotDisplayMode -string "${MODE:-island}"
"$BIN" --demo "$@" >/dev/null 2>&1 &
APP_PID=$!
sleep "$SETTLE"

read -r NX NY NW NH <<<"$("$CGEV" notch)" || die "no notch on any screen"
export CGEV NX NY NW NH
read -r CW CH <<<"$CROP"
RECT="$(( NX + NW / 2 - CW / 2 )),$NY,$CW,$CH"
if [ -n "${AT:-}" ]; then
    read -r AX AY AW AH <<<"$AT"
    RECT="$AX,$AY,$AW,$AH"
fi
FLAGS=(-x -R"$RECT")
if [ "${CURSOR:-0}" = 1 ]; then FLAGS+=(-C); fi

if [ -n "${BEFORE:-}" ]; then eval "$BEFORE"; fi

if [ -n "${BURST:-}" ]; then
    PIDS=()
    for i in $(seq 0 $(( BURST - 1 ))); do
        screencapture "${FLAGS[@]}" "$SHOTS/$(printf '%s-%02d' "$NAME" "$i").png" &
        PIDS+=($!)
        sleep 0.05
    done
    wait "${PIDS[@]}"
    echo "$SHOTS/$NAME-00.png … $NAME-$(printf '%02d' $(( BURST - 1 ))).png"
else
    screencapture "${FLAGS[@]}" "$SHOTS/$NAME.png"
    [ -s "$SHOTS/$NAME.png" ] || die "screencapture wrote nothing"
    echo "$SHOTS/$NAME.png"
fi
