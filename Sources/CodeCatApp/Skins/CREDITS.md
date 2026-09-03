# Mascot sprite assets

Authors, sources and licences for every pack live in
[`THIRD_PARTY_NOTICES.md`](../../../THIRD_PARTY_NOTICES.md) at the repository
root — that is the file to read for the licensing side. This one records how the
files are wired into the build, which is what breaks if someone moves them.

Licences were read on the itch.io pages themselves, not taken from secondary
tables. All three packs are "name your own price", i.e. free.

## What is here, and what is not

- `luizmelo/` — CC0. Committed. The author's own licence text is kept verbatim
  in `luizmelo/License.txt`.
- `mxmaze/` — CC BY 4.0. Committed. Attribution is a legal obligation here, not
  a courtesy, and is shown in the app under *About the assets*.
- `elthen/` — **not committed.** The author allows using the sprites but not
  passing the assets themselves on, so this directory is gitignored and
  `scripts/fetch-optional-assets.sh` downloads the sheet onto the machine that
  builds the app. Without it the *Silver* skin is simply absent from the picker
  (`MascotSkin.bundled == false` is what makes that a supported state rather
  than an error).

`fetch-assets.sh` is the generic downloader those scripts call: it walks one
itch.io page's free download flow and saves every file it offers.

## How the app finds these files

They are declared as resources of the `CodeCatApp` target in `Package.swift`
(`.copy("Skins")`). `SpriteSheetStore.skinsRoot` resolves them directly, without
`Bundle.module`: first `Bundle.main.resourceURL/Skins` (the assembled `.app`,
`Contents/Resources/Skins`), then
`Bundle.main.bundleURL/CodeCat_CodeCatApp.bundle/Skins` (`swift run`, and any
future test host). If neither exists it returns `nil` and the caller falls back
to the hand-drawn cat.

`Bundle.module` is deliberately never touched: its generated accessor calls
`fatalError` when it cannot find its bundle, and "the sheet did not make it into
the build" is precisely the case that has to degrade, not crash.
