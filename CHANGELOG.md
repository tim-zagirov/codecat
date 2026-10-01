# Changelog

All notable changes to CodeCat. Dates are the day the work was finished, not the
day it was tagged. Derived from the commit history; the design decisions behind
each release live in the source comments.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
CodeCat uses [semantic versioning](https://semver.org/) — pre-1.0, so the minor
number carries breaking changes.

## [Unreleased]

## [0.5.0] — 2026-10-01

The living island: the state is drawn on the island itself, the island opens one
list of cards, and it opens itself for a moment when an agent needs you — with
the reason. Every switch moves to a Settings window, the floating cat speaks the
island's language, and CodeCat has a mark of its own.

### Added
- **The state lights the island's rim.** A thin stroke along the island's walls
  and bottom in the state's colour — green working, orange waiting, blue done,
  red crashed — with a soft bloom under it, and nothing while every agent
  sleeps. While an agent waits for you a white highlight runs along the rim, a
  lap every 2.4 s; it is CodeCat's only loop and stops the moment nobody waits.
- **The right wing shows live data.** One dot per session, a waiting one with a
  halo drawn over its neighbours; one working session shows its step count and a
  progress ring, or how long it has run; one finished session a check. Five or
  more go back to one dot and the count.
- **The island acknowledges the cursor.** Under the pointer it grows a little,
  the rim brightens and a shadow lifts it; leave before the hover delay and it
  settles back.
- **One list, a card per session.** Hover opens it on one spring, width and
  height together, and the cards blur in. A card shows the project, what you
  asked for, and by state: the agent's current step with its count and bar
  ("Fixing the pagination cursor · 2/5", read from the agent's own task list);
  what it is waiting for with an **Open ↗** button; what a finished turn handed
  back — its first line and chips for the links in it (`localhost:4321`,
  `PR #12`, a file), click to open, drag into a browser; or that the session
  ended unexpectedly, with a × to dismiss it. A session CodeCat cannot open is
  dimmed and says why.
- **Sessions with nothing to do fold** into one line at the end of the list,
  "2 open without a task", which expands in place.
- **The list says whether the Mac is awake.** A footer — "Mac stays awake — 2
  agents working", "Mac can sleep in 1 min", "Closed lid: on" — shown only when
  there is something to say.
- **An empty list that tells you what to do.** "Agents are asleep" and how to
  wake them; before the hooks are installed, one "Connect Claude Code" card with
  **Connect…** and **Not now**.
- **The island peeks when an agent needs you.** It opens itself for 3 s when a
  session asks for permission or a question and when one crashes, and for 1.5 s
  when a turn is done, with one line saying why — "wants to run `npm test`",
  "wants to edit `api.ts`", "has a question for you", the first line of a
  finished turn — and an **Open ↗** button or the turn's first link. A line along
  the bottom counts down the time left; hovering holds the peek, and resting on
  it opens the list. Two agents within a second become one "2 agents need you"
  with **Show**. Each kind has its own switch.
- **One summary after the screen was locked.** Nothing peeks while the Mac is
  locked; on unlock, if anything happened, one "While you were away" peek —
  "2 done · 1 waiting" — with **Show**.
- **The island steps aside in full screen** (a setting, on by default), but a
  waiting or crashed session still peeks over the full-screen app.
- **A Settings window.** General (how to show CodeCat, open at login, hide when
  nothing is running, the hover delay, hide in full screen, show what each
  session is doing), Alerts (the three peeks and the sound), Power (whether the
  Mac is being kept awake, keep it awake, closed-lid mode), Cat (the chosen skin
  in all five states, every skin on its own tile, Codex pets, artists and
  licences) and Claude Code (connected or not, the hooks it listens to, the last
  event, Show settings.json, Remove hooks…, Open log). It opens from "•••" in
  the island, from the menu-bar symbol and with ⌘, in any CodeCat window; ⌘W
  closes it.
- **"Show what each session is doing"** — on by default. Off hides the task in
  your words, the step and what a turn handed back: they are your own words and
  your project's links, and a demo or a shared screen is reason enough to hide
  them.
- **The floating cat stands on a capsule** with the island's rim and right wing.
  It widens into the peek toward the screen's centre, and a click or a rest on
  the cat opens the island's cards in a black panel — below the cat when they fit,
  above it otherwise. Panels close back into the capsule they grew from.
- **CodeCat's own mark.** The notch is the cat: a black island with two ears and
  two orange pixel eyes, on a night-gradient squircle as the app icon, and with
  the eyes knocked out as the menu-bar symbol — which gets an orange dot while an
  agent waits and a red one after a crash.
- **Motion with a rule.** Every change animates once, from the value on screen,
  on the island's springs; Reduce Motion turns growth into cross-fades, the
  waiting pulse into a still ring and stops the rim's highlight.

### Changed
- **Poses that read right.** The cat walks while it works instead of standing
  still, sits and looks at you while it waits instead of the meow people read as
  the cat being sick, and crouches, startled, when a session dies — the same
  frames for all six LuizMelo cats.
- **"Waiting for your input" is a finished turn.** Claude Code's nudge a minute
  after a turn ends no longer turns a session orange, plays no sound and does not
  sort it first: a done session stays done, and a working one whose end was lost
  becomes done.
- **A click in the island lets Escape close it.** Clicking inside the open island
  or the floating list makes CodeCat the active app, so Escape reaches it; when
  it closes, the app you were in is in front again — unless you jumped to a
  session, which brings that one forward. Hover never takes the keyboard.
- **The hover delay is yours** — 0.15 to 1 s in Settings › General, 0.3 s by
  default.
- **The status-bar menu is short:** Show CodeCat as ▸, Settings… ⌘,, the version
  and Quit.

### Removed
- **The glow behind the cat** — the rim carries the state now.
- **The tinted head of the island's menu.**
- **The two island menus** — the short one on hover and the long one on click,
  with its skins and settings disclosures. There is one list.
- **The switches in the status-bar menu**, now in Settings.
- **The floating panel's material, title and the badge on the floating cat** —
  the panel is the island's black list and the capsule carries the state.
- **"While you were away" in the list** — it is the summary peek after an unlock.

### Fixed
- **A long prompt no longer loses the "work started" event.** A unix datagram on
  macOS is capped at 2 048 bytes and `sendto` refuses anything bigger, so a
  `UserPromptSubmit` payload carrying a prompt over ~1.4 KB never arrived at all —
  measured on live data: of 1 760 delivered hook events not one exceeded 2 045 B,
  and the losses were logged as "app not running?" while the app was running. The
  hook now trims the prompt to what a card can show before forwarding it.
- **A session survives its host app restarting.** The host's pid is remembered in
  `routes.json` and outlives the process it names, so after Claude (or CodeCat)
  restarts, every restored row pointed at a pid that no longer existed and said
  "can't open its terminal — that app has been closed" about an app that was
  running. A session of the desktop app is addressed by session id, not by
  process (the deep link `DesktopSessionIndex` builds), so it now routes through
  any live instance of the same app. A terminal tab and a plain application still
  die with their process: a new instance has neither that tab nor that window, and
  sending the user to the wrong one is worse than saying it is gone.
- **A card reacts to the first click.** The list opened by hover belongs to a
  window that is deliberately not key, and the views a click lands on there
  refused the first mouse — so the first click was spent making the window key.
  The window now takes key status itself when a click arrives, and the same click
  is routed normally (`OverlayPanel.sendEvent`).
- **The demo leaves no trace.** Demo sessions were recorded in `routes.json` and
  read back on the next run, so a screenshot meant to show "4 min" could say
  "25h 12m"; the demo now writes no route cache, and its Connect… and Remove only
  say what they would do instead of touching `~/.claude/settings.json`.

## [0.4.0] — 2026-09-14

Pets from the Codex ecosystem, a straight jump into a desktop-app chat, and a
UX pass over both menus after a three-persona review.

### Added
- **Click a desktop-app session, land in that chat.** The desktop Claude app
  keeps a record per Claude Code session with the CLI session id inside, and
  registers `claude://code/continue?session=…`. Rows of desktop sessions now
  open the exact chat through that link instead of just bringing the app
  forward; when no record matches, the old behaviour stays as the fallback
  (`DesktopSessionIndex`).
- **Pets in the Codex pet format.** Any pet folder in `~/.codex/pets` or in
  `~/Library/Application Support/CodeCat/Pets` shows up in the skin picker and
  drives the cat through all five states (`idle`, `running`, `waiting`, `failed`,
  `jumping` then `review`). Upscaled pixel art is brought back to its native
  pitch and, when the native drawing fits the cat's canvas, renders as crisply
  as the built-in packs; anything larger is shrunk smoothly. Broken folders are
  skipped and named once in the log.
- **Hover states on everything you can press.** Skin tiles in the floating
  panel now highlight under the cursor (they used to look like pictures),
  the "Artists and licences" row highlights and turns its chevron, both show the
  pointing hand, and the floating cat lifts slightly under the cursor
  (not under Reduce Motion). The cat shows no pointing hand: its window can
  never become key, and macOS ignores the cursor such a window sets. One
  `hoverHighlight` modifier draws the same highlight on the panel and the island.
- **The empty panel leads with a call to action.** With no sessions the panel now
  opens on **Set up Claude Code…** rather than blank space — the one step that
  makes CodeCat learn about sessions early is the first thing you see.
- **Installing the hooks asks first.** The action explains what it will write to
  `~/.claude/settings.json`, waits for a yes, and confirms once the merge is done,
  instead of editing the file silently.
- **Closed-lid mode explains itself before the password.** The prompt now says it
  installs a narrow sudoers rule for two exact `pmset` lines and a launch daemon
  that runs as root, so the administrator password is asked for in context.
- **Escape closes the full island menu**, alongside the click and the dwell-out
  that already dismissed it.
- **The mascot has a tooltip** naming its current state, so the pose has words.

### Changed
- **One indicator drives the island counter and the floating badge.** Both read
  from the same aggregate, so a crashed session shows on each and their colours
  agree — working green, waiting orange, problem red, done blue. Sessions sort by
  urgency, so the one that needs you is first.
- **Durations read honestly.** "waiting 3 min", "5 min ago", "just now" — never
  "running for 0 min". Each session row shows one status, a glyph for where it
  runs, and a single jump hint instead of competing cues.
- **The island menu tucks skins and settings behind disclosures** and says "Click
  for skins and settings", so the short menu stays short. The skin grid is a 3×3
  of larger tiles, the panel title states the aggregate state, and the setting
  labels say what they do. Long menus scroll rather than run off the screen.
- **The island opens on a deliberate hover** rather than any crossing of the
  notch, and its wings no longer sit over the menu bar while it is closed. The
  menu-bar menu drops its dead session rows and groups the view modes into a
  submenu.

### Fixed
- **Choosing "Island" on a Mac without a notch no longer strands the mascot** —
  it falls back to the floating cat instead of drawing an island with nowhere to
  live.
- **The island menu answers hover.** Session rows, skin tiles and the credits row
  highlighted only in the floating panel; on the island nothing reacted to the
  cursor. SwiftUI's hover is silent in a window that is not key, and the island's
  window is never made key by hover on purpose (a key panel would take your
  keystrokes from the terminal). The AppKit host now publishes the pointer and one
  `onHoverRegion` modifier computes "hovered" from each view's own frame — the same
  mechanism on both surfaces.
- **The cat no longer vanishes in Mission Control.** Both the floating cat and
  the island stayed put through Space switches but slid away with everything
  else on a pinch; one `.stationary` collection flag keeps them on screen.

## [0.3.0] — 2026-09-03

The release that makes CodeCat publishable: an English interface, a licence, and
a build a stranger can trust.

### Added
- **An English interface throughout.** Every user-visible string moved out of the
  view bodies into `Resources/en.lproj/Localizable.strings`, and a test keeps the
  catalog and the call sites in step. Source comments, the Makefile, the scripts
  and the documentation are English too.
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
  `docs/release.md`.

### Changed
- The manual verification checklist moved out of the README into
  `docs/verification-checklist.md`.
- `README.md` was rewritten for someone who has never seen the project.
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
- **The island no longer swallows clicks where it is not drawn.** The window is a
  rectangle and the island is not: clicks over the concave corners at the screen
  edge — where the app menu on the left and the status icons on the right live —
  were being taken by the island rather than the menu bar, permanently; and for a
  fraction of a second while the menu expanded, the window was wider than the
  drawing beneath it. Hit-testing now follows the same `IslandLayout.silhouettePath`
  the view builds its mask from.
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

[0.5.0]: https://github.com/tim-zagirov/codecat/releases/tag/v0.5.0
[0.4.0]: https://github.com/tim-zagirov/codecat/releases/tag/v0.4.0
[0.3.0]: https://github.com/tim-zagirov/codecat/releases/tag/v0.3.0
[0.2.0]: https://github.com/tim-zagirov/codecat/releases/tag/v0.2.0

0.1.0 has no tag: it predates tagging, and inventing one now would put a
version marker on a commit that never shipped under that name. Its entry above
is reconstructed from the history.
