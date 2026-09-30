import XCTest
@testable import CodeCatCore

/// The demo loop exists to be photographed, and its failure mode is quiet: a cat
/// cycling through three poses instead of four looks like a cat cycling through
/// poses. So what is asserted here is the property that matters — every state the
/// mascot can be in is actually reached — driven through the real `SessionStore`
/// rather than by reading the scripted events back.
final class DemoFeedTests: XCTestCase {

    private func aggregate(after phase: DemoFeed.Phase, in store: SessionStore,
                           now: Date) -> AggregateStatus {
        for event in DemoFeed.events(for: phase) { store.apply(hook: event, now: now) }
        for activity in DemoFeed.activities(for: phase, now: now) { store.apply(activity: activity) }
        return store.aggregate
    }

    func testTheLoopReachesEveryMascotState() {
        let store = SessionStore()
        var now = Date()
        var seen: Set<AggregateStatusKey> = []
        for step in 0..<DemoFeed.Phase.allCases.count {
            now = now.addingTimeInterval(4)
            seen.insert(AggregateStatusKey(aggregate(after: DemoFeed.phase(atStep: step),
                                                     in: store, now: now)))
        }
        // `.problem` is the exception, and deliberately: it means a session died,
        // which is not something to script into a promotional loop.
        XCTAssertEqual(seen, [.sleeping, .working, .waiting, .done])
    }

    /// Each phase is a full description of where every session should be, so a
    /// capture script can jump straight to the one it wants. That only holds if the
    /// phases are order-independent.
    func testAnyPhaseCanBeEnteredDirectly() {
        for phase in DemoFeed.Phase.allCases {
            let store = SessionStore()
            let now = Date()
            let direct = AggregateStatusKey(aggregate(after: phase, in: store, now: now))
            let expected: AggregateStatusKey = {
                switch phase {
                case .idle: return .sleeping
                case .working: return .working
                case .waiting: return .waiting
                case .done: return .done
                }
            }()
            XCTAssertEqual(direct, expected, "\(phase) entered directly")
        }
    }

    func testWorkingPhaseCountsExactlyTheAgentsThatAreWorking() {
        let store = SessionStore()
        let now = Date()
        _ = aggregate(after: .working, in: store, now: now)
        // Two of the three sessions work; the third stays open and idle, which is
        // what makes the badge worth photographing — it counts work, not sessions.
        XCTAssertEqual(store.badgeCount, 2)
        XCTAssertEqual(store.ordered.count, 3)
    }

    /// The row the "waiting" screenshot is about must keep its own status line
    /// rather than being overwritten by the scripted activity of its neighbours.
    func testTheWaitingSessionKeepsItsOwnActivityLine() {
        let store = SessionStore()
        let now = Date()
        _ = aggregate(after: .waiting, in: store, now: now)
        let waiting = store.ordered.first { $0.id == DemoFeed.sessionIDs[0] }
        XCTAssertEqual(waiting?.status, .waitingForYou(.question))
        XCTAssertEqual(waiting?.activityDescription,
                       L10n.t("activity.waiting", "waiting for you"))
    }

    func testEveryDemoSessionNamesAProject() {
        let store = SessionStore()
        _ = aggregate(after: .working, in: store, now: Date())
        for session in store.ordered {
            XCTAssertFalse(session.projectName.isEmpty, session.id)
        }
    }

    /// The loop repeats, and a negative step must not trap on a negative modulo.
    func testPhaseLookupWrapsInBothDirections() {
        XCTAssertEqual(DemoFeed.phase(atStep: 0), .idle)
        XCTAssertEqual(DemoFeed.phase(atStep: 4), .idle)
        XCTAssertEqual(DemoFeed.phase(atStep: 6), .waiting)
        XCTAssertEqual(DemoFeed.phase(atStep: -1), .done)
    }

    /// `.problem` is kept out of the loop, but the mascot has a pose for it and a
    /// screenshot of that pose has to be possible. The pin reaches it through the
    /// store's own staleness rule — one silent session with no live process — so
    /// the picture shows the state the way it really arises: one session stopped,
    /// one still working, one idle.
    func testTheProblemPinReachesTheProblemState() {
        let store = SessionStore()
        DemoFeed.applyProblem(to: store, now: Date())
        XCTAssertEqual(AggregateStatusKey(store.aggregate), .problem)
        let byID = Dictionary(uniqueKeysWithValues: store.ordered.map { ($0.id, $0) })
        XCTAssertEqual(byID[DemoFeed.sessionIDs[0]]?.status, .working)
        XCTAssertEqual(byID[DemoFeed.sessionIDs[1]]?.status, .crashed)
        XCTAssertEqual(byID[DemoFeed.sessionIDs[2]]?.status, .idle)
        XCTAssertEqual(byID[DemoFeed.sessionIDs[0]]?.activityDescription,
                       L10n.f("activity.editing.file", "editing %@", "IslandLayout.swift"))
    }

    /// A demo whose rows have no task text would photograph the very state this line
    /// was added to fix — three rows that say nothing about what they are doing.
    func testWorkingDemoSessionsCarryATask() {
        let store = SessionStore()
        let now = Date()
        for event in DemoFeed.events(for: .working) { store.apply(hook: event, now: now) }
        for activity in DemoFeed.activities(for: .working, now: now) { store.apply(activity: activity) }
        let working = store.ordered.filter { $0.status == .working }
        XCTAssertFalse(working.isEmpty)
        for session in working {
            XCTAssertNotNil(session.taskText, "\(session.projectName) has nothing to show")
        }
    }

