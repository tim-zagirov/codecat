# Island live state: tone, session dots, task steps, handoff, motion

Date: 2026-09-18. Target release: 0.5.0.

## 1. Why

CodeCat today answers "is something running, and does it need me" — a pose, a
dot, a number. It does not answer the three questions a person actually has when
they glance at the notch during a long agent run:

- *Where is it in the work?* The row shows the tool in hand ("editing api.ts"),
  never the plan the agent is following.
- *Which of my sessions is in which state?* The island shows one tone and one
  count; "2 working, 1 waiting" is invisible until the menu opens.
- *It finished — what do I look at?* The cat stretches out, and the link to the
  dev server, the PR, the Figma file or the artifact is only in the terminal.

A concept video for a Grok notch companion (@ab.workss, 57 s) shows all three
answered from the notch: a mascot whose tint carries the state, a cluster of
agent avatars, a step list with the current step emphasised, and a finished
result the user drags straight out of the notch into a browser window. This spec
ports what CodeCat has honest data for and leaves the rest.

Measured on this machine's transcripts (last 60 files): 520 turn-ending
messages, 47 with a URL, 49 with an absolute path. Hosts: figma.com, github.com,
claude.ai (artifacts), localhost dev servers on ports 4321, 4330, 5173, 5180.
Task-list tool calls: 39 `TaskCreate`, 74 `TaskUpdate`, 11 `TodoWrite`. The
parser sees none of them today.

## 2. Scope

In:

1. **Strip tone** — a glow behind the cat in the island's left wing, coloured by
   the aggregate tone.
2. **Session dots** — one dot per active session in the right wing, each in its
   own status colour, instead of one tone plus a number.
3. **Task steps** — the agent's own task list (TodoWrite / TaskCreate /
   TaskUpdate) read from the transcript; the row shows the current step and
   progress.
4. **Handoff** — when a turn ends, the first line of the agent's final message
   and chips for the links and paths in it; click opens, drag carries the link
   out of the island.
5. **Tinted menu head** — the island menu's top carries a faint gradient of the
   aggregate tone when it is *waiting* or *problem*.
6. **Motion** — every one of the above animates as specified in §8, and every
   animation respects Reduce Motion.

Out (decided, not forgotten):

- **Subagent chips.** The parser only flags `isSubagent`; per-subagent tracking
  (agentId, description, lifetime) is its own feature. Next.
- **Dropping a folder on the notch to start a session there.** A new capability
  (launching `claude` in a cwd), not a display change.
- **Approving permission prompts from the island.** A button that says yes to a
  command the user has not read defeats the prompt. The row says what is asked
  and the click jumps to the terminal, as today.
- **Typing a reply from the island.** Keystrokes into a tty land wherever the
  cursor is, and the desktop app has no such channel at all.
- **Greeting particles.** Decoration without information.

## 3. Data model (`CodeCatCore`)

### 3.1 Task steps

```swift
public struct TaskStep: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable { case pending, inProgress, completed }
    public let id: String          // TodoWrite: index as string; TaskCreate: the "#N" number
    public var title: String       // what the row shows — see title rules
    public var activeForm: String? // TodoWrite's present-continuous form, if any
    public var status: Status
}
```

`Session` gains `steps: [TaskStep]` (empty by default) and two derived values:

- `currentStep: TaskStep?` — the first `.inProgress` step; if none, the first
  `.pending`; nil when every step is completed or there are none.
- `stepProgress: (done: Int, total: Int)?` — completed count over total; nil
  when `steps` is empty.

Title shown for the current step: `activeForm` when present and non-empty
("Writing the parser"), else `title` ("Write the parser"). Both are capped by
`TaskText.sanitized` rules (one line, ≤ 160 chars) — the same cap, the same
function, so a pasted path in a step title cannot blow up the row.

### 3.2 Steps updates in the transcript

`TranscriptActivity` gains `stepsUpdates: [StepsUpdate]` (empty for the vast
majority of lines):

