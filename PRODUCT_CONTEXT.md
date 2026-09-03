# CodeCat — Product & Engineering Context

Compiled from the repository at `master` (151 commits, HEAD `1cbdc8a`, 2026-09-01) — all of it derived
from code, configs, docs, commits and assets here. The UI and most documentation are in Russian; quotes
are translated. Unknowns are listed in §12 rather than guessed.

---

## 1. One-line pitch

CodeCat is a native macOS menu-bar utility that tracks every local Claude Code session in
real time, keeps the Mac awake while agents are working, and shows an on-screen pixel-cat
mascot whose pose tells you at a glance whether an agent is working, done, or waiting for you.

## 2. Problem & user

**User:** macOS developers who run Claude Code (CLI and/or desktop app), start long agent
tasks, and walk away from the machine.

**Pain**, stated in the founding spec `docs/superpowers/specs/2026-08-28-codecat-design.md`:

> "The main pain we solve: the agent asked a question or is waiting for permission and the
> user didn't notice — time is idling. The second: the Mac falls asleep and cuts off hours
> of agent work."

Scenarios named in the same spec: *"set a task, closed the laptop, left with phone tethering
— the Mac finished the work and fell asleep by itself"* and *"locked the Mac in a coworking
space: locking ≠ sleeping, processes keep running."*

