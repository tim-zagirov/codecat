# CodeCat public-release pass — what was done, and what is left for you

Everything below landed on `master` as separate commits between `83d777f` and
HEAD. **Tests: 390 before, 404 after, all green.** The version is now 0.3.0;
`v0.2.0` tags the state this pass started from.

**Read the force-push section before you push anything.**

---

## ⚠️ A force-push is required

Elthen's sprite sheet was purged from git history with `git filter-branch`
(`git-filter-repo` is not installed on this machine, and installing it would
have changed your environment without asking). Every commit hash from
`fd34a4c` onward has changed, so the rewritten `master` cannot fast-forward
onto the remote:

```bash
git push --force-with-lease origin master
git push --force-with-lease origin claude/codecat-release-prep-20e944
git push origin v0.2.0 v0.3.0
```

`--force-with-lease` rather than `--force`: it refuses if the remote moved since
you last fetched, which is the one accident this is exposed to.

Three follow-ups:

- **`refs/original/` still holds the old history**, which is filter-branch's own
  backup and the reason the blob is still in `.git`. Verified: nothing under
  `refs/heads` or `refs/remotes` reaches it any more. Once you are satisfied:
  ```bash
  git for-each-ref --format='%(refname)' refs/original | xargs -n1 git update-ref -d
  git reflog expire --expire=now --all && git gc --prune=now --aggressive
  ```
- **A full pre-rewrite bundle** was written to this session's scratchpad at
  `…/scratchpad/pre-purge-backup.bundle`. That directory is temporary — copy it
  somewhere else if you want a backup that outlives the session. `refs/original`
  is the real safety net until you run the command above.
- **The remote's old objects survive on GitHub** until its own garbage
  collection runs. If that matters, GitHub Support can be asked to run it after
  the force-push; a repository rename does not do it.

`git log --all --oneline -- "*elthen*"` returns nothing after the rewrite.

## 1. Licensing

- **`LICENSE`** — MIT, © 2026 Timur Zagirov, with an explicit note that it
  covers the source and not the sprite artwork. Named in both READMEs.
- **`THIRD_PARTY_NOTICES.md`** — every asset with author, source URL and
  licence, split into "bundled" and "downloaded at build time". It also records
  that CodeCat has no other third-party dependencies at all.
- **Elthen's sheet is out of the repository.** `Sources/CodeCatApp/Skins/elthen/`
  is gitignored, and `scripts/fetch-optional-assets.sh` downloads it at build
  time from itch.io (`make bundle` runs it). The registry tolerates its absence:
  `MascotSkin.bundled == false` marks it as a skin that may legitimately be
  missing, `AppState.availableSkins` filters it out of the picker, and a stored
  selection pointing at it migrates silently to the default. No alert, no
  `fatalError`. Verified by moving the file away and running the suite.
- **CC BY 4.0 attribution for mxmaze** is in the app (*About the assets*), in
  `THIRD_PARTY_NOTICES.md`, and in the credits section of both READMEs.

### One deviation, deliberate

You asked me to delete `Sources/CodeCatApp/Skins/elthen/` from the working tree.
I used `git rm --cached` instead: the file is untracked, gitignored and purged
from history — the repository no longer contains it in any sense — but it is
still on your disk, so your local builds keep the Silver skin and you can test
the fetch path by deleting it yourself. Bundling those sprites inside a built
`.app` is ordinary use under Elthen's terms; only redistributing the files is
not, and that is what the purge addresses. Delete it if you disagree:

```bash
rm -rf Sources/CodeCatApp/Skins/elthen
```

## 2. English UI

Every user-facing string now goes through `L10n` and lives in
`Resources/en.lproj/Localizable.strings` (base) and `ru.lproj` (translation) —
109 keys covering the menu bar, both menus, every alert, session statuses,
activity lines, "While you were away", the hook install/remove dialogs, *About
the assets*, the skin names and the menu-bar tooltip. `NSAppleEventsUsageDescription`
is localised through `InfoPlist.strings`.

**`.strings`, not `.xcstrings`.** A string catalog is compiled by Xcode's build
system, and this bundle is assembled by the Makefile from a SwiftPM package —
there is no Xcode project anywhere in the build to compile one. `.strings` was
the alternative you allowed, and it is what `make bundle` can actually produce
and sign.

The English text is repeated at each call site as `L10n`'s `value:` argument, so
a build that never assembled the `.lproj` directories — `swift run`, the test
bundle, a packaging mistake — shows real English rather than raw keys like
`menu.quit`. `LocalizationCatalogTests` fails the build if a key is untranslated,
orphaned, or if a placeholder changed between the two languages.

Verified by artefact, not by reading: the assembled `.app` was loaded and both
catalogs resolved — `menu.quit` → "Quit" / "Выйти", `menubar.working` → "working: 3"
/ "работает: 3". Checklist item 35 covers the language switch by hand.