```swift
public enum StepsUpdate: Equatable, Sendable {
    case replaceAll([TaskStep])           // TodoWrite: the whole list, every call
    case create(id: String, title: String) // TaskCreate, from its tool_result
    case update(id: String, status: TaskStep.Status) // TaskUpdate
    case remove(id: String)               // TaskUpdate with status "deleted"
}
```

Where each comes from, read off live transcripts:

- **TodoWrite** — an `assistant` entry, `content[].tool_use` with `name ==
  "TodoWrite"`, `input.todos: [{content, activeForm, status}]`. `status` values
  seen: `pending`, `in_progress`, `completed`. Ids are the index in the array as
  a string ("0", "1", …); the list is replaced whole on every call, so ids need
  only be stable within one call.
- **TaskCreate** — the `tool_use` carries `subject` but no id. The id is in the
  matching `user` entry's `tool_result`: the text `Task #N created successfully:
  <subject>`. The parser reads the **result** line (regex
  `^Task #(\d+) created successfully: (.+)$`), which needs no correlation with
  the request. A `TaskCreate` whose result never arrives creates nothing —
  correct, since the task was never created.
- **TaskUpdate** — `input.taskId` (string) and `input.status`. Values seen:
  `completed`, `in_progress`; `pending` and `deleted` are accepted for
  completeness (`deleted` → `.remove`). Any other status is ignored.
- Both `assistant` and `user` entries can carry several `tool_use` /
  `tool_result` blocks; every matching block yields an update, in order, which
  is why the field is an array.

Subagent entries (`agentId` non-empty) never update the parent's steps: a
subagent's todo list is its own errand. `isSidechain` entries likewise.

### 3.3 Steps lifecycle in `SessionStore`

- `apply(activity:)` applies each update in order after the task-text logic and
  before the `endsTurn` early return (steps must survive a turn ending, like the
  task does).
- `.replaceAll` replaces `steps`. `.create` appends (or replaces a step with the
  same id — a `TaskCreate` result replayed from the primed tail must not
  duplicate). `.update` on an unknown id is ignored. `.remove` removes.
- `SessionStart` (non-compact) clears `steps` with `taskText`: a clean slate.
- `Stop`, `Notification`, `UserPromptSubmit` leave `steps` alone: Claude Code
  keeps the list across turns, and a new prompt often continues the same plan.
- `expireFinished` / `reconcile` unchanged: the steps go with the session.

Restart behaviour: `primeFromExistingTranscripts` replays the last 64 KB of each
recent transcript, so after a CodeCat restart a session's steps are rebuilt from
whatever `TodoWrite` / `TaskCreate` / `TaskUpdate` lines fall inside that tail.
A `TaskUpdate` whose `TaskCreate` fell outside the tail is dropped by the
unknown-id rule. That is accepted: the alternative (reading whole transcripts,
tens of MB) is out of proportion for a row hint. When a partial rebuild leaves a
list with updates but no creates, the row simply shows no steps.

### 3.4 Handoff

```swift
public struct HandoffLink: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case localhost, pullRequest, github, figma, artifact, web, file, folder }
    public let id: String      // the target string
    public let kind: Kind
    public let title: String   // what the chip says
    public let target: URL     // http(s) URL or file URL
}

public struct Handoff: Equatable, Sendable {
    public let summary: String?      // first line of the final message, or nil
    public let links: [HandoffLink]  // ≤ 4, in order of first appearance
}
```

`Session` gains `handoff: Handoff?`.

`HandoffExtractor.extract(from text: String, pathKind: (String) -> PathKind?) -> Handoff?`,
with `PathKind { file, folder }` and `realPathKind` as the default, is a pure
function in `CodeCatCore`:

