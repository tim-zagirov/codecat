import XCTest
@testable import CodeCatCore

/// The executor itself lives in the app target and has no tests, so the decisions it
/// makes around the Apple event — what TCC's answer means, how long to wait, and when
/// a wedged script must refuse a new jump — live here instead, where they can be
/// checked on fixed values.
final class JumpExecutionPolicyTests: XCTestCase {

    // MARK: - Reading TCC's answer

    func testNoErrorMeansPermissionIsAlreadyGranted() {
        XCTAssertEqual(JumpExecutionPolicy.permission(forStatus: 0), .granted)
    }

    /// -1743 `errAEEventNotPermitted`: the user said no.
    func testEventNotPermittedMeansDenied() {
        XCTAssertEqual(JumpExecutionPolicy.permission(forStatus: -1743), .denied)
    }

    /// -1742 `errAETargetAddressNotPermitted` is the same answer wearing a different
    /// hat — the send is refused for permission reasons, so the user needs the same
    /// actionable message, not a raw AppleScript error.
    func testTargetAddressNotPermittedIsAlsoDenied() {
        XCTAssertEqual(JumpExecutionPolicy.permission(forStatus: -1742), .denied)
    }

    /// -1744 `errAEEventWouldRequireUserConsent`: nothing has been decided yet, so
    /// sending puts up the system consent panel and blocks on a human.
    func testWouldRequireConsentMeansAwaitingConsent() {
        XCTAssertEqual(JumpExecutionPolicy.permission(forStatus: -1744), .awaitingConsent)
    }

    func testProcessNotFoundMeansTheHostIsGone() {
        XCTAssertEqual(JumpExecutionPolicy.permission(forStatus: -600), .hostGone)
    }

    /// An unrecognised status must not be optimistically read as "granted": that would
    /// put the short deadline on a send that may still be waiting for a human.
    func testAnUnknownStatusIsTreatedAsAwaitingConsent() {
        XCTAssertEqual(JumpExecutionPolicy.permission(forStatus: -12345), .awaitingConsent)
    }

    // MARK: - How long to wait

    /// The short deadline exists to catch a wedged terminal. It must never be the one
    /// running against a human reading the consent panel — that fired mid-dialog and
    /// reported the terminal had not answered moments before the jump succeeded.
    func testConsentGetsAMuchLongerDeadlineThanAWedgedTerminal() {
        let consent = JumpExecutionPolicy.timeout(for: .awaitingConsent)
        let granted = JumpExecutionPolicy.timeout(for: .granted)
        XCTAssertGreaterThan(consent, granted * 5)
        XCTAssertGreaterThanOrEqual(granted, 5)
        XCTAssertGreaterThanOrEqual(consent, 60)
    }

    // MARK: - Refusing a jump behind a wedged script

    func testNothingOutstandingIsNeverBlocked() {
        XCTAssertFalse(JumpExecutionPolicy.isBlocked(outstanding: 0, deadlinePassed: true))
    }

    /// A script that is merely still running gets to finish: the new jump queues
    /// behind it and runs in a moment, which is not something to warn about.
    func testAHealthyOutstandingScriptDoesNotBlock() {
        XCTAssertFalse(JumpExecutionPolicy.isBlocked(outstanding: 1, deadlinePassed: false))
    }

    /// Past its deadline the script is wedged and owns the serial queue, so a new jump
    /// would queue invisibly — which is the silent refusal the spec forbids.
    func testAnOverdueOutstandingScriptBlocks() {
        XCTAssertTrue(JumpExecutionPolicy.isBlocked(outstanding: 1, deadlinePassed: true))
        XCTAssertTrue(JumpExecutionPolicy.isBlocked(outstanding: 3, deadlinePassed: true))
    }

    // MARK: - What a timeout means

    /// A deadline that expires while the consent panel is still up must not claim the
    /// terminal failed to answer: it was never asked. The two cases are different
    /// events and get different words.
    func testTimeoutDetailDistinguishesAWedgedTerminalFromAPendingConsentPanel() {
        let wedged = JumpMessages.timedOutDetail(awaitingConsent: false)
        let consent = JumpMessages.timedOutDetail(awaitingConsent: true)
        XCTAssertNotEqual(wedged, consent)
        XCTAssertTrue(wedged.localizedCaseInsensitiveContains("терминал"))
        XCTAssertTrue(consent.localizedCaseInsensitiveContains("разрешени"))
        XCTAssertFalse(consent.localizedCaseInsensitiveContains("терминал не ответил"))
    }
}