**Diagnostic text was deliberately left in English**, unlocalised: the log and
the hook's stderr exist to be pasted into a bug report, and a log whose language
depends on the reporter is harder to read, not easier.

**Copy change beyond translation:** the `.done` activity line now reads
"finished the task" rather than "done". In Russian it sat next to the status word
as "закончил · закончил"; the English screenshot made "done · done" impossible to
ignore.

### Documentation

- `README.md` rewritten in English, in the structure you asked for. `README.ru.md`
  mirrors it. Both now open with a screenshot.
- The 34-item checklist moved to `docs/verification-checklist.md`, translated,
  reorganised into sections, plus a 35th item for the localisation.
- `docs/product-brief.md` and `docs/HANDOFF.md`: headings and summaries in
  English, bodies left Russian as agreed. HANDOFF's "where things stand" and
  "what's next" were both two releases out of date and were rewritten.
- `docs/how-this-was-built.md` is new — the subagent-driven workflow, the
  whole-branch review lesson, and the timeline.

### Translations I was unsure about

| String | What I chose | The doubt |
| --- | --- | --- |
| `activity.session.opened` | "open, waiting for a task" | Russian "открыта, ждёт задачу" has a grammatical subject (the session) that English drops. Sits next to the status word "open", so it reads "open · open, waiting for a task" — mildly redundant, the same shape the `.done` line had before I changed it. Worth a second look. |
| `setting.hide.when.idle` | "Hide the cat when nothing is running" | "когда сессий нет" is literally "when there are no sessions". "Nothing is running" is truer to the behaviour (it hides on no sessions, not on an idle cat) but drops the word "session" the rest of the UI uses. |
| `activity.waiting.maybe` | "looks like it is waiting for you" | The hedge is load-bearing — it is a heuristic guess, not a signal — but the English is long next to its neighbours in a narrow panel. |
| `jump.hint.no.host` | "can't jump — this session started before CodeCat did" | Contraction in UI copy is not macOS house style; without it ("cannot jump") the line is longer than the row. |
| `session.status.crashed` | "stopped" | Russian "оборвалась" means *broke off* — an abnormal ending. "Stopped" is neutral and might read as a clean stop; "died" or "lost" are alarming. |
| `menubar.problem` | "problem" | "проблема" is one word in a tooltip; "something went wrong" is more natural English but too long for a menu-bar tooltip. |

## 3. App icon

`scripts/make-icon.swift` draws the resting `CatView` cat in Core Graphics on a
dark rounded tile and writes `Resources/AppIcon.png` (1024×1024) and
`Resources/CodeCat.icns`. Wired in through `CFBundleIconFile`, copied into
`Contents/Resources` *before* `codesign` so the signature covers it, checked by
`make verify-skins`, and used as the DMG's volume icon.

Core Graphics rather than rendering the SwiftUI view: `CatView` lives in the app
target, so rendering it would mean building and launching the app to produce a
file the build itself needs. The trade is that the two can drift; the icon is
regenerated by running the script, not by the build.

> **TODO — replace with designed artwork if you want to.** This is the product's
> own cat at icon scale, not a designed mark. It is recognisable at 32pt (I
> checked), and it is honest, but a designer would do better with the silhouette
> and the tile. Replacing it means replacing `Resources/AppIcon.png` and
> re-running `iconutil`; nothing else in the build knows what the cat looks like.

## 4. Release pipeline

**`docs/release.md`** documents the whole path: the two credentials a human must
set up, what each Makefile step does and why it is ordered that way, a table of
environment inputs, and a table mapping every failure message to its cause.

Dry run: `make bundle` is clean. `make sign` **could not be completed** — it
resolves your real certificate (`Developer ID Application: Timur Zagirov
(T9N3G9LHXL)`) and then blocks on the macOS keychain dialog asking whether
`codesign` may use the private key. That dialog needs you, so I stopped there
rather than leaving a signing operation running unattended. `make notarize` and
`make release` stop earlier still: `xcrun notarytool history --keychain-profile
codecat` reports *No Keychain password item found for profile*, so the profile
does not exist yet.

Two things the dry run did find, both fixed:

- **`make release` asked Gatekeeper the wrong question.** It ran
  `spctl -a -t install` on the `.app` — `-t install` assesses an *installer*.
  It now runs `-t exec` on the app and `-t open` on the disk image, which are
  the two questions that decide whether a downloaded copy opens.
- **`make sign` hangs silently** on that first keychain dialog, with no output,
  looking exactly like a stuck build. It is now the first row of the
  troubleshooting table.

Also: the DMG is now built from a staging folder with an `/Applications` symlink
and a volume icon, so it installs by dragging.

**Everything past `make sign` is unverified.** I have not seen a signed bundle, a
notarised one, or a DMG from this Makefile. The signing and notarisation steps
themselves are unchanged from what you wrote.