- **URLs**: `https?://[^\s<>()\[\]"'`]+`, then trailing `.,;:!?)*_` stripped
  (markdown and sentence punctuation). Deduplicated by string.
- **Paths**: `/Users/…` and `~/…` runs without whitespace or quotes, trailing
  `.,;:)*_` stripped, `~` expanded with `NSString.expandingTildeInPath`. A
  relative path is *not* extracted: "src/foo.ts" in prose is too ambiguous.
  Kept only when `pathKind` says so (injected: the real one is `realPathKind`,
  backed by `FileManager`; tests pass a closure).
  A path under `~/.claude` or `~/Library` is dropped (the agent's own bookkeeping
  is not a deliverable).
- **Kind and title**:
  | Match | Kind | Title |
  | --- | --- | --- |
  | host is `localhost` or `127.0.0.1` | localhost | `localhost:PORT` (host and port only; `localhost` alone when no port) |
  | `github.com/<o>/<r>/pull/<n>` | pullRequest | `PR #n` |
  | `github.com/…` (anything else) | github | `GitHub` |
  | host ends with `figma.com` | figma | `Figma` |
  | host `claude.ai` and path contains `/artifact` | artifact | `Artifact` |
  | any other http(s) | web | host without `www.` |
  | existing file | file | last path component |
  | existing directory | folder | last path component + `/` |
- **Summary**: the first non-empty line of the text after stripping markdown
  markers (`**`, `__`, leading `#`, `>` and `-`/`*` bullets, backticks; inline
  markdown links `[text](url)` collapse to `text`) and after removing every
  extracted URL and path *when the line is nothing but the link*. Capped by
  `TaskText.sanitized` (one line, ≤ 160). A line that is a fenced-code marker
  (```) is skipped. Nil when nothing is left.
- **Cap**: the first four links. Four is the most a row can carry at island
  width without wrapping to a second row of chips.
- Returns nil when there is neither summary nor links.

Lifecycle in `SessionStore`:

- The parser attaches `finalText: String?` to a `TranscriptActivity` when
  `endsTurn` is true — the concatenation of the assistant entry's `text` blocks
  (they are in the same entry as `stop_reason`). `apply(activity:)` in the
  `endsTurn` branch sets `handoff = HandoffExtractor.extract(...)` (nil when
  nothing was found — an explicit nil, replacing any older handoff).
- `UserPromptSubmit` and any non-`endsTurn` activity that moves the session to
  `.working` clear `handoff`: the next turn has begun and the old result is
  stale.
- `SessionStart` (non-compact) clears it.
- `Stop` hook leaves it alone (the transcript's `end_turn` line, which carries
  the text, may arrive before or after the hook).

The store gets `pathKind` injected at init (default: `realPathKind`) so tests
never touch the disk.

### 3.5 Session dots

`SessionStore.dots: [SessionDot]` — `id` is the session id, `tone` the status
tone — one entry per session that counts (the same population as `indicator`:
waiting, working, crashed, done; `idle` excluded), ordered as `ordered` is
(urgency first), so the island can animate each session's own dot: the cluster
is one `ZStack` with per-slot offsets keyed by session id. The island renders
it when the count is 1…4 and falls back to the existing capsule at 5+ or when
it is empty. The mapping from `SessionStatus` to `MascotTone` is one function,
shared with the session-row dot (`SessionListView.color(for:)` today draws from
status directly; it moves to go through the tone so the three surfaces cannot
drift).

### 3.6 Demo feed

`DemoFeed` gains steps and a handoff for its scripted sessions so the README
screenshots and the verification checklist can show them: session 0 carries a
five-step list with step 3 in progress; session 1, in its `.done` phase,
carries the summary "Готово: тесты зелёные, релиз 0.4.1 собран" and links
`localhost:4321`, `PR #12` and `Figma` (a folder would need a real path on the
capture machine; a folder chip is checked on a live session instead). Demo
sessions go through the same `apply` paths (synthetic `TranscriptActivity`
values), not a side door.

## 4. Island strip (`IslandView`)

### 4.1 Tone glow (left wing)

