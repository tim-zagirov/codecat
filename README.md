# CodeCat 🐈

A menu-bar cat that watches your Claude Code sessions, keeps the Mac awake while
agents are working, and waves a paw when one of them needs you.

*[Русская версия](README.ru.md)*

![The island in the notch, with two agents working](docs/media/island-badge.png)

## How it works, in 30 seconds

Claude Code fires hooks on five session events. CodeCat installs a tiny binary
(`codecat-hook`) as the handler for all five; it forwards each event over a unix
socket to the app, which keeps the state of every live session. Transcripts in
`~/.claude/projects` fill in the detail — which project, and what the agent is
doing right now ("editing api.ts", "running a command").

That state drives three things: the cat's pose, an IOKit power assertion that
keeps the Mac awake while any agent is working, and a list you can click to jump
straight to the terminal tab a session lives in.

Nothing leaves the machine. There is no network code in CodeCat at all.

## Install

Download the latest `CodeCat-<version>.dmg` from
[Releases](https://github.com/tim-zagirov/codecat/releases), open it, drag
`CodeCat.app` to `/Applications`, and launch it. The build is signed and
notarised, so it opens on a double-click — no right-click-and-Open dance.

Then, from the cat's menu:

1. **Install Claude Code hooks…** — without them CodeCat still works, but it
   learns about session changes late (from transcripts rather than events).
2. Optionally **Closed-lid mode** — asks for an administrator password once.

A Homebrew cask is planned but does not exist yet.

Requires macOS 14 or later. Apple silicon and Intel.

## What it does

- **Tracks every local Claude Code session** — CLI and the desktop app — in real
  time.
- **Shows a cat.** It sleeps when nothing is running, works while agents work,
  waves a paw when one is waiting for you, and stretches out and settles down
  when the work is done. Eight sprite skins to pick from.
- **Two ways to show it:** a floating cat you drag where you like, or an
  *island* — a black slab drawn around the notch of a built-in display, which
  expands into a menu on hover.
- **Jumps to a session.** Click a row and you land in the exact terminal tab
  that session is running in.
- **Keeps the Mac awake** while agents work, and lets it sleep again once they
  stop.
- **Closed-lid mode.** Shut the laptop and walk away; the agents keep going.
- **"While you were away"** — a summary of what happened while the screen was
  locked.

<p>
  <img src="docs/media/panel-sessions.png" alt="The panel: three sessions, the skin grid and the settings" width="300">
  <img src="docs/media/cat-waiting.png" alt="The cat waving because an agent is waiting" width="120">
</p>

## Hooks: what gets written, and how to take it back

**Install Claude Code hooks…** merges one entry per event into
`~/.claude/settings.json`:

```jsonc
{
  "hooks": {
    "SessionStart":     [{ "hooks": [{ "type": "command", "command": "/Applications/CodeCat.app/Contents/MacOS/codecat-hook" }] }],
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/Applications/CodeCat.app/Contents/MacOS/codecat-hook" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "/Applications/CodeCat.app/Contents/MacOS/codecat-hook" }] }],
    "Notification":     [{ "hooks": [{ "type": "command", "command": "/Applications/CodeCat.app/Contents/MacOS/codecat-hook" }] }],
    "SessionEnd":       [{ "hooks": [{ "type": "command", "command": "/Applications/CodeCat.app/Contents/MacOS/codecat-hook" }] }]
  }
}
```

Five events, one binary, no arguments. Every other key in the file — your
permission allowlist, MCP servers, other people's hooks — is preserved exactly,
and installing twice does not duplicate anything.

`codecat-hook` reads the event on stdin, sends it to
`~/Library/Application Support/CodeCat/hook.sock`, and exits. It never blocks
Claude Code: if CodeCat is not running, the send fails, the hook writes one line
to the log and exits 0.

**To remove them:** cat's menu → **Remove Claude Code hooks…**. It deletes only
entries whose command is CodeCat's own and leaves everything else alone. Do this
*before* deleting the app — otherwise five entries pointing at a binary that no
longer exists stay in your settings, and Claude Code will try to run them on
every event of every session.

Full uninstall:

```bash
# 1. Remove the hooks from the menu first, then:
sudo bash /Applications/CodeCat.app/Contents/Resources/uninstall-lid-mode.sh  # if you enabled lid mode
rm -rf /Applications/CodeCat.app
rm -rf ~/Library/Application\ Support/CodeCat
```

## Closed-lid mode, and exactly what it may do as root

macOS sleeps when you close the lid, which kills whatever your agents were in the
middle of. Closed-lid mode toggles `pmset -a disablesleep` while agents are
working and clears it when they stop.

`pmset -a disablesleep` needs root, so enabling this once runs
`scripts/install-lid-mode.sh` under an administrator password. It installs
exactly two things.

**1. A sudoers rule at `/etc/sudoers.d/codecat`**, for your user only:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
```

Two literal command lines. Not `pmset` in general, not a wildcard — the two exact
argument vectors CodeCat runs and nothing else. `visudo -cf` validates the file
before it is installed.

**2. A launch daemon, `com.codecat.sleepreset`**, which every 60 seconds asks: is
CodeCat running? If yes, it does nothing at all. If no, and `SleepDisabled` is
still 1, it clears it. That is the safety net for a crash or a Force Quit while
the flag was set — without it the flag would survive until the next reboot. It
checks before it writes, so an idle Mac is not having its energy preferences
rewritten by root once a minute forever.

`scripts/uninstall-lid-mode.sh` removes both.

## Privacy

- **No network.** CodeCat makes no outbound connections. There is no analytics,
  no telemetry, no crash reporting, no update check.
- **Reads** `~/.claude/projects` (session transcripts) and
  `~/.claude/settings.json` (only to add or remove its own hook entries).
- **Writes** only to `~/Library/Application Support/CodeCat` — the socket, a
  route cache, and a log.
- The log at `~/Library/Application Support/CodeCat/codecat.log` rotates at 1 MB
  and never exceeds two files. It stays on your disk; nothing reads it but you.

## Building from source

```bash
git clone https://github.com/tim-zagirov/codecat.git
cd codecat
swift test        # 400 tests
make app          # dist/CodeCat.app, ad-hoc signed — fine on your own machine
```

`make app` is all you need for local use. Distribution needs a Developer ID
certificate and a notarisation profile — see [docs/release.md](docs/release.md)
for `make sign` / `make notarize` / `make release` and the exact credentials to
set up.

One skin ("Silver") is not in this repository: its author allows using the
sprites but not redistributing the files. `make bundle` runs
`scripts/fetch-optional-assets.sh`, which downloads it from itch.io. If that
fails — offline, or itch.io changed its download flow — the build succeeds and
the skin simply does not appear. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

### What is and is not verified

Automatically, on every `swift test`: all of `CodeCatCore` — hook and transcript
parsing, aggregate session status, the power assertion, the away log, the
`settings.json` rewrite, the process-tree walk that picks a jump route, the
sprite registry against the real PNGs, and both string catalogs against the call
sites. The build additionally checks that the assembled `.app` really contains
the skins and the localisations.

By hand, because an `LSUIElement` app has no window for a screen-control tool to
find: everything in [docs/verification-checklist.md](docs/verification-checklist.md).
Closed-lid mode in particular has never run end to end on a machine — it needs an
administrator password, so it was never executed during development.

### How this was built

Every line of CodeCat was written by AI agents, driven by specs. If that is the
interesting part for you, [docs/how-this-was-built.md](docs/how-this-was-built.md)
has the workflow, the timeline, and the one review lesson that cost the most.

## Credits and licence

CodeCat's source code is [MIT](LICENSE) © 2026 Timur Zagirov.

The cats are not. Sprite artwork belongs to its authors and ships under their
terms — the full list, with sources and licences, is in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md):

- **LuizMelo**, [Pet Cats Pack](https://luizmelo.itch.io/pet-cat-pack) — CC0 1.0.
  Six of the eight skins.
- **Maze.Bit.Boutique (mxmaze)**, [16-Bit Kitty](https://mxmaze.itch.io/16-bit-kitty-free)
  — **CC BY 4.0**. Attribution is required, and is shown in the app under *About
  the assets* as well as here.
- **Elthen's Pixel Art Shop**,
  [2D Pixel Art Cat Sprites](https://elthen.itch.io/2d-pixel-art-cat-sprites) —
  author's own terms. Downloaded at build time, not redistributed here.
