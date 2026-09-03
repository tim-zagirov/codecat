#!/usr/bin/env bash
#
# Downloads the sprite sheets that this repository is not allowed to redistribute.
#
# Today that is exactly one: Elthen's "2D Pixel Art Cat Sprites". The author's
# terms (https://www.patreon.com/posts/27430241) allow using the sprites in a
# project but forbid passing the assets themselves on, which a public git
# repository would do. So the sheet is fetched onto the build machine instead and
# the destination is gitignored.
#
# Failure is not fatal on purpose. This script runs from `make bundle`, where the
# only consequence of not having the file is that one optional skin ("Silver")
# does not appear in the picker — CodeCat has seven other cats. A build must not
# break because itch.io is down, because the machine is offline, or because the
# page's download flow changed.
#
# Usage: scripts/fetch-optional-assets.sh [--force]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$ROOT/Sources/CodeCatApp/Skins/elthen"
SHEET="Cat Sprite Sheet.png"
PAGE="https://elthen.itch.io/2d-pixel-art-cat-sprites"
# The registry in MascotSkins declares an 8x10 grid of 32x32 frames. Selecting the
# file by its dimensions rather than by name is what makes this survive the author
# renaming a file inside the archive.
WANT_W=256
WANT_H=320

warn() { echo "fetch-optional-assets: $*" >&2; }

if [ "${1:-}" != "--force" ] && [ -f "$DEST/$SHEET" ]; then
    echo "fetch-optional-assets: already have $DEST/$SHEET"
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! bash "$ROOT/Sources/CodeCatApp/Skins/fetch-assets.sh" "$PAGE" "$tmp/download" >"$tmp/log" 2>&1; then
    warn "download failed; the optional \"Silver\" skin will not be available."
    warn "itch.io page: $PAGE"
    sed 's/^/  | /' "$tmp/log" >&2
    exit 0
fi

mkdir -p "$tmp/unpacked"
shopt -s nullglob
for archive in "$tmp/download"/*.zip; do
    unzip -q -o "$archive" -d "$tmp/unpacked" || warn "could not unpack $(basename "$archive")"
done
shopt -u nullglob

match=""
while IFS= read -r png; do
    w="$(sips -g pixelWidth  "$png" 2>/dev/null | awk '/pixelWidth/  {print $2}')"
    h="$(sips -g pixelHeight "$png" 2>/dev/null | awk '/pixelHeight/ {print $2}')"
    if [ "$w" = "$WANT_W" ] && [ "$h" = "$WANT_H" ]; then match="$png"; break; fi
done < <(find "$tmp" -type f -iname '*.png')

if [ -z "$match" ]; then
    warn "no ${WANT_W}x${WANT_H} sheet in the download; the \"Silver\" skin will not be available."
    warn "downloaded files:"
    find "$tmp/download" "$tmp/unpacked" -type f 2>/dev/null | sed 's/^/  | /' >&2
    exit 0
fi

mkdir -p "$DEST"
cp "$match" "$DEST/$SHEET"
echo "fetch-optional-assets: installed $DEST/$SHEET (from $(basename "$match"))"