Behind the sprite, a radial gradient: centre `tone.color.opacity(0.42)`, edge
clear, radius equal to the wing height (32 pt), centred on the sprite. Drawn
under the cat, over the black. Tones: working green, waiting orange, done blue,
problem red; sleeping draws no glow. The colour literals are the same four the
row dots and the capsule use — `MascotTone` → `Color` becomes one function in
`CodeCatApp` (`ToneColor.color(for:)`), and the three existing copies are
replaced by it.

### 4.2 Session dots (right wing)

For 1…4 counted sessions: a cluster of 6 pt dots, 4 pt apart. One dot centred;
two in a row; three and four in a 2×2 grid (three leaves the bottom-right cell
empty). The cluster is centred in the wing. A waiting session's dot pulses on
the existing 3 s cycle (scale 1.0 → 1.35); no other dot pulses. Five or more
sessions, or none: the capsule exactly as today.

Hover help text on the cluster: "2 working, 1 waiting for you" (the existing
`menubar.*` strings composed with ", ").

## 5. Session row (`SessionListView`)

### 5.1 Step line

Shown when the session is `.working` and `currentStep` is non-nil. Its content:

```
[bar ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬]  3/5
Writing the parser
```

concretely one line of text (the step title, 10 pt on the island / 11 pt on the
panel, `style.secondary`) with a trailing monospaced-digit counter `3/5`
(`style.tertiary`), and under it a 2 pt progress bar the width of the text
column: track `Color.white.opacity(0.10)` on the island / `Color.primary.opacity(0.10)`
on the panel, fill in the working tone, corner radius 1. Progress is
`done / total`; with `total == 0` the line is not shown.

Placement:

- **Panel (three-line rows)**: the step line replaces the demoted status line
  ("working · editing api.ts") while the step exists. The duration keeps its
  column on that line. When the session leaves `.working`, the status line
  returns.
- **Island (two-line rows)**: the row grows by one line: name + duration, task,
  step. Rows already vary in height by whether a task exists; a third line
  follows the same rule.

The step line is hidden by the same switch as the task text (§7).

### 5.2 Handoff block

Shown when `handoff` is non-nil and the status is `.done` or `.waitingForYou`:

- The summary, `style.secondary`, up to 2 lines on the panel and 1 on the
  island, `truncationMode(.tail)`.
- Chips 6 pt apart, wrapping to a second row when they do not fit; the block
  sits under the whole row at the text column's inset, so the chips get the
  row's full width. Each chip is a capsule with a 10 pt SF Symbol and the
  title at 10 pt medium, padding 7 × 3, fill `Color.white.opacity(0.10)`
  (island) / `Color.primary.opacity(0.07)` (panel), hover fill doubles. Symbols:
  localhost `globe`, pullRequest `arrow.triangle.pull`, github `chevron.left.forwardslash.chevron.right`,
  figma `paintpalette`, artifact `doc.richtext`, web `link`, file `doc`,
  folder `folder`. Titles longer than 18 characters are cut with an ellipsis.
- **Click** on a chip: `NSWorkspace.shared.open(target)` for URLs and files;
  for a folder `NSWorkspace.shared.activateFileViewerSelecting([target])`.
  Click does not close the menu (the user may want a second chip). It also
  does not trigger the row's jump: the chip's tap gesture wins, and the chip
  shows the pointing-hand cursor through the same `onHoverRegion` path the row
  uses. Click on the short (hover) menu leaves it open; the full menu closes
  when the opened app takes focus, as it does on any loss of focus.
- **Drag**: `.onDrag { NSItemProvider(object: target as NSURL) }` with the chip
  itself as the preview. A URL dropped on a browser window opens it; a file
  URL dropped on Finder copies. Drag from the island's short (non-key) menu
  needs the hosting view to accept first-mouse; if AppKit refuses the drag
  session from a non-key window, the chip click still works there and the drag
  works from the full menu and the panel — the plan carries a spike to settle
  this before the chips are built.
