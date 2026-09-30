import XCTest
@testable import CodeCatCore

final class PeekContentTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_756_400_000)

    func session(_ id: String, _ project: String, _ status: SessionStatus,
                 action: PendingAction.Kind? = nil, handoff: Handoff? = nil) -> Session {
        var s = Session(id: id, projectPath: "/p/\(project)", status: status,
                        activityDescription: "", startedAt: t0, lastActivity: t0)
        s.pendingActions = action.map { [PendingEntry(id: "toolu_a", action: PendingAction(tool: "Bash", kind: $0))] } ?? []
        s.handoff = handoff
        return s
    }

    func item(_ kind: PeekItem.Kind, _ ids: [String]) -> PeekItem {
        PeekItem(kind: kind, sessionIDs: ids, createdAt: t0)
    }

    let localhost = HandoffLink(kind: .localhost, title: "localhost:4321", target: URL(string: "http://localhost:4321")!)

    func testAWaitSaysWhoAndWhatAndOffersTheColouredOpen() {
        let s = session("s1", "codecat", .waitingForYou(.permission), action: .run(command: "npm test"))
        let content = PeekContent.make(for: item(.waiting, ["s1"]), sessions: [s], showsTaskText: true)
        XCTAssertEqual(content, PeekContent(title: "codecat", segments: [.text("wants to run"), .code("npm test")],
                                            pill: .open(prominent: true), sessionID: "s1", tone: .waiting))
    }

    /// With "Show what each session is doing" off the command stays private too.
    func testAWaitWithTheTaskSwitchOffSaysOnlyThatItWaits() {
        let s = session("s1", "codecat", .waitingForYou(.permission), action: .run(command: "npm test"))
        XCTAssertEqual(PeekContent.make(for: item(.waiting, ["s1"]), sessions: [s], showsTaskText: false)?.segments,
                       [.text("waiting for you")])
    }

    func testACrashOffersAPlainOpen() {
        let s = session("s1", "orbit-api", .crashed)
        XCTAssertEqual(PeekContent.make(for: item(.crashed, ["s1"]), sessions: [s], showsTaskText: true),
                       PeekContent(title: "orbit-api", segments: [.text("the session ended unexpectedly")],
                                   pill: .open(prominent: false), sessionID: "s1", tone: .problem))
    }

    /// Spec §6.2: a done peek's pill is the turn's first chip.
    func testADoneTurnShowsItsSummaryAndFirstChip() {
        let s = session("s1", "site", .done,
                        handoff: Handoff(summary: "tests are green, 0.4.1 is built", links: [localhost]))
        XCTAssertEqual(PeekContent.make(for: item(.done, ["s1"]), sessions: [s], showsTaskText: true),
                       PeekContent(title: "site", segments: [.text("tests are green, 0.4.1 is built")],
                                   pill: .chip(localhost), sessionID: "s1", tone: .done))
    }

    func testADoneTurnWithTheTaskSwitchOffShowsNeitherSummaryNorChip() {
        let s = session("s1", "site", .done,
                        handoff: Handoff(summary: "tests are green, 0.4.1 is built", links: [localhost]))
        let content = PeekContent.make(for: item(.done, ["s1"]), sessions: [s], showsTaskText: false)
        XCTAssertEqual(content?.segments, [.text("finished the task")])
        XCTAssertEqual(content?.pill, .absent)
    }

    func testAMergedPeekNamesTheProjectsAndOffersShow() {
        let sessions = [session("s1", "codecat", .waitingForYou(.question)), session("s2", "site", .crashed)]
        XCTAssertEqual(PeekContent.make(for: item(.merged, ["s1", "s2"]), sessions: sessions, showsTaskText: true),
                       PeekContent(title: "2 agents need you", segments: [.text("codecat · site")],
                                   pill: .show, sessionID: nil, tone: .waiting))
    }

    /// Figma 03: "2 done · 1 waiting"; a kind with nothing to count is left out.
    func testTheAwaySummaryCountsWhatHappened() {
        let away = PeekContent.make(for: item(.away(done: 2, waiting: 1, crashed: 0), []), sessions: [], showsTaskText: true)
        XCTAssertEqual(away, PeekContent(title: "While you were away", segments: [.text("2 done · 1 waiting")],
                                         pill: .show, sessionID: nil, tone: .waiting))
        let quiet = PeekContent.make(for: item(.away(done: 1, waiting: 0, crashed: 0), []), sessions: [], showsTaskText: true)
        XCTAssertEqual(quiet?.segments, [.text("1 done")])
        XCTAssertEqual(quiet?.tone, .done)
    }

    func testAPeekAboutASessionThatIsGoneSaysNothing() {
        XCTAssertNil(PeekContent.make(for: item(.waiting, ["gone"]), sessions: [], showsTaskText: true))
    }
}