    /// The session that was never given a prompt has no task, and the demo has to
    /// show that state too — it is the row a new user sees first.
    func testTheUnpromptedDemoSessionHasNoTask() {
        let store = SessionStore()
        let now = Date()
        for event in DemoFeed.events(for: .working) { store.apply(hook: event, now: now) }
        XCTAssertNil(store.sessions[DemoFeed.sessionIDs[2]]?.taskText)
    }

    /// The demo's activity lines have to actually land. They did not: the app applies
    /// the phase's hooks and its activities with ONE `Date()`, and
    /// `SessionStore.apply(activity:)` drops an activity whose timestamp is not later
    /// than the session's last — so every demo row kept the hook's placeholder
    /// ("started on the task") and the README screenshots shipped showing it.
    func testDemoActivitiesLandOnTopOfTheirPhasesHooks() {
        let store = SessionStore()
        let now = Date()
        for event in DemoFeed.events(for: .working) { store.apply(hook: event, now: now) }
        for activity in DemoFeed.activities(for: .working, now: now) { store.apply(activity: activity) }
        XCTAssertEqual(store.sessions[DemoFeed.sessionIDs[0]]?.activityDescription,
                       L10n.f("activity.editing.file", "editing %@", "IslandLayout.swift"))
    }

    /// A finished session in the real world was asked for something first — the loop
    /// reaches `.done` through `.working`. Pinned straight to `.done` for a
    /// screenshot, it has to arrive in the same state, or the picture shows three
    /// rows that finished nothing in particular.
    func testAPinnedDonePhaseStillShowsWhatWasAsked() {
        assertPinnedPhaseKeepsTheTask(.done, expecting: .done)
    }

    /// The same for the state the product is really about: a session waiting on the
    /// user has to say both what it needs AND what it was asked for.
    func testAPinnedWaitingPhaseStillShowsWhatWasAsked() {
        assertPinnedPhaseKeepsTheTask(.waiting, expecting: .waitingForYou(.question))
    }

    private func assertPinnedPhaseKeepsTheTask(_ pinned: DemoFeed.Phase,
                                               expecting status: SessionStatus,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        let store = SessionStore()
        var now = Date()
        for phase in DemoFeed.leadIn(for: pinned) + [pinned] {
            for event in DemoFeed.events(for: phase) { store.apply(hook: event, now: now) }
            now = now.addingTimeInterval(60)
        }
        XCTAssertEqual(store.sessions[DemoFeed.sessionIDs[0]]?.status, status,
                       file: file, line: line)
        XCTAssertNotNil(store.sessions[DemoFeed.sessionIDs[0]]?.taskText,
                        "pinned \(pinned) has nothing to show", file: file, line: line)
    }

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
        XCTAssertEqual(h?.summary, "Done — tests are green, release 0.4.1 is built.")
        XCTAssertEqual(h?.links.map(\.title), ["localhost:4321", "PR #12", "Figma"])
    }

    // MARK: - Pins for captures (Part 2)

    func testASinglePinIsTheFirstSessionAloneInThatPhase() {
        let working = SessionStore()
        DemoFeed.apply(.single(.working), to: working, now: Date())
        XCTAssertEqual(working.ordered.map(\.id), [DemoFeed.sessionIDs[0]])
        XCTAssertEqual(working.ordered.first?.status, .working)
        XCTAssertEqual(working.ordered.first?.stepProgress?.done, 2)
        XCTAssertEqual(working.ordered.first?.stepProgress?.total, 5)

        let done = SessionStore()
        DemoFeed.apply(.single(.done), to: done, now: Date())
        XCTAssertEqual(done.ordered.map(\.status), [.done])

        let waiting = SessionStore()
        DemoFeed.apply(.single(.waiting), to: waiting, now: Date())
        XCTAssertEqual(waiting.ordered.map(\.status), [.waitingForYou(.question)])
    }

    func testTheManyPinPutsSixAgentsToWork() {
        let store = SessionStore()
        DemoFeed.apply(.many, to: store, now: Date())
        XCTAssertEqual(store.ordered.count, 6)
        XCTAssertEqual(store.aggregate, .working(6))
        XCTAssertTrue(store.ordered.allSatisfy { $0.taskText != nil })
    }

    /// Figma's "Full list": every card kind at once.
    func testTheShowcasePinHasEveryCardKind() {
        let store = SessionStore()
        DemoFeed.apply(.showcase, to: store, now: Date())
        XCTAssertEqual(store.ordered.map(\.status),
                       [.waitingForYou(.question), .working, .working, .done, .idle, .idle])
        XCTAssertEqual(store.ordered.map(\.projectName),
                       ["codecat", "orbit-api", "site", "studio-site", "notes-cli", "infra"])
        XCTAssertEqual(store.ordered[2].stepProgress?.done, 2)
        XCTAssertEqual(store.ordered[3].handoff?.links.count, 3)
    }

    func testTheEmptyPinLeavesNoSessions() {
        let store = SessionStore()
        DemoFeed.apply(.empty, to: store, now: Date())
        XCTAssertTrue(store.ordered.isEmpty)
    }

    func testAPinnedPhaseLandsWhereTheLoopWouldHave() {
        let store = SessionStore()
        DemoFeed.apply(.phase(.waiting), to: store, now: Date())
        XCTAssertEqual(store.aggregate, .waiting(1))
        XCTAssertEqual(store.sessions[DemoFeed.sessionIDs[0]]?.taskText, DemoFeed.tasks[0])
    }
}