- The block is hidden by the task-text switch (§7): it is the agent's words
  and the user's paths, the same class of content.

## 6. Island menu head (`IslandMenuView`)

When the aggregate tone is `.waiting` or `.problem`, a `LinearGradient` from
`tone.color.opacity(0.16)` at the top to clear at 64 pt, laid under the menu
content across the full menu width, beginning at the strip's bottom edge. Not
for working or done: those are not requests for attention, and a permanent green
head would train the eye to ignore the orange one. Island only; the floating
panel keeps its system material.

## 7. Setting

The existing switch `showsTaskText` ("Show what you asked each session for")
broadens to cover steps and the handoff block, and its label becomes "Show what
each session is doing" (key unchanged, `settings.taskText.title` text changed
in both the code and the catalog; the help text says: task, current step and
the final message with its links). Off means the row is back to name, status,
duration — one switch, one meaning: "nothing from inside the conversation on
screen".

## 8. Motion and behaviour

Principles, in the order they are applied:

1. **Frequency rule.** The island is seen hundreds of times a day. Nothing new
   loops. The only cycle stays the existing 3 s waiting pulse, because it asks
   for attention. Everything else animates once, on change, and never longer
   than 300 ms. Escape and click close the menu exactly as today.
2. **Time-based, not counter-based.** An animation that must survive the
   island's root view being reassigned (which `IslandController` does on every
   state change) is computed from a timestamp, the way `SpriteTimeline` is,
   not from a `@State` that a rebuild would reset.
3. **Reduce Motion.** Read `accessibilityReduceMotion`. Scale and offset
   become opacity crossfades; stagger is dropped; the waiting pulse becomes a
   static ring (`stroke` of the tone at 1.5 pt around the dot) so the signal
   survives the loss of movement.

Concrete values:

| Element | Change | Motion | Reduce Motion |
| --- | --- | --- | --- |
| Tone glow | tone changes | colour crossfade 250 ms `easeOut`; on arrival one bloom: scale 0.9 → 1.0 and opacity 0 → 1 over 250 ms `easeOut`, computed from `statusSince` (bloom shows only while `now − statusSince < 0.25 s`) | crossfade only |
| Tone glow | to sleeping | opacity 1 → 0 over 250 ms | same |
| Session dot | appears | scale 0.6 → 1.0 (0.6 on the way out) and opacity, on the reposition spring together with the neighbours' move | opacity only |
| Session dot | disappears | scale 0.6 → 1.0 (0.6 on the way out) and opacity, on the reposition spring together with the neighbours' move | opacity only |
| Session dot | neighbours reposition | `IslandView.reveal` spring (0.28, damping 1.0) via `.animation(_, value: dots)` | none (instant) |
| Session dot | tone changes | colour crossfade 250 ms | same |
| Session dot | waiting | scale 1.0 ↔ 1.35, 3 s `easeInOut`, the existing cycle | static ring |
| Step title | text changes | `.contentTransition(.opacity)` plus a 2 px blur on the outgoing text, 200 ms `easeOut` (implemented as two overlaid `Text`s keyed by the title with `.transition(.opacity.combined(with: .blur(2)))` — a custom `AnyTransition` using `.blur(radius:)`) | opacity only |
| Step counter | number changes | `.contentTransition(.numericText())`, monospaced digits | same (no movement in it) |
| Progress bar | fill changes | `IslandView.reveal` spring, both directions | instant |
| Handoff chips | appear | stagger 40 ms per chip, each scale 0.95 → 1.0 and opacity 0 → 1 over 200 ms `easeOut` | opacity, no stagger |
| Handoff chip | mouse down | scale 0.97 over 120 ms, on **down** not up: the chip is a `Button` with a custom `ButtonStyle`, whose `configuration.isPressed` is true from mouse-down (`onHoverRegion` cannot see the press, and a `DragGesture` would fight `.onDrag`) | same, it is feedback |
| Menu head tint | tone changes or appears | opacity crossfade 300 ms | same |
| Row grows a step line | step appears / goes | height on the `IslandView.reveal` spring, with `.animation(_, value:)` on the row's derived layout key; the island's window height follows through the existing `IslandContentHeightKey` path | instant |

