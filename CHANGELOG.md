# Changelog

All notable changes to CodeCat. Dates are the day the work was finished, not the
day it was tagged. Derived from the commit history; the design decisions behind
each release are in `docs/superpowers/specs/`.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
CodeCat uses [semantic versioning](https://semver.org/) — pre-1.0, so the minor
number carries breaking changes.

## [0.3.0] — 2026-09-03

The release that makes CodeCat publishable: an English interface, a licence, and
a build a stranger can trust.

### Added
- **English UI**, with Russian as a second localisation. Every user-visible
  string moved into `Resources/{en,ru}.lproj/Localizable.strings`, and a test
  keeps the two catalogs and the call sites in step.
- **MIT licence**, plus `THIRD_PARTY_NOTICES.md` naming every sprite pack with
  its author, source and terms.
- **An app icon**, generated from the hand-drawn cat by
  `scripts/make-icon.swift` and wired into the bundle and the disk image.
- **A DMG that installs by dragging** — the image now carries an `/Applications`
  symlink and a volume icon.
- **GitHub Actions CI** running `swift test` and `make bundle` on every push. No
  signing in CI, on purpose: a Developer ID key does not belong in a repository
  secret.
- `CONTRIBUTING.md`, issue templates, `docs/release.md`, `CHANGELOG.md`, and
  `docs/how-this-was-built.md`.

### Changed
- The manual verification checklist moved out of the README into
  `docs/verification-checklist.md` and gained an item for the localisation.
- `README.md` was rewritten for someone who has never seen the project;
  `README.ru.md` mirrors it.
- Session status words now come from one place (`SessionStatus.title`) instead
  of two hand-written copies.
- `make release` asks Gatekeeper about the app with `-t exec` and about the disk
  image with `-t open`, rather than assessing the app as if it were an installer.

### Removed
- **Elthen's sprite sheet is no longer in the repository.** The author allows
  using the sprites but not redistributing the files, which a public repository
  would do. It is now downloaded at build time by
  `scripts/fetch-optional-assets.sh`; when it is absent the "Silver" skin simply
  does not appear, and the other seven are unaffected. The file was also purged
  from git history, so this release requires a force-push.

### Fixed
- A skin whose sheets are missing no longer produces an error alert on launch —
  it is filtered out of the picker instead, and a stored selection pointing at it
  migrates silently to the default.

## [0.2.0] — 2026-09-01

The island, and the first release that could be diagnosed after the fact.

### Added
- **Island display mode**: a black slab drawn around the notch of a built-in
  display, with the cat in one wing and a session counter in the other. Hovering
  opens a short menu, clicking opens the full one, and both are the same window
  morphing rather than a popover — so the shape can flow into the screen edge.
- **A log file** at `~/Library/Application Support/CodeCat/codecat.log`, written
  by both the app and the hook. An `LSUIElement` app has no console; before this,
  a misbehaving build could only be investigated by rebuilding a stand-in.
- **Remove Claude Code hooks…** in the menu. `HooksInstaller.remove` had been
  written and tested since 0.1.0 but was never reachable, so an uninstalled app
  left five entries calling a binary that no longer existed.
- **Developer ID signing and notarisation** (`make sign`, `make notarize`,
  `make release`), with the entitlement that gives hardened runtime back the
  right to send Apple events — without which jump-to-session breaks in exactly
  the builds other people would download.
- A fifth hook event, `UserPromptSubmit`: the precise moment an agent starts
  work. The transcript says the same thing up to 21 seconds later.
- **Session route caching on disk**, so clicking a session still jumps to it
  after CodeCat restarts.
- Subagent work is marked as such in the session list.
- The version is printed in the menu, and `CFBundleVersion` is derived from the
  commit count — before this every build claimed to be build 1.
- "Hide the cat when nothing is running", working in both display modes.

### Changed
- "Done" is now a transition — stretch, lie down, sleep — instead of a
  one-second action looped for ten minutes.
- An open-but-idle session counts as `.idle`, not `.working`. The badge said "1"
  with no agent running because `SessionStart` means "a session appeared", not
  "an agent started".
- End of turn is detected from the transcript (`stop_reason == "end_turn"`), not
  only from the `Stop` hook, which does not always arrive.

### Fixed
- Quitting no longer drops the Mac into sleep 37 ms later: clearing
  `disablesleep` made the kernel re-read power settings and act on all the idle
  time accumulated while the flag was up.
- The closed-lid daemon no longer rewrites power preferences as root once a
  minute forever while CodeCat is not running — 1957 needless runs in two days on
  the development machine.
- The mascot is visible immediately after a restart, even mid-task. Measured
  blindness before the fix: 4 to 89 seconds.
- Hook events are no longer lost under load from several projects at once.
- The badge's number and its colour were counting different sets of sessions.

## [0.1.0] — 2026-08-30

The MVP. Everything the product promises, working end to end.

### Added
- **Session tracking** for every local Claude Code session, CLI and desktop, via
  four hook events over a unix datagram socket plus transcript watching in
  `~/.claude/projects` for the detail.
- **The cat**: a hand-drawn SwiftUI mascot in a floating window, whose pose
  follows the aggregate state of every session — asleep, working, waving a paw
  when an agent needs you.
- **Eight sprite skins** from three free packs, picked from a grid of live
  previews, with an "About the assets" section naming every author and licence.
- **Keeping the Mac awake** while agents work, through an IOKit power assertion
  with a grace period and a battery floor.
- **Closed-lid mode**: a narrow sudoers rule for two exact `pmset` command lines
  and a launch daemon that clears the flag if CodeCat is not running.
- **Jump to session**: clicking a row switches to the exact terminal tab a
  session lives in, found by walking the hook's own process ancestry. Every
  failure path says what happened and what it did instead.
- **"While you were away"**: a summary of what happened while the screen was
  locked.
- Safe merging of CodeCat's hooks into `~/.claude/settings.json`, preserving
  every other key and other people's hook entries.

[0.3.0]: https://github.com/tim-zagirov/codecat/releases/tag/v0.3.0
[0.2.0]: https://github.com/tim-zagirov/codecat/releases/tag/v0.2.0

0.1.0 has no tag: it predates tagging, and inventing one now would put a
version marker on a commit that never shipped under that name. Its entry above
is reconstructed from the history.
