# Island Live State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The island answers three questions at a glance — where each session is in its work, which session is in which state, and what to look at when one finishes — with motion that is felt, not watched.

**Architecture:** `CodeCatCore` gains three pure data paths read off the transcript: the agent's task list (`TodoWrite` / `TaskCreate` / `TaskUpdate` → `TaskStep`), the final message of a turn (`HandoffExtractor` → `Handoff`), and a per-session tone list (`SessionStore.dots`). `CodeCatApp` renders them: a tone glow and a dot cluster in the island strip, a step line with a progress bar and a handoff block with draggable chips in the session row, a tinted menu head. All motion constants live in one file and every animation has a Reduce Motion fallback.

**Tech Stack:** Swift 5.9, SwiftUI + AppKit (macOS 14+), XCTest, Swift Package Manager. Build: `swift build`; tests: `swift test`; app bundle: `make app`.

**Spec:** `docs/superpowers/specs/2026-09-18-island-live-state-design.md`

## Global Constraints

- `swift test` is at 508 tests and must stay green after every task; new behaviour comes with tests in `Tests/CodeCatCoreTests`.
- `CodeCatApp` has no unit tests (an `LSUIElement` app has no window for a test to find); every view task ends with `swift build` and a rendered check in the demo (`open dist/CodeCat.app --args --demo`; add `--demo-phase=working|waiting|done|idle|problem` to pin one phase and `--demo-open-menu` to open the menu) captured with `screencapture`.
- Every user-visible string goes through `L10n.t(key, english)` / `L10n.f(key, english, args…)` AND into `Resources/en.lproj/Localizable.strings`. `LocalizationCatalogTests` fails on a key present in one place and not the other.
- Colour literals for the four tones are written **once**, in `ToneColor` (Task 6). No new `.green` / `.orange` / `.blue` / `.red` literals anywhere else.
- Motion durations are constants in `Motion.swift` (Task 6). No new duration literals in views.
- Every scale/offset animation reads `@Environment(\.accessibilityReduceMotion)` and degrades to an opacity crossfade or to nothing, exactly as the spec's motion table says.
- Doc comments explain *why* (the codebase's style — see any file in `Sources`); a comment that restates the code is not written.
- Commits: one per task, message in the repo's style (`feat:` / `fix:` / `docs:`).
- Work happens on branch `claude/island-live-state`, created from `claude/session-task-text` (commit `36bb310`).

---

## File structure

Created:

- `Sources/CodeCatCore/HandoffExtractor.swift` — pure text → `Handoff` (URLs, paths, summary, titles).
- `Sources/CodeCatApp/ToneColor.swift` — the one `MascotTone → Color` function.
- `Sources/CodeCatApp/Motion.swift` — every animation constant.
- `Sources/CodeCatApp/HandoffChipView.swift` — one chip: symbol, title, click, drag, press feedback.
- `Sources/CodeCatApp/StepLineView.swift` — the step title, counter and progress bar.
- `Tests/CodeCatCoreTests/SessionModelTests.swift` — derived values on `Session`.
- `Tests/CodeCatCoreTests/HandoffExtractorTests.swift`.

Modified:

- `Sources/CodeCatCore/SessionModel.swift` — `TaskStep`, `StepsUpdate`, `HandoffLink`, `Handoff`; `Session.steps/handoff` + derived values; `SessionStatus.tone`; `TranscriptActivity.stepsUpdates/finalText`.
- `Sources/CodeCatCore/TranscriptParser.swift` — reads the three task tools and the final text.
- `Sources/CodeCatCore/SessionStore.swift` — steps/handoff lifecycle, `dots`, injected `pathKind`.
- `Sources/CodeCatCore/DemoFeed.swift` — steps and a handoff for the scripted sessions.
- `Sources/CodeCatApp/IslandView.swift` — glow, dot cluster.
- `Sources/CodeCatApp/IslandMenuView.swift` — tinted head.
- `Sources/CodeCatApp/SessionListView.swift` — step line, handoff block, tone colours.
- `Sources/CodeCatApp/MascotBadge.swift` — tone colours via `ToneColor`.
- `Sources/CodeCatApp/MenuStyle.swift` — `chipFill`, `chipHover`, `barTrack`.
- `Sources/CodeCatApp/SettingsSectionView.swift` — the switch's label and help.
- `Resources/en.lproj/Localizable.strings`, `CHANGELOG.md`, `README.md`, `docs/verification-checklist.md`, the spec (two touch-ups).

---

### Task 0: Branch

- [ ] **Step 1: Create the branch**

```bash
cd /Users/timzagirov/Projects/vibe-coding-utility
git checkout -b claude/island-live-state 36bb310
swift test 2>&1 | grep "Executed" | tail -1
```

Expected: `Executed 508 tests, with 0 failures`.

---

### Task 1: Core model — steps, handoff, tone

**Files:**
- Modify: `Sources/CodeCatCore/SessionModel.swift`
- Create: `Tests/CodeCatCoreTests/SessionModelTests.swift`

**Interfaces:**
- Produces:
  - `public struct TaskStep: Equatable, Sendable, Identifiable { enum Status: String { case pending, inProgress, completed }; id: String; title: String; activeForm: String?; status: Status; var displayTitle: String }`
  - `public enum StepsUpdate: Equatable, Sendable { case replaceAll([TaskStep]); case create(id: String, title: String); case update(id: String, status: TaskStep.Status); case remove(id: String) }`
  - `public struct HandoffLink: Equatable, Sendable, Identifiable { enum Kind { case localhost, pullRequest, github, figma, artifact, web, file, folder }; id: String; kind: Kind; title: String; target: URL }`
  - `public struct Handoff: Equatable, Sendable { summary: String?; links: [HandoffLink] }`
  - `Session.steps: [TaskStep]`, `Session.handoff: Handoff?`, `Session.currentStep: TaskStep?`, `Session.stepProgress: (done: Int, total: Int)?`
  - `SessionStatus.tone: MascotTone`
  - `TranscriptActivity.init(..., stepsUpdates: [StepsUpdate] = [], finalText: String? = nil)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/CodeCatCoreTests/SessionModelTests.swift`:

```swift
import XCTest
@testable import CodeCatCore

final class SessionModelTests: XCTestCase {
    private func session(steps: [TaskStep]) -> Session {
        var s = Session(id: "s1", projectPath: "/p", status: .working, activityDescription: "",
                        startedAt: Date(), lastActivity: Date())
        s.steps = steps
        return s
    }
    private func step(_ id: String, _ title: String, _ status: TaskStep.Status,
                      active: String? = nil) -> TaskStep {
        TaskStep(id: id, title: title, activeForm: active, status: status)
    }

    func testCurrentStepIsTheFirstInProgress() {
        let s = session(steps: [step("0", "a", .completed), step("1", "b", .inProgress),
                                step("2", "c", .inProgress), step("3", "d", .pending)])
        XCTAssertEqual(s.currentStep?.id, "1")
    }

    func testCurrentStepFallsBackToTheFirstPending() {
        let s = session(steps: [step("0", "a", .completed), step("1", "b", .pending)])
        XCTAssertEqual(s.currentStep?.id, "1")
    }

    func testCurrentStepIsNilWhenEverythingIsDoneOrThereAreNoSteps() {
        XCTAssertNil(session(steps: [step("0", "a", .completed)]).currentStep)
        XCTAssertNil(session(steps: []).currentStep)
    }

    func testStepProgressCountsCompletedOverTotal() {
        let s = session(steps: [step("0", "a", .completed), step("1", "b", .inProgress),
                                step("2", "c", .pending)])
        XCTAssertEqual(s.stepProgress?.done, 1)
        XCTAssertEqual(s.stepProgress?.total, 3)
        XCTAssertNil(session(steps: []).stepProgress)
    }

    func testDisplayTitlePrefersTheActiveFormWhenPresent() {
        XCTAssertEqual(step("0", "Write the parser", .inProgress, active: "Writing the parser").displayTitle,
                       "Writing the parser")
        XCTAssertEqual(step("0", "Write the parser", .inProgress, active: "").displayTitle,
                       "Write the parser")
        XCTAssertEqual(step("0", "Write the parser", .inProgress).displayTitle, "Write the parser")
    }

    func testStatusMapsToTheSameToneTheIndicatorUses() {
        XCTAssertEqual(SessionStatus.working.tone, .working)
        XCTAssertEqual(SessionStatus.waitingForYou(.question).tone, .waiting)
        XCTAssertEqual(SessionStatus.done.tone, .done)
        XCTAssertEqual(SessionStatus.crashed.tone, .problem)
        XCTAssertEqual(SessionStatus.idle.tone, .sleeping)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter SessionModelTests 2>&1 | tail -5`
Expected: compile errors — `TaskStep` and `currentStep` do not exist.

- [ ] **Step 3: Add the types and fields**

In `Sources/CodeCatCore/SessionModel.swift`, after `SessionStatus`:

```swift
/// One item of the agent's own task list, as it wrote it with `TodoWrite` or
/// `TaskCreate`. The list is the only statement of a plan that exists anywhere in
/// the transcript; the tool in hand ("editing api.ts") says what the agent is
/// touching, this says what it is *for*.
public struct TaskStep: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable { case pending, inProgress, completed }
    /// `TodoWrite` lists have no ids, so the index is the id — they are replaced
    /// whole on every call and only need to be stable within one. `TaskCreate`
    /// tasks are numbered by Claude Code ("Task #3") and that number is the id.
    public let id: String
    public var title: String
    /// `TodoWrite`'s present-continuous form ("Writing the parser"), the better line
    /// for a step that is happening right now. `TaskCreate` sends none.
    public var activeForm: String?
    public var status: Status

    public init(id: String, title: String, activeForm: String? = nil, status: Status) {
        self.id = id; self.title = title; self.activeForm = activeForm; self.status = status
    }

    /// The line the row shows for this step.
    public var displayTitle: String {
        if let activeForm, !activeForm.isEmpty { return activeForm }
        return title
    }
}

/// A change to a session's task list, read off one transcript line. See
/// `TranscriptParser` for where each case comes from.
public enum StepsUpdate: Equatable, Sendable {
    case replaceAll([TaskStep])
    case create(id: String, title: String)
    case update(id: String, status: TaskStep.Status)
    case remove(id: String)
}

/// Something the agent's final message pointed at: a dev server, a pull request, a
/// file it wrote. The chip under a finished session.
public struct HandoffLink: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case localhost, pullRequest, github, figma, artifact, web, file, folder
    }
    /// The target as written, so two mentions of the same link are one chip.
    public let id: String
    public let kind: Kind
    public let title: String
    public let target: URL

    public init(kind: Kind, title: String, target: URL) {
        self.id = target.absoluteString; self.kind = kind; self.title = title; self.target = target
    }
}

/// What a finished turn hands the user: the first line of the agent's last message
/// and the links in it. Nil on a session whose last turn said nothing worth a chip.
public struct Handoff: Equatable, Sendable {
    public let summary: String?
    public let links: [HandoffLink]
    public init(summary: String?, links: [HandoffLink]) {
        self.summary = summary; self.links = links
    }
}
```

Add to `SessionStatus` (inside the enum, after `title`):

```swift
    /// The colour a session's own dot is drawn in — the same vocabulary the island
    /// counter and the floating badge use, so a dot on the island and a dot in a row
    /// can never mean two different things.
    public var tone: MascotTone {
        switch self {
        case .idle: return .sleeping
        case .working: return .working
        case .waitingForYou: return .waiting
        case .done: return .done
        case .crashed: return .problem
        }
    }
```

Add to `Session` (after `taskText`):

```swift
    /// The agent's task list — see `TaskStep`. Empty until the agent writes one.
    public var steps: [TaskStep] = []
    /// What the last finished turn handed over — see `Handoff`. Nil while working:
    /// the next turn has begun and the old result is stale.
    public var handoff: Handoff? = nil

    /// The step the agent is on: the first in progress, else the first still pending.
    /// Nil when the list is done or absent — the row then shows nothing rather than
    /// a finished step pretending to be current.
    public var currentStep: TaskStep? {
        steps.first(where: { $0.status == .inProgress }) ?? steps.first(where: { $0.status == .pending })
    }

    /// Completed over total, nil with no list.
    public var stepProgress: (done: Int, total: Int)? {
        guard !steps.isEmpty else { return nil }
        return (steps.filter { $0.status == .completed }.count, steps.count)
    }
```

Add to `TranscriptActivity` two stored properties and init parameters:

```swift
    /// Changes to the session's task list carried by this line — see `StepsUpdate`.
    /// Empty for almost every line.
    public let stepsUpdates: [StepsUpdate]
    /// The assistant's text on the line that ends the turn — the message the user
    /// would read in the terminal. Nil on every other line.
    public let finalText: String?
```

Extend the init signature: `..., taskText: String? = nil, stepsUpdates: [StepsUpdate] = [], finalText: String? = nil)` and assign both.

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | grep -E "Executed|error" | tail -3`
Expected: `Executed 514 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/SessionModel.swift Tests/CodeCatCoreTests/SessionModelTests.swift
git commit -m "feat(core): task steps, handoff and per-status tone on the session model"
```

---

### Task 2: Parser — task-list tools and the final text

**Files:**
- Modify: `Sources/CodeCatCore/TranscriptParser.swift`
- Test: `Tests/CodeCatCoreTests/TranscriptParserTests.swift`

**Interfaces:**
- Consumes: `TaskStep`, `StepsUpdate`, `TranscriptActivity.init(stepsUpdates:finalText:)` from Task 1; `TaskText.sanitized`.
- Produces: `parseLine` fills `stepsUpdates` and `finalText`.

- [ ] **Step 1: Write the failing tests**

Append to `TranscriptParserTests` (inside the class). The existing `line(_:content:)` helper builds an entry with `message.content` as an array; `assistant(stopReason:)` builds one with `stop_reason`.

```swift
    // MARK: - Task list

    func testTodoWriteReplacesTheWholeList() {
        let l = line("assistant", content: #"""
            {"type":"tool_use","name":"TodoWrite","input":{"todos":[
              {"content":"Read the parser","activeForm":"Reading the parser","status":"completed"},
              {"content":"Write the test","activeForm":"Writing the test","status":"in_progress"},
              {"content":"Ship it","activeForm":"Shipping it","status":"pending"}]}}
            """#)
        let updates = TranscriptParser.parseLine(l)?.stepsUpdates
        XCTAssertEqual(updates, [.replaceAll([
            TaskStep(id: "0", title: "Read the parser", activeForm: "Reading the parser", status: .completed),
            TaskStep(id: "1", title: "Write the test", activeForm: "Writing the test", status: .inProgress),
            TaskStep(id: "2", title: "Ship it", activeForm: "Shipping it", status: .pending),
        ])])
    }

    func testTaskCreateIsReadFromItsResultLine() {
        let l = line("user", content:
            #"{"type":"tool_result","tool_use_id":"toolu_1","content":"Task #3 created successfully: Propose 2-3 approaches"}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.stepsUpdates,
                       [.create(id: "3", title: "Propose 2-3 approaches")])
    }

    func testTaskCreateResultAsTextBlocksIsReadToo() {
        let l = line("user", content:
            #"{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"Task #4 created successfully: Write docs"}]}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.stepsUpdates, [.create(id: "4", title: "Write docs")])
    }

    func testTaskUpdateStatusesAndDeletion() {
        XCTAssertEqual(TranscriptParser.parseLine(line("assistant", content:
            #"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"completed"}}"#))?.stepsUpdates,
            [.update(id: "2", status: .completed)])
        XCTAssertEqual(TranscriptParser.parseLine(line("assistant", content:
            #"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"in_progress"}}"#))?.stepsUpdates,
            [.update(id: "2", status: .inProgress)])
        XCTAssertEqual(TranscriptParser.parseLine(line("assistant", content:
            #"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"deleted"}}"#))?.stepsUpdates,
            [.remove(id: "2")])
        XCTAssertEqual(TranscriptParser.parseLine(line("assistant", content:
            #"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"blocked"}}"#))?.stepsUpdates,
            [])
    }

    func testOneLineWithTwoToolBlocksYieldsTwoUpdatesInOrder() {
        let l = line("assistant", content: #"""
            {"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}},
            {"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"in_progress"}}
            """#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.stepsUpdates,
                       [.update(id: "1", status: .completed), .update(id: "2", status: .inProgress)])
    }

    func testASubagentsTodoListDoesNotTouchTheParent() {
        let l = """
        {"type":"assistant","sessionId":"s1","cwd":"/p","agentId":"a1",\
        "timestamp":"2026-08-28T10:00:00.123Z","message":{"content":[\
        {"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"x","status":"pending"}]}}]}}
        """
        XCTAssertEqual(TranscriptParser.parseLine(l)?.stepsUpdates, [])
    }

    func testAnOrdinaryToolLineCarriesNoUpdates() {
        let l = line("assistant", content: #"{"type":"tool_use","name":"Bash","input":{"command":"ls"}}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.stepsUpdates, [])
    }

    // MARK: - Final text

    func testTheTurnEndingLineCarriesItsText() {
        let l = """
        {"type":"assistant","sessionId":"s1","cwd":"/p","timestamp":"2026-09-01T00:00:00.000Z",\
        "message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done."},\
        {"type":"text","text":"See http://localhost:4321"}]}}
        """
        let a = TranscriptParser.parseLine(l)
        XCTAssertEqual(a?.endsTurn, true)
        XCTAssertEqual(a?.finalText, "Done.\nSee http://localhost:4321")
    }

    func testALineThatDoesNotEndTheTurnHasNoFinalText() {
        XCTAssertNil(TranscriptParser.parseLine(assistant(stopReason: "tool_use", tool: "Bash"))?.finalText)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TranscriptParserTests 2>&1 | grep -E "error|failed|Executed" | tail -5`
Expected: the new tests fail (`stepsUpdates` is `[]`, `finalText` is nil).

- [ ] **Step 3: Implement**

In `TranscriptParser.parseLine`, after `let isSubagent = …`, compute and pass:

```swift
        // Neither a subagent's list nor a sidechain's is the session's plan: each is
        // the errand a subordinate was sent on, under the parent's session id.
        let isSidechain = obj["isSidechain"] as? Bool == true
        let stepsUpdates = (isSubagent || isSidechain) ? [] : stepsUpdates(obj)
        let finalText = endsTurn ? assistantText(obj) : nil
        return TranscriptActivity(sessionId: sessionId, projectPath: cwd,
                                  description: description, timestamp: ts,
                                  isSubagent: isSubagent, endsTurn: endsTurn,
                                  taskText: taskText(obj, type: type),
                                  stepsUpdates: stepsUpdates, finalText: finalText)
```

Add the helpers (private, in the same enum):

```swift
    /// The message's content blocks, or none.
    private static func blocks(_ obj: [String: Any]) -> [[String: Any]] {
        ((obj["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
    }

    /// The text of the assistant's message — every `text` block, in order, one per
    /// line. Tool blocks are skipped: they are not what the user reads.
    private static func assistantText(_ obj: [String: Any]) -> String? {
        let parts = blocks(obj).compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        let text = parts.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// Changes to the task list on this line. Three tools write it, read off live
    /// transcripts:
    ///  * `TodoWrite` — the whole list every time, in `input.todos`.
    ///  * `TaskUpdate` — one task's status, in `input.taskId` / `input.status`.
    ///  * `TaskCreate` — the request carries no id; the id is in the RESULT, a `user`
    ///    entry whose `tool_result` says "Task #3 created successfully: <subject>".
    ///    Reading the result needs no correlation with the request, and a create
    ///    whose result never came created nothing.
    private static func stepsUpdates(_ obj: [String: Any]) -> [StepsUpdate] {
        var updates: [StepsUpdate] = []
        for block in blocks(obj) {
            switch block["type"] as? String {
            case "tool_use":
                let input = block["input"] as? [String: Any] ?? [:]
                switch block["name"] as? String {
                case "TodoWrite":
                    let todos = input["todos"] as? [[String: Any]] ?? []
                    let steps = todos.enumerated().compactMap { index, todo -> TaskStep? in
                        guard let raw = todo["content"] as? String,
                              let title = TaskText.sanitized(raw),
                              let status = stepStatus(todo["status"] as? String) else { return nil }
                        let active = (todo["activeForm"] as? String).flatMap(TaskText.sanitized)
                        return TaskStep(id: String(index), title: title, activeForm: active, status: status)
                    }
                    updates.append(.replaceAll(steps))
                case "TaskUpdate":
                    // The id is a string in every payload seen; a number is accepted
                    // in case a future build sends one.
                    let id = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init)
                    guard let id else { break }
                    let raw = input["status"] as? String
                    if raw == "deleted" {
                        updates.append(.remove(id: id))
                    } else if let status = stepStatus(raw) {
                        updates.append(.update(id: id, status: status))
                    }
                default:
                    break
                }
            case "tool_result":
                // The result is a plain string or an array of text blocks — both
                // shapes occur in the same transcript.
                let texts: [String]
                if let text = block["content"] as? String {
                    texts = [text]
                } else {
                    texts = (block["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
                }
                for text in texts {
                    if let created = taskCreated(text) { updates.append(created) }
                }
            default:
                break
            }
        }
        return updates
    }

    private static func stepStatus(_ raw: String?) -> TaskStep.Status? {
        switch raw {
        case "pending": return .pending
        case "in_progress": return .inProgress
        case "completed": return .completed
        default: return nil
        }
    }

    private static let taskCreatedPattern = try! NSRegularExpression(
        pattern: #"^Task #(\d+) created successfully: (.+)$"#, options: [.anchorsMatchLines])

    private static func taskCreated(_ text: String) -> StepsUpdate? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = taskCreatedPattern.firstMatch(in: text, range: range),
              let idRange = Range(match.range(at: 1), in: text),
              let titleRange = Range(match.range(at: 2), in: text),
              let title = TaskText.sanitized(String(text[titleRange])) else { return nil }
        return .create(id: String(text[idRange]), title: title)
    }
```

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | grep -E "Executed|error:" | tail -3`
Expected: `Executed 523 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/TranscriptParser.swift Tests/CodeCatCoreTests/TranscriptParserTests.swift
git commit -m "feat(core): read the agent's task list and the turn's final text from the transcript"
```

---

### Task 3: HandoffExtractor

**Files:**
- Create: `Sources/CodeCatCore/HandoffExtractor.swift`
- Create: `Tests/CodeCatCoreTests/HandoffExtractorTests.swift`

**Interfaces:**
- Consumes: `Handoff`, `HandoffLink` (Task 1), `TaskText.sanitized`, `L10n`.
- Produces:
  - `public enum HandoffExtractor { public enum PathKind { case file, folder }; public static let maxLinks = 4; public static func extract(from text: String, pathKind: (String) -> PathKind?) -> Handoff?; public static func realPathKind(_ path: String) -> PathKind? }`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import CodeCatCore

final class HandoffExtractorTests: XCTestCase {
    /// Every path exists and is a file, except ones ending in "/" which are folders.
    private func kind(_ path: String) -> HandoffExtractor.PathKind? {
        path.hasSuffix("/dist") ? .folder : .file
    }
    private func extract(_ text: String) -> Handoff? {
        HandoffExtractor.extract(from: text, pathKind: kind)
    }

    func testLocalhostChipShowsHostAndPort() {
        let h = extract("Dev server: http://localhost:4321/app")
        XCTAssertEqual(h?.links.map(\.kind), [.localhost])
        XCTAssertEqual(h?.links.first?.title, "localhost:4321")
        XCTAssertEqual(h?.links.first?.target.absoluteString, "http://localhost:4321/app")
        XCTAssertEqual(extract("http://127.0.0.1:5180")?.links.first?.title, "127.0.0.1:5180")
        XCTAssertEqual(extract("http://localhost/")?.links.first?.title, "localhost")
    }

    func testPullRequestAndOtherGitHubLinks() {
        let h = extract("PR: https://github.com/tim/codecat/pull/12 and https://github.com/tim/codecat/issues/3")
        XCTAssertEqual(h?.links.map(\.title), ["PR #12", "GitHub"])
        XCTAssertEqual(h?.links.map(\.kind), [.pullRequest, .github])
    }

    func testFigmaArtifactAndPlainWeb() {
        let h = extract("""
            https://www.figma.com/design/abc/File
            https://claude.ai/code/artifact/xyz
            https://www.example.com/docs
            """)
        XCTAssertEqual(h?.links.map(\.kind), [.figma, .artifact, .web])
        XCTAssertEqual(h?.links.map(\.title), ["Figma", "Artifact", "example.com"])
    }

    func testTrailingMarkdownAndSentencePunctuationIsStripped() {
        let h = extract("Open **http://localhost:4321**, then (https://github.com/a/b/pull/7).")
        XCTAssertEqual(h?.links.map { $0.target.absoluteString },
                       ["http://localhost:4321", "https://github.com/a/b/pull/7"])
    }

    func testExistingFileAndFolderPathsBecomeChips() {
        let h = extract("Wrote /Users/dev/Projects/app/index.html and the bundle at ~/Projects/app/dist")
        XCTAssertEqual(h?.links.map(\.kind), [.file, .folder])
        XCTAssertEqual(h?.links.map(\.title), ["index.html", "dist/"])
        XCTAssertEqual(h?.links[1].target.path, NSString(string: "~/Projects/app/dist").expandingTildeInPath)
    }

    func testAPathThatDoesNotExistIsDropped() {
        let h = HandoffExtractor.extract(from: "See /Users/dev/gone.txt", pathKind: { _ in nil })
        XCTAssertNil(h?.links.first)
    }

    func testTheAgentsOwnBookkeepingIsNotADeliverable() {
        let h = extract("Log: ~/.claude/projects/x/y.jsonl and ~/Library/Application Support/CodeCat/codecat.log")
        XCTAssertEqual(h?.links ?? [], [])
    }

    func testLinksAreDedupedAndCappedAtFour() {
        let h = extract("""
            http://localhost:1 http://localhost:1 http://localhost:2 http://localhost:3
            http://localhost:4 http://localhost:5
            """)
        XCTAssertEqual(h?.links.map(\.title), ["localhost:1", "localhost:2", "localhost:3", "localhost:4"])
    }

    func testSummaryIsTheFirstLineWithMarkdownStripped() {
        let h = extract("## **Done**, tests green.\n\nSee http://localhost:4321")
        XCTAssertEqual(h?.summary, "Done, tests green.")
    }

    func testSummarySkipsFencesBulletsAndLinesThatAreOnlyALink()  {
        let h = extract("```\nhttp://localhost:4321\n- **http://localhost:4321**\nDeployed to staging.")
        XCTAssertEqual(h?.summary, "Deployed to staging.")
    }

    func testSummaryIsCappedLikeTheTaskText() {
        let long = String(repeating: "word ", count: 60)
        XCTAssertLessThanOrEqual(extract(long)?.summary?.count ?? 0, TaskText.maxLength)
    }

    func testNothingUsefulYieldsNil() {
        XCTAssertNil(extract(""))
        XCTAssertNil(extract("```\n```"))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter HandoffExtractorTests 2>&1 | tail -3`
Expected: compile error — `HandoffExtractor` does not exist.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Turns the agent's final message into what the row can hand the user: the first
/// line as a summary and the links in it as chips. Pure — the only question it
/// cannot answer alone, "does this path exist and is it a folder", is injected.
///
/// Measured on this machine (spec §1): one turn-ending message in ten carries a URL
/// or an absolute path, and the hosts are dev servers, GitHub, Figma and claude.ai.
public enum HandoffExtractor {
    public enum PathKind: Equatable, Sendable { case file, folder }

    /// Four is what one row of chips holds at island width without wrapping.
    public static let maxLinks = 4

    /// The real answer, from the file system. Tests inject a closure instead.
    public static func realPathKind(_ path: String) -> PathKind? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? .folder : .file
    }

    public static func extract(from text: String, pathKind: (String) -> PathKind?) -> Handoff? {
        let mentions = self.mentions(in: text)
        var links: [HandoffLink] = []
        var seen: Set<String> = []
        for mention in mentions {
            guard links.count < maxLinks else { break }
            guard let link = link(for: mention, pathKind: pathKind),
                  seen.insert(link.id).inserted else { continue }
            links.append(link)
        }
        let summary = summary(of: text, mentions: mentions.map(\.raw))
        guard summary != nil || !links.isEmpty else { return nil }
        return Handoff(summary: summary, links: links)
    }

    // MARK: - Mentions

    private struct Mention { let raw: String; let isPath: Bool; let location: Int }

    /// `(`, `)`, `[`, `]`, quotes and whitespace end a URL: they are the characters
    /// prose and markdown put around one. `*` and `_` do not — they are legal in a
    /// URL — so markdown emphasis is stripped from the end afterwards instead.
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s<>()\[\]"'`]+"#)
    /// Only absolute paths under the home directory: "src/foo.ts" in prose is too
    /// ambiguous to click. The look-behind keeps a path from starting in the middle
    /// of a URL or another path.
    private static let pathPattern = try! NSRegularExpression(
        pattern: #"(?<![\w/.\-])(?:/Users/|~/)[^\s"'`<>()\[\]]+"#)
    private static let trailing: Set<Character> = [".", ",", ";", ":", "!", "?", "*", "_"]

    private static func mentions(in text: String) -> [Mention] {
        let range = NSRange(text.startIndex..., in: text)
        var found: [Mention] = []
        for (pattern, isPath) in [(urlPattern, false), (pathPattern, true)] {
            for match in pattern.matches(in: text, range: range) {
                guard let r = Range(match.range, in: text) else { continue }
                var raw = String(text[r])
                while let last = raw.last, trailing.contains(last) { raw.removeLast() }
                guard !raw.isEmpty else { continue }
                found.append(Mention(raw: raw, isPath: isPath, location: match.range.location))
            }
        }
        return found.sorted { $0.location < $1.location }
    }

    // MARK: - Links

    private static func link(for mention: Mention, pathKind: (String) -> PathKind?) -> HandoffLink? {
        if mention.isPath { return fileLink(mention.raw, pathKind: pathKind) }
        guard let url = URL(string: mention.raw), let host = url.host?.lowercased() else { return nil }
        let path = url.path
        if host == "localhost" || host == "127.0.0.1" {
            let title = url.port.map { "\(host):\($0)" } ?? host
            return HandoffLink(kind: .localhost, title: title, target: url)
        }
        if host == "github.com" || host == "www.github.com" {
            let parts = path.split(separator: "/")
            if parts.count >= 4, parts[2] == "pull" {
                return HandoffLink(kind: .pullRequest,
                                   title: L10n.f("handoff.title.pr", "PR #%@", String(parts[3])), target: url)
            }
            return HandoffLink(kind: .github, title: L10n.t("handoff.title.github", "GitHub"), target: url)
        }
        if host.hasSuffix("figma.com") {
            return HandoffLink(kind: .figma, title: L10n.t("handoff.title.figma", "Figma"), target: url)
        }
        if host == "claude.ai", path.contains("/artifact") {
            return HandoffLink(kind: .artifact, title: L10n.t("handoff.title.artifact", "Artifact"), target: url)
        }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return HandoffLink(kind: .web, title: bare, target: url)
    }

    /// The agent's own bookkeeping — transcripts, logs, caches — is never what it
    /// is handing over, however often it names those paths.
    private static let excludedPrefixes = ["~/.claude", "~/Library"].map {
        NSString(string: $0).expandingTildeInPath
    }

    private static func fileLink(_ raw: String, pathKind: (String) -> PathKind?) -> HandoffLink? {
        let path = NSString(string: raw).expandingTildeInPath
        guard !excludedPrefixes.contains(where: { path.hasPrefix($0) }),
              let kind = pathKind(path) else { return nil }
        let name = (path as NSString).lastPathComponent
        let url = URL(fileURLWithPath: path, isDirectory: kind == .folder)
        switch kind {
        case .file: return HandoffLink(kind: .file, title: name, target: url)
        case .folder: return HandoffLink(kind: .folder, title: name + "/", target: url)
        }
    }

    // MARK: - Summary

    private static let markdownNoise = try! NSRegularExpression(
        pattern: #"(\*\*|__|`|^#+\s*|^>\s*|^[-*]\s+)"#, options: [.anchorsMatchLines])

    /// The first line that says something: not a code fence, not a bullet made of a
    /// bare link, with the emphasis and heading marks removed.
    private static func summary(of text: String, mentions: [String]) -> String? {
        for rawLine in text.components(separatedBy: .newlines) {
            if rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("```") { continue }
            var line = rawLine
            for mention in mentions { line = line.replacingOccurrences(of: mention, with: "") }
            let stripped = markdownNoise.stringByReplacingMatches(
                in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            let words = stripped.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            guard !words.isEmpty else { continue }
            // The line with its links kept, cleaned of markdown — a summary that
            // says "see localhost:4321" is still a summary.
            let clean = markdownNoise.stringByReplacingMatches(
                in: rawLine, range: NSRange(rawLine.startIndex..., in: rawLine), withTemplate: "")
            return TaskText.sanitized(clean)
        }
        return nil
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed" | tail -5`
Expected: `Executed 535 tests, with 0 failures`. If a title or summary assertion fails, adjust the implementation, not the test — the table in spec §3.4 is the contract.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/HandoffExtractor.swift Tests/CodeCatCoreTests/HandoffExtractorTests.swift
git commit -m "feat(core): extract the summary and links a finished turn hands over"
```

---

### Task 4: SessionStore — steps and handoff lifecycle, dots

**Files:**
- Modify: `Sources/CodeCatCore/SessionStore.swift`
- Test: `Tests/CodeCatCoreTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `SessionStore.init(routeCache: SessionRouteCache? = nil, pathKind: @escaping (String) -> HandoffExtractor.PathKind? = HandoffExtractor.realPathKind)`, `SessionStore.dots: [MascotTone]`.

- [ ] **Step 1: Write the failing tests**

Append to `SessionStoreTests`:

```swift
    // MARK: - Task steps

    private func activity(_ id: String = "s1", at time: Date, updates: [StepsUpdate] = [],
                          endsTurn: Bool = false, finalText: String? = nil) -> TranscriptActivity {
        TranscriptActivity(sessionId: id, projectPath: "/proj", description: "working on the task",
                           timestamp: time, endsTurn: endsTurn, stepsUpdates: updates, finalText: finalText)
    }

    func testStepsUpdatesApplyInOrder() {
        let store = SessionStore()
        store.apply(activity: activity(at: t0, updates: [
            .create(id: "1", title: "Read"), .create(id: "2", title: "Write"),
            .update(id: "1", status: .completed), .update(id: "2", status: .inProgress)]))
        let s = store.sessions["s1"]!
        XCTAssertEqual(s.steps.map(\.id), ["1", "2"])
        XCTAssertEqual(s.currentStep?.title, "Write")
        XCTAssertEqual(s.stepProgress?.done, 1)
    }

    func testCreateOnAnExistingIdReplacesRatherThanDuplicates() {
        let store = SessionStore()
        store.apply(activity: activity(at: t0, updates: [.create(id: "1", title: "Read")]))
        store.apply(activity: activity(at: t0 + 1, updates: [.create(id: "1", title: "Read again")]))
        XCTAssertEqual(store.sessions["s1"]?.steps.map(\.title), ["Read again"])
    }

    func testUpdateOnAnUnknownIdIsIgnoredAndRemoveRemoves() {
        let store = SessionStore()
        store.apply(activity: activity(at: t0, updates: [.create(id: "1", title: "Read"),
                                                        .update(id: "9", status: .completed),
                                                        .remove(id: "1")]))
        XCTAssertEqual(store.sessions["s1"]?.steps, [])
    }

    func testReplaceAllReplacesTheList() {
        let store = SessionStore()
        store.apply(activity: activity(at: t0, updates: [.create(id: "1", title: "Read")]))
        let list = [TaskStep(id: "0", title: "A", status: .completed), TaskStep(id: "1", title: "B", status: .pending)]
        store.apply(activity: activity(at: t0 + 1, updates: [.replaceAll(list)]))
        XCTAssertEqual(store.sessions["s1"]?.steps, list)
    }

    func testStepsSurviveTheEndOfATurnAndAStopHook() {
        let store = SessionStore()
        store.apply(activity: activity(at: t0, updates: [.create(id: "1", title: "Read")]))
        store.apply(activity: activity(at: t0 + 1, endsTurn: true))
        store.apply(hook: hook("Stop"), now: t0 + 2)
        XCTAssertEqual(store.sessions["s1"]?.steps.count, 1)
    }

    func testARealSessionStartClearsStepsButCompactionKeepsThem() {
        let store = SessionStore()
        store.apply(activity: activity(at: t0, updates: [.create(id: "1", title: "Read")]))
        store.apply(hook: HookEvent(hookEventName: "SessionStart", sessionId: "s1", cwd: "/proj",
                                    message: nil, source: "compact"), now: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.steps.count, 1)
        store.apply(hook: HookEvent(hookEventName: "SessionStart", sessionId: "s1", cwd: "/proj",
                                    message: nil, source: "clear"), now: t0 + 2)
        XCTAssertEqual(store.sessions["s1"]?.steps, [])
    }

    // MARK: - Handoff

    func testTheEndOfATurnSetsTheHandoff() {
        let store = SessionStore(pathKind: { _ in nil })
        store.apply(activity: activity(at: t0))
        store.apply(activity: activity(at: t0 + 1, endsTurn: true,
                                       finalText: "Done.\nhttp://localhost:4321"))
        let h = store.sessions["s1"]?.handoff
        XCTAssertEqual(h?.summary, "Done.")
        XCTAssertEqual(h?.links.map(\.title), ["localhost:4321"])
    }

    func testAnEndOfTurnWithNothingToHandOverClearsTheOldOne() {
        let store = SessionStore(pathKind: { _ in nil })
        store.apply(activity: activity(at: t0, endsTurn: true, finalText: "Done."))
        XCTAssertNotNil(store.sessions["s1"]?.handoff)
        store.apply(activity: activity(at: t0 + 1, endsTurn: true, finalText: nil))
        XCTAssertNil(store.sessions["s1"]?.handoff)
    }

    func testTheNextPromptAndTheNextWorkClearTheHandoff() {
        let store = SessionStore(pathKind: { _ in nil })
        store.apply(activity: activity(at: t0, endsTurn: true, finalText: "Done."))
        store.apply(hook: hook("UserPromptSubmit"), now: t0 + 1)
        XCTAssertNil(store.sessions["s1"]?.handoff)

        store.apply(activity: activity(at: t0 + 2, endsTurn: true, finalText: "Done again."))
        XCTAssertNotNil(store.sessions["s1"]?.handoff)
        store.apply(activity: activity(at: t0 + 3))
        XCTAssertNil(store.sessions["s1"]?.handoff)
    }

    func testAStopHookAfterTheTranscriptKeepsTheHandoff() {
        let store = SessionStore(pathKind: { _ in nil })
        store.apply(activity: activity(at: t0, endsTurn: true, finalText: "Done."))
        store.apply(hook: hook("Stop"), now: t0 + 1)
        XCTAssertEqual(store.sessions["s1"]?.handoff?.summary, "Done.")
    }

    // MARK: - Dots

    func testDotsFollowTheOrderedListAndSkipIdleSessions() {
        let store = SessionStore()
        store.apply(hook: hook("SessionStart", id: "idle"), now: t0)
        startWorking(store, id: "w", at: t0 + 1)
        startWorking(store, id: "q", at: t0 + 2)
        store.apply(hook: hook("Notification", id: "q", message: "Claude is asking"), now: t0 + 3)
        store.apply(activity: TranscriptActivity(sessionId: "d", projectPath: "/proj",
                                                 description: "finished the task",
                                                 timestamp: t0 + 4, endsTurn: true))
        XCTAssertEqual(store.dots, [.waiting, .working, .done])
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter SessionStoreTests 2>&1 | grep -E "error|failed|Executed" | tail -5`
Expected: compile errors on `pathKind:` and `dots`.

- [ ] **Step 3: Implement**

In `SessionStore`:

```swift
    /// Answers "does this path exist, and is it a folder" for `HandoffExtractor`.
    /// Injected so the store's tests never touch the disk.
    private let pathKind: (String) -> HandoffExtractor.PathKind?

    public init(routeCache: SessionRouteCache? = nil,
                pathKind: @escaping (String) -> HandoffExtractor.PathKind? = HandoffExtractor.realPathKind) {
        self.routeCache = routeCache
        self.pathKind = pathKind
    }

    /// One tone per session that counts — the same population as `indicator`, in
    /// the order `ordered` shows them. The island draws these as a cluster of dots
    /// when there are four or fewer, so "two working and one waiting" is visible
    /// without opening the menu.
    public var dots: [MascotTone] {
        ordered.compactMap { $0.status == .idle ? nil : $0.status.tone }
    }
```

In `apply(hook:)`: the `SessionStart` non-compact branch also does `s.steps = []` and `s.handoff = nil` next to `s.taskText = nil`. The `UserPromptSubmit` branch adds `s.handoff = nil` with the comment "the next turn has begun; the old result is stale".

In `apply(activity:)`, after the task-text `if` and before the `endsTurn` branch:

```swift
        for update in activity.stepsUpdates { s.apply(update) }
```

In the `endsTurn` branch, before `sessions[activity.sessionId] = s`:

```swift
            // What the turn hands over. Set to the extraction's answer even when that
            // is nil: a turn that said nothing worth a chip replaces an older handoff
            // rather than leaving it up.
            s.handoff = activity.finalText.flatMap {
                HandoffExtractor.extract(from: $0, pathKind: pathKind)
            }
```

In the working path (after the `endsTurn` branch), next to `s.finishedAt = nil`: `s.handoff = nil`.

Add a private extension on `Session` at the bottom of the file:

```swift
private extension Session {
    mutating func apply(_ update: StepsUpdate) {
        switch update {
        case .replaceAll(let list):
            steps = list
        case .create(let id, let title):
            // A create replayed from the primed transcript tail must not duplicate.
            if let index = steps.firstIndex(where: { $0.id == id }) {
                steps[index].title = title
            } else {
                steps.append(TaskStep(id: id, title: title, status: .pending))
            }
        case .update(let id, let status):
            guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
            steps[index].status = status
        case .remove(let id):
            steps.removeAll { $0.id == id }
        }
    }
}
```

- [ ] **Step 4: Run all tests**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed" | tail -5`
Expected: `Executed 547 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/SessionStore.swift Tests/CodeCatCoreTests/SessionStoreTests.swift
git commit -m "feat(core): sessions carry their task steps and the last turn's handoff; per-session dots"
```

---

### Task 5: Demo feed

**Files:**
- Modify: `Sources/CodeCatCore/DemoFeed.swift`
- Modify: `docs/superpowers/specs/2026-09-18-island-live-state-design.md` §3.6 (one sentence)
- Test: `Tests/CodeCatCoreTests/DemoFeedTests.swift`

**Interfaces:**
- Consumes: `TranscriptActivity.init(stepsUpdates:finalText:)`.
- Produces: `DemoFeed.steps: [TaskStep]`, `DemoFeed.handoffText: String`.

- [ ] **Step 1: Amend the spec**

In §3.6 replace "carries the summary "Готово: тесты зелёные, релиз 0.4.1 собран" and links `localhost:4321`, `PR #12`, and a folder" with "carries the summary "Готово: тесты зелёные, релиз 0.4.1 собран" and links `localhost:4321`, `PR #12` and `Figma` (a folder would need a real path on the capture machine; a folder chip is checked on a live session instead)".

- [ ] **Step 2: Write the failing tests**

Append to `DemoFeedTests`:

```swift
    func testTheWorkingSessionCarriesAStepListWithACurrentStep() {
        let store = SessionStore()
        let now = Date()
        _ = aggregate(after: .working, in: store, now: now)
        let s = store.sessions[DemoFeed.sessionIDs[0]]
        XCTAssertEqual(s?.steps.count, 5)
        XCTAssertEqual(s?.currentStep?.displayTitle, DemoFeed.steps[2].activeForm)
        XCTAssertEqual(s?.stepProgress?.done, 2)
    }

    func testTheDoneSessionCarriesAHandoffWithThreeChips() {
        let store = SessionStore(pathKind: { _ in nil })
        var now = Date()
        for phase in DemoFeed.leadIn(for: .done) + [.done] {
            now = now.addingTimeInterval(4)
            _ = aggregate(after: phase, in: store, now: now)
        }
        let h = store.sessions[DemoFeed.sessionIDs[1]]?.handoff
        XCTAssertEqual(h?.summary, "Готово: тесты зелёные, релиз 0.4.1 собран.")
        XCTAssertEqual(h?.links.map(\.title), ["localhost:4321", "PR #12", "Figma"])
    }
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --filter DemoFeedTests 2>&1 | tail -4`
Expected: compile error on `DemoFeed.steps`.

- [ ] **Step 4: Implement**

Add to `DemoFeed`:

```swift
    /// The first session's plan — five steps with the third under way, so a
    /// screenshot shows a bar that is neither empty nor full.
    public static let steps: [TaskStep] = [
        TaskStep(id: "0", title: "Найти, где дублируются карточки", activeForm: "Ищу, где дублируются карточки", status: .completed),
        TaskStep(id: "1", title: "Написать падающий тест", activeForm: "Пишу падающий тест", status: .completed),
        TaskStep(id: "2", title: "Починить курсор пагинации", activeForm: "Чиню курсор пагинации", status: .inProgress),
        TaskStep(id: "3", title: "Прогнать тесты ленты", activeForm: "Прогоняю тесты ленты", status: .pending),
        TaskStep(id: "4", title: "Снять скриншоты для PR", activeForm: "Снимаю скриншоты для PR", status: .pending),
    ]

    /// The second session's final message — a summary line and three links, one of
    /// each kind a chip most often is.
    public static let handoffText = """
        Готово: тесты зелёные, релиз 0.4.1 собран.

        Посмотреть: http://localhost:4321 и https://github.com/you/orbit-api/pull/12
        Макет: https://www.figma.com/design/demo/orbit
        """
```

In `activities(for:now:)`:

- Replace the guard with `guard phase != .idle else { return [] }` and add, at the top of the function's body after the guard:

```swift
        if phase == .done {
            // The second session's turn ends in the transcript, with its text — the
            // hook alone (`Stop`) has no message to hand over.
            return [TranscriptActivity(sessionId: sessionIDs[1], projectPath: projects[1],
                                       description: L10n.t("activity.done", "finished the task"),
                                       timestamp: now.addingTimeInterval(1), endsTurn: true,
                                       finalText: handoffText)]
        }
```

- In the existing `compactMap`, the activity for `index == 0` carries `stepsUpdates: [.replaceAll(steps)]` (other indices pass `[]`).

- [ ] **Step 5: Run all tests**

Run: `swift test 2>&1 | grep -E "Executed|error:|failed" | tail -5`
Expected: `Executed 549 tests, with 0 failures`. `testAnyPhaseCanBeEnteredDirectly` must still pass: the `.done` activity sets session 1 to `.done`, which the aggregate already was.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodeCatCore/DemoFeed.swift Tests/CodeCatCoreTests/DemoFeedTests.swift docs/superpowers/specs/2026-09-18-island-live-state-design.md
git commit -m "feat(core): the demo feed carries a step list and a handoff to photograph"
```

---

### Task 6: ToneColor and Motion constants

**Files:**
- Create: `Sources/CodeCatApp/ToneColor.swift`, `Sources/CodeCatApp/Motion.swift`
- Modify: `Sources/CodeCatApp/IslandView.swift` (the `color(for:)` at the bottom), `Sources/CodeCatApp/MascotBadge.swift:85-92`, `Sources/CodeCatApp/SessionListView.swift:421-430`, `Sources/CodeCatApp/MenuStyle.swift`

**Interfaces:**
- Produces: `ToneColor.color(for: MascotTone) -> Color`; `Motion.*`; `MenuStyle.chipFill/chipHover/barTrack`.

- [ ] **Step 1: Create `ToneColor.swift`**

```swift
import SwiftUI
import CodeCatCore

/// The four state colours, written once. The island glow, the island dots, the
/// floating badge and the session-row dots all read from here, so a green on one
/// surface is the same green everywhere — three copies of this switch used to
/// exist and only agreed by discipline.
enum ToneColor {
    static func color(for tone: MascotTone) -> Color {
        switch tone {
        case .working: return .green
        case .waiting: return .orange
        case .done: return .blue
        case .problem: return .red
        case .sleeping: return Color.white.opacity(0.35)
        }
    }
}
```

- [ ] **Step 2: Create `Motion.swift`**

```swift
import SwiftUI

/// Every duration and curve the new island surfaces use, in one place, so the
/// numbers in the design spec (§8) and the numbers on screen are the same numbers.
///
/// The rules behind them: the island is seen hundreds of times a day, so nothing
/// here loops (the waiting pulse is the one exception, and it is a request for
/// attention); everything animates once, on change, and never longer than 300 ms;
/// enter curves are ease-out because the first frames are the ones being watched.
enum Motion {
    /// Tone glow and dot colour changes.
    static let toneCrossfade = Animation.easeOut(duration: 0.25)
    /// A new tone's single bloom — scale 0.9 → 1 and opacity 0 → 1 — measured from
    /// `AppState.statusSince`, so a rebuilt view does not replay it.
    static let bloomDuration: TimeInterval = 0.25
    static let dotAppear = Animation.easeOut(duration: 0.18)
    static let dotDisappear = Animation.easeOut(duration: 0.15)
    /// Repositioning and any height change: the island's own reveal spring, no
    /// overshoot (see `IslandView.reveal`).
    static var reposition: Animation { IslandView.reveal }
    static let stepTitle = Animation.easeOut(duration: 0.20)
    static let chipAppear = Animation.easeOut(duration: 0.20)
    static let chipStagger: TimeInterval = 0.04
    static let chipPress = Animation.easeOut(duration: 0.12)
    static let headTint = Animation.easeOut(duration: 0.30)
    /// The one loop: the waiting dot, the same cycle the badge has always used.
    static let pulse = Animation.easeInOut(duration: 3.0)

    /// Ease-out cubic for a value driven by time rather than by SwiftUI.
    static func easeOut(_ progress: Double) -> Double {
        let p = min(1, max(0, progress))
        return 1 - pow(1 - p, 3)
    }
}
```

- [ ] **Step 3: Route the three colour switches through `ToneColor`**

- `IslandView.color(for:)`: body becomes `ToneColor.color(for: tone)`.
- `MascotBadge.color(for:)`: same.
- `SessionListView.color(for status:)`: `.idle` keeps `.secondary` (grey on the panel's light material); every other case returns `ToneColor.color(for: status.tone)`.

- [ ] **Step 4: Add chip and bar surfaces to `MenuStyle`**

After `cellSpacing` add `var chipFill: Color`, `var chipHover: Color`, `var barTrack: Color`. In `.panel`: `chipFill: Color.primary.opacity(0.07), chipHover: Color.primary.opacity(0.14), barTrack: Color.primary.opacity(0.10)`. In `.island`: `chipFill: Color.white.opacity(0.10), chipHover: Color.white.opacity(0.20), barTrack: Color.white.opacity(0.10)`.

- [ ] **Step 5: Build and test**

Run: `swift build 2>&1 | grep -E "error|Compiling|Build" | tail -3 && swift test 2>&1 | grep Executed | tail -1`
Expected: `Build complete!`, 549 tests green.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodeCatApp/ToneColor.swift Sources/CodeCatApp/Motion.swift Sources/CodeCatApp/IslandView.swift Sources/CodeCatApp/MascotBadge.swift Sources/CodeCatApp/SessionListView.swift Sources/CodeCatApp/MenuStyle.swift
git commit -m "refactor(app): one tone→colour function and one home for motion constants"
```

---

### Task 7: Island strip — tone glow and dot cluster

**Files:**
- Modify: `Sources/CodeCatApp/IslandView.swift`

**Interfaces:**
- Consumes: `appState.store.indicator`, `appState.store.dots`, `appState.statusSince`, `ToneColor`, `Motion`.

- [ ] **Step 1: Add the environment and the glow**

At the top of `IslandView` add `@Environment(\.accessibilityReduceMotion) private var reduceMotion`.

Replace the `cat` property with:

```swift
    private var cat: some View {
        MascotView(skin: appState.skin,
                   status: appState.store.aggregate,
                   indicator: appState.store.indicator,
                   drawingSize: spriteSize,
                   canvasSize: CGSize(width: spriteSize.width, height: height),
                   showsBadge: false,
                   since: appState.statusSince,
                   onLoadFailure: { [appState] skin in appState.reportSkinLoadFailure(skin) })
            .background(glow)
    }

    /// A soft radial wash behind the cat in the aggregate tone — the state readable
    /// from across the room, before the eye finds the dots. Sleeping draws nothing.
    ///
    /// The bloom on a new tone is computed from `statusSince`, not from view state:
    /// the controller reassigns the island's root view on every state change, and a
    /// `@State` would replay the bloom on each of those. `TimelineView` runs only
    /// while the bloom is under way (`paused` afterwards), so the strip costs nothing
    /// at rest.
    private var glow: some View {
        let tone = appState.store.indicator.tone
        let since = appState.statusSince
        let settled = Date().timeIntervalSince(since) > Motion.bloomDuration + 0.05
        return TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: settled)) { context in
            let progress = reduceMotion ? 1.0
                : Motion.easeOut(context.date.timeIntervalSince(since) / Motion.bloomDuration)
            Circle()
                .fill(RadialGradient(colors: [ToneColor.color(for: tone).opacity(0.42), .clear],
                                     center: .center, startRadius: 0, endRadius: height))
                .frame(width: height * 2, height: height * 2)
                .scaleEffect(0.9 + 0.1 * progress)
                .opacity(tone == .sleeping ? 0 : progress)
                .animation(Motion.toneCrossfade, value: tone)
        }
        .allowsHitTesting(false)
    }
```

- [ ] **Step 2: Add the dot cluster**

Replace the `counter` property's non-sleeping branches so the order is: sleeping dot as today; then `let dots = appState.store.dots; if (1...4).contains(dots.count) { cluster(dots) } else if indicator.tone == .waiting { …existing pulsing capsule… } else { …existing capsule… }`.

Add:

```swift
    /// One dot per session, up to four: one centred, two in a row, three or four in
    /// a 2×2 grid. Each dot is its session's own tone, so "two working and one
    /// waiting" is legible without opening the menu — the capsule's one tone and
    /// one count could not say it. Five or more fall back to the capsule: a cluster
    /// of nine dots is a rash, not a reading.
    private func cluster(_ dots: [MascotTone]) -> some View {
        let rows: [[(Int, MascotTone)]] = stride(from: 0, to: dots.count, by: 2).map { start in
            Array(dots.enumerated().dropFirst(start).prefix(dots.count <= 2 ? dots.count : 2))
        }
        return VStack(spacing: 4) {
            ForEach(rows, id: \.first!.0) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.0) { _, tone in dot(tone) }
                }
            }
        }
        .animation(reduceMotion ? nil : Motion.reposition, value: dots)
        .help(clusterHelp(dots))
    }

    private func dot(_ tone: MascotTone) -> some View {
        let base = Circle()
            .fill(ToneColor.color(for: tone))
            .frame(width: 6, height: 6)
            .animation(Motion.toneCrossfade, value: tone)
            .transition(reduceMotion ? .opacity
                        : .scale(scale: 0.6).combined(with: .opacity))
        return Group {
            if tone == .waiting {
                if reduceMotion {
                    // No movement, but the signal survives: a ring makes the waiting
                    // dot the one that is not like the others.
                    base.overlay(Circle().strokeBorder(ToneColor.color(for: .waiting), lineWidth: 1.5)
                                    .frame(width: 11, height: 11))
                } else {
                    base.phaseAnimator([false, true]) { content, pulse in
                        content.scaleEffect(pulse ? 1.35 : 1.0)
                    } animation: { _ in Motion.pulse }
                }
            } else {
                base
            }
        }
    }

    /// "2 working, 1 waiting for you" — the same words the menu-bar tooltip uses.
    private func clusterHelp(_ dots: [MascotTone]) -> String {
        var parts: [String] = []
        let working = dots.filter { $0 == .working }.count
        let waiting = dots.filter { $0 == .waiting }.count
        if working > 0 { parts.append(L10n.f("menubar.working", "working: %d", working)) }
        if waiting > 0 { parts.append(L10n.f("menubar.waiting", "waiting: %d", waiting)) }
        if dots.contains(.problem) { parts.append(L10n.t("menubar.problem", "problem")) }
        if dots.contains(.done) { parts.append(L10n.t("menubar.done", "done")) }
        return parts.joined(separator: ", ")
    }
```

The `.transition` on each dot needs an animated container for appear/disappear: wrap the `ForEach(row)` contents so that `withAnimation` applies — the `.animation(_, value: dots)` on the `VStack` covers insertions and removals of the identity-keyed dots (`Motion.dotAppear` for insertion and `Motion.dotDisappear` for removal are approximated by the reposition spring here; if the appear looks slower than 180 ms on the frame captures, switch the container to `.animation(Motion.dotAppear, value: dots.count)` and keep `Motion.reposition` for `value: dots`).

- [ ] **Step 3: Build and look**

```bash
swift build 2>&1 | grep -E "error|Build" | tail -3
make app 2>&1 | tail -1
pkill -x CodeCat; sleep 1
open dist/CodeCat.app --args --demo
```

Set the display mode to Island from the cat's menu if it is not already. Capture the strip in each demo phase (the loop is 4 s per phase; or pin one with `--demo-phase=waiting`):

```bash
for i in 1 2 3 4 5 6 7 8; do screencapture -x -R 0,0,1512,40 /tmp/strip-$i.png; sleep 2; done
```

Look at the eight images: a glow behind the cat in green / orange / blue; a cluster with 2–3 dots whose colours match the rows; a pulsing orange dot in the waiting phase; no glow and a single grey dot in the idle phase.

- [ ] **Step 4: Commit**

```bash
git add Sources/CodeCatApp/IslandView.swift
git commit -m "feat(island): a tone glow behind the cat and one dot per session in the strip"
```

---

### Task 8: Step line with progress bar

**Files:**
- Create: `Sources/CodeCatApp/StepLineView.swift`
- Modify: `Sources/CodeCatApp/SessionListView.swift` (the `sessionRow` VStack)
- Modify: `Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `Session.currentStep`, `Session.stepProgress`, `MenuStyle.barTrack`, `ToneColor`, `Motion`.
- Produces: `StepLineView(title: String, done: Int, total: Int, demoted: Bool)`.

- [ ] **Step 1: Create `StepLineView.swift`**

```swift
import SwiftUI
import CodeCatCore

/// The step the agent is on, with a counter and a thin bar: "Writing the parser ·
/// 3/5". Drawn under the task line while a session is working and has a list.
///
/// The title changes with a crossfade through a 2 px blur: two texts fading over
/// each other read as two objects, and the blur melts them into one change.
struct StepLineView: View {
    let title: String
    let done: Int
    let total: Int
    /// Panel rows print the line at 11 pt like their status line; island rows at 10.
    let demoted: Bool

    @Environment(\.menuStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ZStack(alignment: .leading) {
                    Text(title)
                        .font(.system(size: demoted ? 10 : 11))
                        .foregroundStyle(style.secondary)
                        .lineLimit(1)
                        .id(title)
                        .transition(reduceMotion ? .opacity : .blurFade)
                }
                .animation(Motion.stepTitle, value: title)
                Spacer(minLength: 0)
                Text(L10n.f("row.step.progress", "%d/%d", done, total))
                    .font(.system(size: 10))
                    .foregroundStyle(style.tertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.stepTitle, value: done)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(style.barTrack)
                    Capsule()
                        .fill(ToneColor.color(for: .working))
                        .frame(width: proxy.size.width * CGFloat(done) / CGFloat(max(total, 1)))
                }
            }
            .frame(height: 2)
            .animation(reduceMotion ? nil : Motion.reposition, value: done)
        }
    }
}

/// Opacity plus a small blur — the outgoing text softens as it goes, and the
/// incoming one sharpens as it arrives.
private struct BlurFade: ViewModifier {
    let radius: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

extension AnyTransition {
    static let blurFade = AnyTransition.modifier(
        active: BlurFade(radius: 2, opacity: 0),
        identity: BlurFade(radius: 0, opacity: 1))
}
```

- [ ] **Step 2: Place it in the row**

In `SessionListView.sessionRow`, inside the `VStack(alignment: .leading, spacing: style.lineSpacing)`, replace the `if let task = task(session), !statusOutranksTask(session) { … } else { … }` block with:

```swift
                if let task = task(session), !statusOutranksTask(session) {
                    taskLine(task, lines: style.rowLayout == .twoLine ? 1 : 2)
                    // The agent's own plan outranks the tool in hand: "Writing the
                    // parser · 3/5" says where the work is, "editing api.ts" only
                    // that it moves. On the panel the step takes the status line's
                    // place; on the island the row grows a third line for it.
                    if let step = stepLine(session) {
                        step
                    } else if style.rowLayout == .threeLine {
                        statusLine(session, demoted: true)
                    }
                } else {
                    statusLine(session, demoted: false)
                    if let task = task(session), style.rowLayout == .threeLine {
                        taskLine(task, lines: 1)
                    }
                }
```

And add:

```swift
    /// The step line, or nil when there is nothing to show: the session is not
    /// working, has no list, its list is finished, or the switch is off.
    private func stepLine(_ session: Session) -> StepLineView? {
        guard appState.showsTaskText, session.status == .working,
              let step = session.currentStep, let progress = session.stepProgress else { return nil }
        return StepLineView(title: step.displayTitle, done: progress.done, total: progress.total,
                            demoted: style.rowLayout == .twoLine)
    }
```

Wrap the row's outer `content` with `.animation(reduceMotion ? nil : Motion.reposition, value: session.currentStep?.id)` so the row's height change travels on the spring; add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` to `SessionListView`.

- [ ] **Step 3: Add the string**

In `Localizable.strings`, under a new `/* MARK: - Session row: steps and handoff */` section:

```
/* The step counter beside the current step: completed over total. */
"row.step.progress" = "%d/%d";
```

- [ ] **Step 4: Build, test, look**

```bash
swift build 2>&1 | grep -E "error|Build" | tail -2 && swift test 2>&1 | grep Executed | tail -1
make app 2>&1 | tail -1 && pkill -x CodeCat; sleep 1; open dist/CodeCat.app --args --demo
```

Open the island menu (hover) in the working phase and capture: `screencapture -x -R 0,0,1512,300 /tmp/step.png`. Expected: under "codecat" and its task, the line "Чиню курсор пагинации  2/5" and a 2 pt bar two-fifths green. Panel mode: the same line in place of "working · editing IslandLayout.swift".

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatApp/StepLineView.swift Sources/CodeCatApp/SessionListView.swift Resources/en.lproj/Localizable.strings
git commit -m "feat(row): the agent's current step and progress under the task"
```

---

### Task 9: Handoff chips (spike, then build)

**Files:**
- Create: `Sources/CodeCatApp/HandoffChipView.swift`
- Modify: `Sources/CodeCatApp/SessionListView.swift`
- Modify: `Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `Session.handoff`, `HandoffLink`, `MenuStyle.chipFill/chipHover`, `Motion`, `onHoverRegion`.
- Produces: `HandoffChipView(link: HandoffLink, index: Int)`, `HandoffBlockView(handoff: Handoff, compact: Bool)`.

- [ ] **Step 1: Spike — does a drag start from the island's short (non-key) menu?**

Temporarily add to `IslandMenuView`, above `SessionListView`, a `Text("drag me").onDrag { NSItemProvider(object: URL(string: "http://localhost:4321")! as NSURL) }`. Build, run the demo, hover to open the short menu, and drag the text onto a Safari window. Record the outcome in this task's commit message. `IslandHostingView` already answers `acceptsFirstMouse` with true (`HoverHostingView.swift:138`), so the expectation is that the drag works. If it does not, the chip still opens on click everywhere and drags from the full menu and the panel — note it in `docs/verification-checklist.md` in Task 12. Remove the spike text before continuing.

- [ ] **Step 2: Create `HandoffChipView.swift`**

```swift
import SwiftUI
import AppKit
import CodeCatCore

/// One link a finished turn handed over: a symbol, a short title, a click that
/// opens it and a drag that carries it out of the island into a browser or Finder
/// window — the one scene from the concept video that is pure use.
struct HandoffChipView: View {
    let link: HandoffLink
    /// Position in the row, for the stagger.
    let index: Int

    @Environment(\.menuStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Image(systemName: link.kind.symbol).font(.system(size: 10))
                Text(shortTitle).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(style.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(hovering ? style.chipHover : style.chipFill))
        }
        .buttonStyle(ChipButtonStyle())
        .onDrag { NSItemProvider(object: link.target as NSURL) }
        .onHoverRegion { phase in
            hovering = phase == .active
            if hovering { NSCursor.pointingHand.set() }
        }
        .help(link.target.absoluteString)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.95)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            let delay = reduceMotion ? 0 : Double(index) * Motion.chipStagger
            withAnimation(Motion.chipAppear.delay(delay)) { appeared = true }
        }
    }

    /// Eighteen characters: a `localhost:4321` fits, a long file name is cut.
    private var shortTitle: String {
        link.title.count > 18 ? String(link.title.prefix(17)) + "…" : link.title
    }

    private func open() {
        switch link.kind {
        case .folder: NSWorkspace.shared.activateFileViewerSelecting([link.target])
        default: NSWorkspace.shared.open(link.target)
        }
    }
}

/// Press feedback on mouse-down, not on release — the interface is listening.
private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.chipPress, value: configuration.isPressed)
    }
}

extension HandoffLink.Kind {
    var symbol: String {
        switch self {
        case .localhost: return "globe"
        case .pullRequest: return "arrow.triangle.pull"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .figma: return "paintpalette"
        case .artifact: return "doc.richtext"
        case .web: return "link"
        case .file: return "doc"
        case .folder: return "folder"
        }
    }
}

/// The summary and the chips, under a finished or waiting row.
struct HandoffBlockView: View {
    let handoff: Handoff
    /// Island rows have one line for the summary; panel rows two.
    let compact: Bool
    @Environment(\.menuStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let summary = handoff.summary {
                Text(summary)
                    .font(.system(size: compact ? 10 : 11))
                    .foregroundStyle(style.secondary)
                    .lineLimit(compact ? 1 : 2)
                    .truncationMode(.tail)
            }
            if !handoff.links.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(handoff.links.enumerated()), id: \.element.id) { index, link in
                        HandoffChipView(link: link, index: index)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 3: Place the block in the row**

In `SessionListView.sessionRow`, inside the text `VStack`, after the task/status block and before the unavailable-reason hint:

```swift
                if let handoff = handoffBlock(session) {
                    handoff.padding(.top, 2)
                }
```

Add:

```swift
    /// The handoff block, when the session has one to show and the switch is on. It
    /// is the agent's words and the user's paths — the same class of content as the
    /// task, hidden by the same switch.
    private func handoffBlock(_ session: Session) -> HandoffBlockView? {
        guard appState.showsTaskText, let handoff = session.handoff else { return nil }
        switch session.status {
        case .done, .waitingForYou: return HandoffBlockView(handoff: handoff, compact: style.rowLayout == .twoLine)
        case .idle, .working, .crashed: return nil
        }
    }
```

A click on a chip must not also fire the row's `onTapGesture`. SwiftUI's `Button` claims the click before the parent's tap gesture on macOS; verify on the rendered check below and, if the row jumps too, wrap the block in `.onTapGesture {}` (an empty gesture closer to the chips wins over the outer one).

- [ ] **Step 4: Add the strings**

```
/* Chip titles for links the agent handed over. */
"handoff.title.pr" = "PR #%@";
"handoff.title.github" = "GitHub";
"handoff.title.figma" = "Figma";
"handoff.title.artifact" = "Artifact";
```

- [ ] **Step 5: Build, test, look**

```bash
swift build 2>&1 | grep -E "error|Build" | tail -2 && swift test 2>&1 | grep Executed | tail -1
make app 2>&1 | tail -1 && pkill -x CodeCat; sleep 1; open dist/CodeCat.app --args --demo
```

In the done phase, open the menu: under "orbit-api" the line "Готово: тесты зелёные, релиз 0.4.1 собран." and three chips: globe `localhost:4321`, pull `PR #12`, palette `Figma`. Frame-capture the reveal at 50 ms: `for i in $(seq 1 8); do screencapture -x -R 0,0,1512,320 /tmp/chips-$i.png; sleep 0.05; done` started the instant the menu opens — chips should arrive one after another, left to right. Click `localhost:4321`: the default browser opens it and the menu stays. Drag `PR #12` onto a Safari window: it navigates there.

- [ ] **Step 6: Commit**

```bash
git add Sources/CodeCatApp/HandoffChipView.swift Sources/CodeCatApp/SessionListView.swift Resources/en.lproj/Localizable.strings
git commit -m "feat(row): what a finished turn handed over — its summary and draggable link chips

Spike: a drag from the short (non-key) island menu <does / does not> start; write the observed outcome here."
```

---

### Task 10: Tinted menu head

**Files:**
- Modify: `Sources/CodeCatApp/IslandMenuView.swift`

- [ ] **Step 1: Implement**

Add to `IslandMenuView`:

```swift
    /// A faint wash of the aggregate tone at the top of the menu when it is asking
    /// for attention — waiting or problem. Not for working or done: a permanent
    /// green head would teach the eye to ignore the orange one.
    private var headTint: some View {
        let tone = appState.store.indicator.tone
        let shown = tone == .waiting || tone == .problem
        return LinearGradient(colors: [ToneColor.color(for: tone).opacity(0.16), .clear],
                              startPoint: .top, endPoint: .bottom)
            .frame(height: 64)
            .opacity(shown ? 1 : 0)
            .animation(Motion.headTint, value: tone)
            .allowsHitTesting(false)
    }
```

On the `ScrollView` add `.background(alignment: .top) { headTint }` (before `.frame(width:)`).

- [ ] **Step 2: Build and look**

Build, run the demo, open the menu in the waiting phase: an orange wash fading over the top 64 pt; in the working phase none. Run `open dist/CodeCat.app --args --demo --demo-phase=problem --demo-open-menu` to see the red one.

- [ ] **Step 3: Commit**

```bash
git add Sources/CodeCatApp/IslandMenuView.swift
git commit -m "feat(island): the menu head takes the tone of a session asking for attention"
```

---

### Task 11: The switch's label and help

**Files:**
- Modify: `Sources/CodeCatApp/SettingsSectionView.swift:168-169`
- Modify: `Resources/en.lproj/Localizable.strings:36`

- [ ] **Step 1: Change the label and add help**

```swift
        SettingToggle(L10n.t("setting.show.task", "Show what each session is doing"),
                      isOn: $appState.showsTaskText)
        Text(L10n.t("setting.show.task.help",
                    "The task in your words, the agent's current step, and the final message "
                    + "with its links. Off for a demo or a shared screen."))
            .font(.system(size: 11))
            .foregroundStyle(style.secondary)
```

In the catalog: `"setting.show.task" = "Show what each session is doing";` and a new
`"setting.show.task.help" = "The task in your words, the agent's current step, and the final message with its links. Off for a demo or a shared screen.";`

- [ ] **Step 2: Test and commit**

Run: `swift test 2>&1 | grep -E "Executed|failed" | tail -2` — the catalog test passes.

```bash
git add Sources/CodeCatApp/SettingsSectionView.swift Resources/en.lproj/Localizable.strings
git commit -m "feat(settings): one switch for everything from inside the conversation"
```

---

### Task 12: Docs

**Files:**
- Modify: `CHANGELOG.md` (Unreleased), `README.md` ("What it does"), `docs/verification-checklist.md`, the spec §9.

- [ ] **Step 1: CHANGELOG — under `## [Unreleased]` → `### Added`, before the existing entries**

```markdown
- **The island says which session is in which state.** Up to four dots in the
  right wing, one per session in its own colour, instead of one colour and a
  count — "two working, one waiting for you" without opening the menu. Five or
  more go back to the counter. A glow behind the cat carries the overall tone
  (`IslandView`).
- **Every working row shows the agent's current step.** Claude Code writes its
  plan into the transcript (`TodoWrite`, `TaskCreate`, `TaskUpdate`); CodeCat
  now reads it and the row says "Writing the parser · 3/5" with a thin bar,
  under the task in your words (`TaskStep`, `StepLineView`).
- **A finished row hands over what to look at.** The first line of the agent's
  last message and chips for the links and files in it — `localhost:4321`,
  `PR #12`, `Figma`, an artifact, a file it wrote. Click opens; drag carries the
  link out of the island into a browser or Finder window (`HandoffExtractor`,
  `HandoffChipView`). Measured on real transcripts, one turn in ten ends with
  one.
- **The island menu's head takes the tone** of a session waiting for you or
  one that died — a faint orange or red wash, nothing for working or done.
- **Motion with a rule.** Nothing new loops; every change animates once, under
  300 ms, from the value on screen; Reduce Motion turns scale and stagger into
  crossfades and the waiting pulse into a ring (`Motion`).

### Changed
- **"Show what you asked each session for"** is now "Show what each session is
  doing" and hides the step and the handoff together with the task.
```

- [ ] **Step 2: README — in "What it does", after the "Jumps to a session" bullet**

```markdown
- **Says where each session is.** The row shows the agent's current step and
  progress from its own task list; the island shows one dot per session.
- **Hands over the result.** When a turn ends, the row shows the agent's last
  line and chips for the links in it — the dev server, the PR, the file. Click
  opens, drag carries it into a browser window.
```

- [ ] **Step 3: Verification checklist — append a section**

```markdown
## Island live state (0.5.0)

Demo: `dist/CodeCat.app/Contents/MacOS/CodeCat --demo`, island mode.

- [ ] Working phase, strip: green glow behind the cat; a cluster of two green dots.
- [ ] Waiting phase, strip: the orange dot pulses on a 3 s cycle; glow orange.
- [ ] Done phase, strip: glow blue; one blue dot among the others.
- [ ] Idle phase: no glow, one grey dot.
- [ ] Five live sessions: the capsule with a count returns.
- [ ] Working phase, menu: "codecat" row shows "Чиню курсор пагинации  2/5" and a bar two-fifths full.
- [ ] Done phase, menu: "orbit-api" row shows the summary and chips localhost:4321, PR #12, Figma.
- [ ] Chip click opens the browser; the menu stays open.
- [ ] Chip drag onto a Safari window navigates there; a folder chip (live session) dragged to the Desktop copies.
- [ ] Waiting phase, menu: orange wash at the top; none in the working phase; red with `--demo-phase=problem`.
- [ ] Frame captures (`screencapture` every 50 ms, 8 frames) of: the glow bloom on a tone change, a dot appearing, the step title changing, the chips arriving. Compare frames 1, 5 and 8 with the spec's start/mid/end values.
- [ ] System Settings → Accessibility → Reduce Motion on: no scale, no stagger; the waiting dot is a ring.
- [ ] Panel mode: the step line replaces the status line; the handoff block under the done row.
- [ ] Switch off "Show what each session is doing": rows are name, status, duration.
```

- [ ] **Step 4: Spec §9 — drop the `island.dots.help` line**

The cluster's help text is composed from the existing `menubar.*` strings; no new key exists. Remove that bullet from §9.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md README.md docs/verification-checklist.md docs/superpowers/specs/2026-09-18-island-live-state-design.md
git commit -m "docs: island live state — changelog, README, verification checklist"
```

---

### Task 13: Visual verification and install (Fable, by hand)

Not delegated. Run the checklist section from Task 12 against `make app`; every line is either ticked from a rendered image or listed as failed in the final report. Then, per the project's rule, install the build:

```bash
make app && rm -rf /Applications/CodeCat.app && cp -R dist/CodeCat.app /Applications/ && open /Applications/CodeCat.app
```