**What they used before** (author's comparison in `docs/product-brief.md`, not market-verified):
`caffeinate` / Amphetamine / KeepingYouAwake — manual toggles that cannot know whether an agent is
working; Claude Code's own `Notification` hook, which fires a notification but aggregates no state;
RunCat / Bongo Cat, which react to CPU or nothing. No direct competitor identified.

## 3. Feature inventory

**Session tracking** — all `shipped`
- Real-time tracking of all local Claude Code sessions (CLI + desktop), with project name and current
  activity in words ("editing api.ts", "running a command", "started a subagent", "thinking").
- Precise "agent is waiting for you" signal from five Claude Code hooks: `SessionStart`,
  `UserPromptSubmit`, `Stop`, `Notification`, `SessionEnd` (`Sources/CodeCatCore/HooksInstaller.swift:34`).
- Heuristic fallback when hooks aren't installed: a 5-minute transcript pause implies waiting.
- Startup discovery of already-running sessions via a persisted route cache — added in 0.2.0
  after measuring 4–89 s of blindness on restart (README checklist item 32).
- States `idle / working / waitingForYou / done / crashed`, aggregated separately for display and
  for power policy (`Sources/CodeCatCore/SessionModel.swift`).

**Power management** — all `shipped`
- IOKit power assertion held while any agent works, released after a 120 s grace period.
- Assertion never taken below a 15 % battery floor (`Sources/CodeCatCore/PowerManager.swift:46`).
- Closed-lid mode: `pmset -a disablesleep` behind a sudoers rule scoped to exactly two commands
  (`scripts/install-lid-mode.sh`), plus a LaunchDaemon that clears the flag every 60 s if no
  CodeCat process is alive — surviving crash, `kill -9` and Force Quit.

**Mascot & UI** — all `shipped`
- Two display modes: a floating always-on-top, all-Spaces borderless window, and an "island" —
  a black plate the height of the menu bar that covers the MacBook notch with wings on both
  sides (cat left, session counter right).
- Five poses driven by aggregate status: sleeping / working (badge = count) / waving a paw
  (red badge) / satisfied / ears-down problem.
- Island interaction: hover opens a short menu (sessions), click the full one (sessions, skins,
  toggles, hooks); ~0.3 s close delay on hover-out. Floating mode has the equivalent details panel.
- Jump-to-session: clicking a session row switches to where it lives — the exact Terminal.app
  or iTerm2 tab (by tty, via AppleScript), or the desktop Claude app brought forward. Rows with
  no known route aren't clickable and say why.
- "While you were away": events collected between screen lock and unlock (`AwayLog.swift`).
- Eight sprite skins in a live-preview grid, with an "About the assets" row showing authors and
  licenses; selection persisted in `UserDefaults` (`mascotSkin`).
- Menu-bar item mirroring state via SF Symbols; version shown as `CodeCat <version> (<build>)`.
- Toggles: keep awake, closed-lid mode, sounds (off by default), show mascot, "hide the cat when there
  are no sessions", install/remove hooks, launch at login (`SMAppService`).
- Hook install/removal merges into `~/.claude/settings.json` idempotently, preserving foreign hooks and
  all other keys; an unreadable settings file aborts the write instead of clobbering it.
- Diagnostic log at `~/Library/Application Support/CodeCat/codecat.log`, tagged `[hook]`/`[app]`, rotating
  at 1 MB.

`stubbed` / not wired up
- Hand-drawn SwiftUI cat (`Sources/CodeCatApp/CatView.swift`) — no longer selectable; kept only as
  the emergency render when sprite sheets fail to load.
- Power state is never surfaced in the panel or menu bar, although the MVP spec promised it.
- Grace period and battery floor are constants, not settings.

## 4. How it works (architecture)

- **Platform:** macOS 14+ (`LSMinimumSystemVersion 14.0`), `LSUIElement` (no Dock icon).
- **Language / frameworks:** Swift (tools 5.9); SwiftUI inside an AppKit shell (`NSPanel`, `NSStatusItem`,
  `NSAlert`), Combine, IOKit power assertions, `SMAppService`, `DistributedNotificationCenter` (screen
  lock/unlock), `sysctl(KERN_PROC_ALL)` for the process tree, AppleScript via `NSAppleScript`/`osascript`.
- **Third-party services / APIs: none.** `Package.swift` declares zero dependencies, and there is
  no networking code anywhere — the only `https://` strings are itch.io attribution links.
- **Targets:** `CodeCatCore` (all logic, no UI), `CodeCatApp` (the app), `codecat-hook` (a ~60-line
  CLI shipped inside the bundle), `CodeCatCoreTests`.
- **Runtime flow:** Claude Code fires a hook → `codecat-hook` reads the event JSON on stdin, walks its
  ancestor process chain for the owning `.app`, tty and `claude` PID, and sends the enriched payload as a
  datagram to `~/Library/Application Support/CodeCat/codecat.sock` → `SessionStore` updates the model →
  subscribers react: `PowerManager` takes/releases the IOKit assertion, the mascot changes pose and badge,
  the lists update. A transcript watcher on `~/.claude/projects/**/*.jsonl` supplies details (project,
  current activity) and is the hook-less fallback.
- **Forks/upstream:** none — the code is original. Only the sprite art is third-party (§6, §8).

## 5. Hard engineering problems solved

Evidence is in `docs/HANDOFF.md`, `.superpowers/sdd/progress.md` and code comments.

1. **Telling "an agent is working" from "a tab is open."** `SessionStart` fires on launch, `--resume`
   and `/clear`, before any work exists; treating it as work left a permanent phantom `1` on the
   badge. Fixed with a distinct `.idle` state excluded from the badge, the aggregate and the power
   policy (`SessionModel.swift:7-27`).
2. **One waiting agent releasing everyone else's sleep assertion.** The power policy read the display
   aggregate, where "waiting" outranks "working" — so a single permission prompt let the Mac sleep on
   every other running agent: the exact failure the product exists to prevent. Found only by a
   whole-branch review; fixed with a separate per-session `anyWorking` accessor.
3. **Making `disablesleep` survivable.** A crash left the Mac unable to sleep until reboot. Now:
   SIGTERM/SIGINT handlers plus `atexit`, and a LaunchDaemon polling every 60 s that clears the flag
   whenever no CodeCat process is alive. A later fix removed the reverse failure — calling
   `pmset -a disablesleep 0` on exit dropped the Mac to sleep in 37 ms because the kernel re-read
   accumulated idle time (README checklist item 33).
4. **Routing a hook back to the terminal tab that spawned it.** The hook walks ancestors from `getppid()`
   (not `getpid()` — it lives inside `CodeCat.app` and would otherwise name CodeCat as session owner under
   tmux/ssh/native installs), collecting the outermost `.app`, its bundle ID and the inherited tty;
   AppleScript then selects that exact tab. Routes are cached on disk so a restart doesn't orphan live
   sessions (`SessionRouteCache.swift`), and PIDs are re-validated against the bundle — macOS reuses them.
5. **Notarization vs. Apple events.** Hardened runtime (required for notarization) silently blocks
   Apple events regardless of user settings, breaking jump-to-session with `errAEEventNotPermitted (-1743)`
   — and it is invisible on ad-hoc builds, which have no hardened runtime. Solved with
   `Resources/CodeCat.entitlements`, plus a `make sign` guard that greps the *signature* for the
   entitlement rather than trusting the file.
6. **Signing an asset-bearing bundle correctly.** Skins must land in `Contents/Resources/Skins`
   *before* `codesign`, or the signature doesn't cover them; `codecat-hook` must be signed separately
   and first, inside-out, or the notary rejects the bundle. `make verify-skins` runs `SkinAssetsTests`
   against the *built bundle* and parses the output, because `swift test --filter` exits 0 when it
   matches no tests at all (`Makefile`).
7. **Counting processes correctly.** `pgrep -x claude` reported one PID with two live sessions running, and
   under-counting would have marked live sessions crashed; replaced with a direct `sysctl(KERN_PROC_ALL)`
   read (`ProcessScanner.swift`). Relatedly, `Bundle.module`'s generated accessor `fatalError`s exactly when
   assets are missing — the case the drawn-cat fallback exists for — so paths are resolved by hand.

## 6. Design & UX decisions

- **Design tokens live in one file**, `Sources/CodeCatApp/MenuStyle.swift`, passed via SwiftUI
  `Environment`: the same rows and cells render on two surfaces with opposite rules. The floating panel on
  `.regularMaterial` uses system semantic colors; the island sits on **pure black** matched to the physical
  notch, where system semantics lie (`.secondary` renders near-black on black in light mode), so its white
  levels are numeric (1.0 / 0.62 / 0.38 / 0.08) and selection is a white border — system blue is already
  spent on the "done" status.
- **Island geometry was measured, not assumed** (`docs/superpowers/specs/2026-08-31-mascot-island-design.md`):
  menu bar on a notched screen is 32 pt, not the 22 pt `NSStatusBar` reports; the island sits at window
  level 26 (above the menu bar's 24 and status icons' 25, below pop-up menus' 101); notch measured at
  185 pt wide; wings are 72 pt — the widest sprite (56 pt) plus padding — accepting a stated, documented
  trade-off that the wings overlap the menu bar.
- **Motion:** per-subview `.phaseAnimator` on the drawn cat — breathing 2.4 s, tail sway 1.8 s, paw wave
  1.0 s; island menus reveal with `spring(response: 0.28, dampingFraction: 1.0)`. Sprite skins use a phase
  model (`SpriteAnimation`/`SpritePhase`): "done" plays *stretch twice → lie down → breathe*, because
  one-shot motions look absurd looped. Styles are never mixed — a pack missing a state reuses its own
  nearest animation and lets the badge carry the difference.
- **Deliberate UX calls visible in code:** an open-but-idle session is not "work"; the mascot is
  draggable and its position persists; the "hide when idle" toggle is duplicated into the menu-bar menu
  because enabling it from the panel would otherwise hide the only way to turn it off; a session row with
  no route is not clickable and explains why; a message "may never claim what the code doesn't know"
  (HANDOFF rule) — jump errors report only what actually happened.
- **Accessibility:** minimal — SF Symbol accessibility descriptions on the status item, an
  `.accessibilityLabel` on skin cells. No VoiceOver pass, no reduced-motion handling.
- **Localization:** none. All UI strings are hardcoded Russian; there are no `.lproj` or `.strings` files.
- **Brand assets:** name and 🐈 emoji only. Sprites live in `Sources/CodeCatApp/Skins/` with `CREDITS.md`,
  original license files and `fetch-assets.sh`. Hand-drawn cat palette: `#E8A04C` body, `rgb(0.23,0.16,0.09)`
  dark, burnt umber `rgb(0.55,0.30,0.16)` for the problem state.

## 7. Product status

- **Version** `0.2.0` (`Resources/Info.plist`), bundle id `com.codecat.app`; `CFBundleVersion` derives
  from `git rev-list --count HEAD` so two builds are always distinguishable. No git tags.
- **Signing:** ad-hoc today (`make app`). `make sign`/`notarize`/`release` are fully written — Developer ID,
  hardened runtime, entitlements, notarytool, stapler, and a DMG whose Gatekeeper verdict is asserted — but
  have **never been run**: no Developer ID certificate yet.
- **Distribution:** none. No `.dmg`, no release, no Homebrew cask, no App Store/TestFlight. Install is
  build-from-source → drag to `/Applications`. Installed bundle is 2.6 MB.
- **CI:** none (no `.github/`). Update mechanism: none — rebuild and copy manually.
- **Repo is pushed** to `https://github.com/tim-zagirov/vibe-coding-utility` (master in sync).
- **To ship publicly:** (a) Apple Developer ID + first real `make release` run and a clean-Mac test;
  (b) a `LICENSE` file — there is none, so the code is legally all-rights-reserved; (c) the Elthen
  sprite sheet is currently **committed and pushed**, which conflicts with that author's
  no-redistribution terms — `CREDITS.md` already plans to remove it in favour of `fetch-assets.sh`;
  (d) English UI and/or README; (e) an app icon (`.icns`) — none exists; (f) screenshots/demo GIF —
  none in the repo; (g) the remaining manual checklist items.
- **Metrics:** none, by design. No analytics, no crash reporting, no network calls. Zero external users
  found in the repo.

## 8. Assets available for marketing

- Sprite skins: `Sources/CodeCatApp/Skins/` — 74 PNGs, 344 KB total, final quality.
  `luizmelo/Cat-1…Cat-6` (50×50 frames, **CC0**), `elthen/Cat Sprite Sheet.png` (256×320, 8×10 grid of
  32×32; commercial use OK, **redistribution forbidden**), `mxmaze/` (48×48, 3×3 grid of 16×16,
  **CC BY 4.0 — attribution required**, credited in-app as "Maze.Bit.Boutique (mxmaze)").
- Licensing detail and sources: `Sources/CodeCatApp/Skins/CREDITS.md`, `luizmelo/License.txt`.
- Hand-drawn cat, fully original and unencumbered: `Sources/CodeCatApp/CatView.swift`.
- Source material: `README.md` (25 KB, Russian), `docs/product-brief.md`, `docs/HANDOFF.md`, five specs
  and five plans under `docs/superpowers/`, `docs/cat-assets-research.md`.
- **Missing:** app icon, logo, landing page, domain, screenshots, demo video/GIF, English copy.
  Screenshots were taken during verification but never committed.

## 9. Repo & workflow facts

- 174 tracked files, 1.7 MB tracked content. ~12,000 lines of Swift across 57 files: `CodeCatCore` 3,538 ·
  `CodeCatApp` 3,575 · `codecat-hook` 63 · tests 4,823. Plus 3 bash scripts and a Makefile — no other languages.
- **151 commits by one author over 5 calendar days** (2026-08-28 → 2026-09-01): 8 / 23 / 54 / 41 / 25.
  Prefix mix: 54 `fix:`, 46 `feat:`, 28 `docs:`, 14 merges — roughly a third of all commits are
  post-review fixes.
- **390 test functions in 20 files**, all in `CodeCatCoreTests`; the app target has no tests.
  `make app` additionally verifies that every registered skin's sheets survived into the signed bundle.
- **AI-assisted development is the method, and it is documented.** The project used the Superpowers
  `subagent-driven-development` skill: a fresh implementer subagent per task, then a reviewer subagent,
  then fixes, then a wide whole-branch review. Artifacts: `.superpowers/sdd/` holds 14 task briefs,
  14 task reports and 18 review diffs; `docs/HANDOFF.md` carries a lessons section. There is no
  `CLAUDE.md`/`AGENTS.md`/`.cursor` file — the process lives in the plans and the ledger instead.
- Recorded lessons, good case-study material: *"a whole-branch review pays off every time"* (it caught
  4 cross-component critical defects the per-task reviews structurally could not see); *"measure, don't argue
  about geometry"*; and the screenshot lesson — every mascot animation was attached to `EmptyView()`, so
  SwiftUI dropped the subtree and the cat rendered with no body. Neither implementer nor reviewer saw it;
  only a PNG render did.

## 10. Numbers worth quoting

- 5 days from first commit (a spec, 23:10) to a working installed build; first code 17 minutes after the spec.
- 151 commits · ~12,000 lines of Swift · 390 tests · **0 external dependencies** · 0 network calls.
- Installed app: 2.6 MB. Sprite assets: 74 PNGs / 344 KB. Log capped at 2 MB.
- Restart blindness before 0.2.0: measured at **4–89 s**; now sub-second.
- Sleep-assertion grace period 120 s; battery floor 15 %; lid-mode watchdog polls every 60 s.
- Measured geometry: 32 pt menu bar on a notched screen, 185 pt notch, 72 pt wings, window level 26.
- The `pmset` exit bug dropped the Mac to sleep in **37 ms**.
- 8 selectable skins × 5 states = 45 skin/state combinations rendered and reviewed as PNGs.
- Manual verification checklist: **34 items** in `README.md`.

## 11. Roadmap

From `docs/superpowers/plans/2026-09-01-release-checklist.md` and `docs/HANDOFF.md` (no TODO/FIXME
markers exist in the source):

1. Developer ID certificate → first real `make release` → verify on a clean Mac.
2. Finish the manual checklist (island behaviour, jump-to-session by hand, iTerm2 branch — never run,
   iTerm2 isn't installed on the dev machine).
3. Hit-test island clicks against `IslandLayout.silhouettePath` so clicks during the ~0.3 s spring
   don't land on unpainted window area.
4. Reduce or explicitly document the wings overlapping the menu bar.
5. Add tests to the app target by extracting controller decisions into pure core functions.
6. Surface power state in the UI; make grace period and battery floor configurable.
7. Housekeeping: prune merged branches and the two leftover worktrees under `.claude/worktrees/`; rewrite
   the stale "what's next" section of `HANDOFF.md`. Open since 2026-08-30: whether to buy a ~$6 sprite pack
   (`docs/cat-assets-research.md`).

## 12. Open questions

1. **License** — which one? There is no `LICENSE` file, so the code is currently all-rights-reserved.
2. **Is the GitHub repo public?** If it is, the committed Elthen sprite sheet violates that author's
   no-redistribution terms today; `CREDITS.md`'s removal plan needs executing either way.
3. **Distribution channel:** GitHub Releases DMG, Homebrew cask, or Mac App Store? (Sandboxing would break
   lid mode and jump-to-session, so the App Store looks incompatible — confirm.)
4. **Language:** localize the UI to English, or ship an English README over a Russian UI?
5. **Audience:** Claude Code only, or Cursor / Codex / other agents later? This changes the pitch.
6. **Price:** free, donation, or paid?
7. **Icon:** who draws the `.icns`?
8. **Has CodeCat run anywhere but the author's machine** — another macOS version, an Intel Mac, iTerm2?
   The repo shows evidence of exactly one machine. Any users or testers besides the author?
9. **Screenshots/recordings outside the repo?** Marketing needs at least the "agent asks → cat waves"
   moment; nothing visual is committed.
10. **Named competitors?** Only indirect ones were identifiable from the repo.
