# Contributing

CodeCat is a personal project that happens to be public. Issues and pull
requests are welcome; there is no roadmap you need to fit into.

## Before you start

For anything beyond a small fix, open an issue first. Not for process — because
the design decisions in this codebase are written down, and it saves you writing
code against an assumption that was already considered and rejected. The specs
are in `docs/superpowers/specs/`, and the comments in the source carry the *why*
rather than the *what*.

## Working on it

```bash
swift test        # everything; it takes under a second
make app          # dist/CodeCat.app, ad-hoc signed
```

To try a change in the real app you must copy the bundle to `/Applications`,
because the installed hooks call the binary by absolute path:

```bash
make app && pkill -x CodeCat
rm -rf /Applications/CodeCat.app && cp -R dist/CodeCat.app /Applications/
open -a /Applications/CodeCat.app
```

## What the codebase expects of a change

- **Logic goes in `CodeCatCore` and gets a test.** The app target has no tests —
  it is `LSUIElement`, so there is nothing a test host can drive. Anything that
  can be decided by a pure function should be one, in the core, tested there.
  This is not a style preference: it is the only place correctness can be
  checked at all.
- **A comment says why, not what.** If a line looks odd, the comment explains
  what happens without it. Nobody needs `// increment the counter`.
- **No silent failures.** Every path that cannot do what the user asked has to
  say so, and the message must not claim something the code does not know. There
  are tests that enforce exactly this for jump-to-session; hold new code to it
  too.
- **User-visible text goes through `L10n`**, with the English at the call site
  and both catalogs updated (`Resources/en.lproj`, `Resources/ru.lproj`).
  `LocalizationCatalogTests` fails if you forget one. Log lines are the
  exception: those stay English so a pasted log is readable by anyone.
- **Verify by artefact.** Reasoning about whether UI code is right has a poor
  record here — three real defects survived careful review and fell only to a
  rendered image or an independently computed number. If you change something
  visual, look at it.

## Things that are deliberately absent

Please do not add: analytics or telemetry of any kind, network calls, an
auto-updater, or a Mac App Store target (sandboxing breaks closed-lid mode and
jump-to-session). These are decisions, not omissions.

## Commit messages

`type: what changed` on the first line — `feat`, `fix`, `chore`, `docs`, `test`.
The body explains why, in whatever detail the change deserves.

## Licence

Contributions are under the [MIT licence](LICENSE), same as the rest of the
code. Sprite artwork has its own terms: see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) before adding any.
