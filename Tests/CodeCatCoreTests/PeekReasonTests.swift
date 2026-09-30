import XCTest
@testable import CodeCatCore

final class PeekReasonTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)

    func session(_ status: SessionStatus, action: PendingAction.Kind? = nil,
                 message: String? = nil, summary: String? = nil) -> Session {
        var s = Session(id: "s1", projectPath: "/p/codecat", status: status,
                        activityDescription: "", startedAt: t0, lastActivity: t0)
        s.pendingActions = action.map { [PendingEntry(id: "toolu_a", action: PendingAction(tool: "Bash", kind: $0))] } ?? []
        s.waitMessage = message
        s.handoff = summary.map { Handoff(summary: $0, links: []) }
        return s
    }

    func testPermissionForACommand() {
        XCTAssertEqual(PeekReason.segments(for: session(.waitingForYou(.permission), action: .run(command: "npm test"))),
                       [.text("wants to run"), .code("npm test")])
    }

    func testPermissionForAFileAHostAndATool() {
        XCTAssertEqual(PeekReason.segments(for: session(.waitingForYou(.permission), action: .edit(file: "api.ts"))),
                       [.text("wants to edit"), .code("api.ts")])
        XCTAssertEqual(PeekReason.segments(for: session(.waitingForYou(.permission), action: .open(host: "docs.swift.org"))),
                       [.text("wants to open"), .code("docs.swift.org")])
        XCTAssertEqual(PeekReason.segments(for: session(.waitingForYou(.permission), action: .use(tool: "Grep"))),
                       [.text("wants to use"), .code("Grep")])
    }

    /// The hook beat the transcript: its own sentence, first sentence only.
    func testPermissionBeforeTheTranscriptSaysAnythingUsesTheHookMessage() {
        let s = session(.waitingForYou(.permission),
                        message: "Claude needs your permission to use Bash. Approve it in the terminal.")
        XCTAssertEqual(PeekReason.segments(for: s), [.text("Claude needs your permission to use Bash")])
    }

    func testNoActionAndNoMessageFallsBackToTheStatus() {
        XCTAssertEqual(PeekReason.segments(for: session(.waitingForYou(.permission))), [.text("waiting for you")])
    }

    func testQuestionAndGuess() {
        XCTAssertEqual(PeekReason.segments(for: session(.waitingForYou(.question))), [.text("has a question for you")])
        XCTAssertEqual(PeekReason.segments(for: session(.waitingForYou(.idle))), [.text("looks like it is waiting for you")])
    }

    func testCrashedAndDone() {
        XCTAssertEqual(PeekReason.segments(for: session(.crashed)), [.text("the session ended unexpectedly")])
        XCTAssertEqual(PeekReason.segments(for: session(.done, summary: "tests are green")), [.text("tests are green")])
        XCTAssertEqual(PeekReason.segments(for: session(.done)), [.text("finished the task")])
    }
}