A chip does not lift on drag start: `.onDrag` offers no end-of-drag callback
to put it back down, and the default drag preview (the chip itself) already
says what is being carried.

Easing names refer to SwiftUI's `Animation.easeOut(duration:)` etc. Every
duration above is a constant in one place (`Motion.swift` in `CodeCatApp`) so
the numbers in this table and in the code are the same numbers.

## 9. Localisation

New keys in `Resources/en.lproj/Localizable.strings` (the catalog test enforces
every key at a call site is present and vice-versa):

- `row.step.progress` — `%d/%d`
- `handoff.title.pr` — `PR #%@`; `handoff.title.github` — `GitHub`;
  `handoff.title.figma` — `Figma`; `handoff.title.artifact` — `Artifact`
- `setting.show.task` — text change; `setting.show.task.help` — new

## 10. Testing

Unit (`CodeCatCoreTests`, `swift test`; the suite is at 508 and must stay
green):

- `TranscriptParserTests`: TodoWrite → `.replaceAll` with statuses and
  activeForm; TaskCreate result line → `.create` with id and title; TaskUpdate
  → `.update` / `.remove`; unknown status ignored; a subagent's TodoWrite
  yields no update; a line with two tool blocks yields two updates; `finalText`
  set only on `end_turn`.
- `SessionStoreTests`: steps applied in order; `.create` on an existing id
  replaces; `.update` on an unknown id ignored; `SessionStart` clears steps and
  handoff; `compact` keeps them; `currentStep` picks in-progress before
  pending; `stepProgress`; handoff set on end_turn, cleared on the next
  `UserPromptSubmit` and on the next working activity; `dots` order and
  population, `idle` excluded.
- `HandoffExtractorTests` (new): every row of the kind/title table; trailing
  markdown punctuation stripped; `~` expansion; non-existing path dropped;
  `~/.claude` path dropped; dedupe; cap at four; summary with markdown
  stripped; summary nil when the only line is a link; nil result when empty.
- `DemoFeedTests`: the demo sessions carry the steps and handoff described.
- `LocalizationCatalogTests`: unchanged, catches missing keys.

Visual, by hand, appended to `docs/verification-checklist.md` — per the
project rule that a defect is found only in a rendered image:

- For each row of the motion table: `screencapture -R` of the island at 50 ms
  intervals through the transition (a shell loop of 8 captures), then the
  frames are compared with the expected start and end states and the 250 ms
  point. Done once with Reduce Motion off and once on.
- The demo feed in island mode: glow, dot cluster with one pulsing dot, a row
  with a step line and bar, a done row with summary and three chips, the tinted
  head in the waiting phase. Same in panel mode.
- A chip dragged onto a Safari window opens the URL; a folder chip dragged to
  the Desktop copies; a click on a `localhost` chip opens the default browser.
- Five demo sessions → the capsule returns.

## 11. Files touched

`CodeCatCore`: `SessionModel.swift` (TaskStep, Handoff, HandoffLink, Session
fields, derived values), `TranscriptParser.swift` (steps updates, finalText),
`SessionStore.swift` (lifecycle, dots, fileExists), new `HandoffExtractor.swift`,
`DemoFeed.swift`.

`CodeCatApp`: `IslandView.swift` (glow, dots), `IslandMenuView.swift` (tint),
`SessionListView.swift` (step line, handoff block), new `HandoffChipView.swift`,
new `ToneColor.swift`, new `Motion.swift`, `SettingsSectionView.swift` (label),
`MascotBadge.swift` / `SessionListView.swift` (use `ToneColor`).

Docs: `CHANGELOG.md` (Unreleased → 0.5.0 entries), `README.md` ("What it
does" gains the three answers), `docs/verification-checklist.md`.
