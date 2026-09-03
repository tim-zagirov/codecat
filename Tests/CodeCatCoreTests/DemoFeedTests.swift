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
}
