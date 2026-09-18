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
