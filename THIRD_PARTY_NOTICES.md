# Third-party notices

CodeCat's own source code is MIT-licensed (see [LICENSE](LICENSE)). The mascot
artwork is not: every sprite pack below belongs to its author and ships under
that author's own terms. Licences were read on the source pages themselves, not
copied from secondary tables.

CodeCat has no other third-party dependencies — no Swift packages, no vendored
libraries, no fonts. Everything else it uses comes from macOS itself
(AppKit, SwiftUI, Foundation, IOKit, ImageIO).

## Bundled with the app

### LuizMelo — Pet Cats Pack

- **Author:** LuizMelo
- **Source:** https://luizmelo.itch.io/pet-cat-pack
- **Licence:** CC0 1.0 Universal (public domain dedication)
- **Attribution:** not required. The author's page adds: "Credit is not
  required, but I would appreciate it." CodeCat credits them anyway, in
  *About the assets*.
- **Files:** `Sources/CodeCatApp/Skins/luizmelo/` — six cats (`Cat-1`…`Cat-6`),
  50×50 px frames in horizontal strips. The author's original licence text is
  kept verbatim at `Sources/CodeCatApp/Skins/luizmelo/License.txt`.
- **Skins:** Ginger, Black, Siamese, Smoke, White, Tabby.

### mxmaze — 16-Bit Kitty (FREE)

- **Author:** Maze.Bit.Boutique (mxmaze)
- **Source:** https://mxmaze.itch.io/16-bit-kitty-free
- **Licence:** CC BY 4.0 — https://creativecommons.org/licenses/by/4.0/
- **Attribution:** **required.** The credit line is
  "Maze.Bit.Boutique (mxmaze), CC BY 4.0", and it is shown inside the app under
  *About the assets* as well as here and in the README.
- **Files:** `Sources/CodeCatApp/Skins/mxmaze/16x16-Brown.png` — one 48×48 sheet,
  a 3×3 grid of 16×16 frames.
- **Skin:** Plush.

## Downloaded at build time, not redistributed

### Elthen's Pixel Art Shop — 2D Pixel Art Cat Sprites

- **Author:** Elthen's Pixel Art Shop (Ahmet Avci)
- **Source:** https://elthen.itch.io/2d-pixel-art-cat-sprites
- **Licence:** no formal licence; the author's own terms apply —
  https://www.patreon.com/posts/27430241
- **Terms, in short:** free to use in commercial and non-commercial projects;
  **the assets themselves may not be resold or redistributed**; not for
  blockchain / NFT / play-to-earn projects; credit is not required.
- **Why it is not in this repository:** "may not be redistributed" covers a
  public git repository. The sheet is therefore *not* committed, and
  `scripts/fetch-optional-assets.sh` downloads it from itch.io onto the machine
  that builds the app. If it is absent, the *Silver* skin simply does not appear
  in the picker — nothing else changes.
- **Skin:** Silver (optional).

## The hand-drawn cat

The fallback cat in `Sources/CodeCatApp/CatView.swift` is drawn in SwiftUI
shapes by the author of CodeCat and is covered by the MIT licence above. It is
what you see if a sprite skin fails to load, and it is the source of the app
icon.