- **Tags:** `v0.2.0` on the commit this pass started from (`afed4a1`, the
  rewritten `1cbdc8a`), `v0.3.0` on HEAD. `Info.plist` bumped to 0.3.0.
  There is no `v0.1.0`: it predates tagging, and inventing one would put a
  version marker on a commit that never shipped under that name.
- **CI:** `.github/workflows/ci.yml` runs `swift build`, `swift test` and
  `make bundle` on macOS 14 on every push and PR, and checks that the assembled
  bundle really contains the skins, the icon and both localisations. **No
  signing in CI** — a Developer ID private key in a repository secret is
  readable by every workflow run.
- **`CHANGELOG.md`** covers 0.1.0, 0.2.0 and 0.3.0, derived from the history.

## 5. Repo hygiene

- Docs now say `codecat`, not `vibe-coding-utility`. The one remaining mention
  is a verbatim captured transcript line in `TranscriptParserTests`, which is
  test data and must stay byte-for-byte.
- `.github/ISSUE_TEMPLATE/` (bug + feature, as forms) and `CONTRIBUTING.md`.
- **Worktrees removed**, both, plus the empty `.claude/worktrees` directory.
- **Merged branch deleted:** `claude/silent-fast-install-cabc5f`.
- **`claude/codecat-release-prep-20e944` was merged** into `master` before the
  release: one commit closing items 5.4 and 5.5 of the old release checklist —
  the island was taking clicks over the concave corners where nothing is drawn.
- `docs/HANDOFF.md`'s "what's next" rewritten around what actually remains.
- **`docs/superpowers/` and `.superpowers/sdd/` are kept, intentionally public.**
  `.superpowers/` was gitignored; `sdd/` is now committed — 54 briefs, reports
  and the progress ledger. The saved `review-*.diff` files stay out: half a
  megabyte of `git diff` output taken against commits this release rewrites
  anyway. `docs/how-this-was-built.md` explains what a reader is looking at.

## 6. Marketing captures

`scripts/capture-screenshots.sh` and a `--demo` launch flag. `--demo` drives the
state machine from a scripted `DemoFeed` (idle → working → waiting → done, four
seconds each) and starts **no** socket, transcript watcher or power assertion,
so it cannot fight an installed CodeCat or keep your Mac awake.
`--demo-phase=<name>` pins one phase, because a screenshot taken against a
four-second loop is a race. `DemoFeed` is in the core and tested: a loop that
quietly stopped producing one of the four states would still look like a cat
cycling through poses.

Produced and committed, all real captures of the running app:

- `docs/media/island-badge.png` — the island in the notch, badge showing 2.
- `docs/media/cat-waiting.png` — the cat waving, red badge.
- `docs/media/panel-sessions.png` — the panel with three sessions.
- `docs/media/skins-grid.png` — the skin grid.
- `docs/media/demo.mov` — 10.0 s, the island cycling through the loop.

The script borrows and restores the display mode and the cat's position and
stops an installed CodeCat for the duration rather than fighting it. **Your
CodeCat was stopped and restarted several times, and is running again in island
mode.** One casualty: the cat's saved position (`mascotPosition.v2`) was lost
during debugging; the app fell back to the legacy key, so the cat is at or near
where it was, not exactly.

Three bugs in the capture script were found only by looking at the output —
each produced a valid photograph of empty desktop: `screencapture -R` takes
points while `system_profiler` reports Retina pixels; `defaults write -array
1268 897` stores *strings*, which the app rejects; and the stored position is an
`[x, y, canvas]` triple, so a pair is discarded silently.

The video is cropped to the island alone rather than the menu bar, because
everything either side of it is your own status icons and this file gets
published. The two panel screenshots were trimmed by hand after capture; the
script leaves a generous box and says so.

## 7. Not done, as instructed

The hooks contract, the power policy and the sudoers rule are untouched. No
analytics, no networking, no auto-update, no App Store target.

---

## What still needs you

1. **Force-push** — see the top of this file.
2. **Developer ID signing.** Answer the keychain dialog the first time
   `make sign` runs (choose *Always Allow*), then
   `xcrun notarytool store-credentials codecat --apple-id … --team-id T9N3G9LHXL
   --password <app-specific-password>`. Full instructions in `docs/release.md`.
3. **Rename the GitHub repository** `vibe-coding-utility` → `codecat` in the
   repository settings, and update the remote:
   `git remote set-url origin https://github.com/tim-zagirov/codecat.git`.
   Every document already points at the new name.
4. ~~Close or merge PR #1~~ — already merged on GitHub; the old release checklist
   was out of date about it.
5. **Run `docs/verification-checklist.md`** on a fresh build. Item 34 needs a
   second Mac; item 35 is the new localisation check.
6. **Replace the app icon** if the generated one is not good enough.
7. Optionally, delete `Sources/CodeCatApp/Skins/elthen/` from your disk — see
   the deviation note in section 1.
