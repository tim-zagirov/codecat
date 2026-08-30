import XCTest
@testable import CodeCatCore

final class HookPayloadTests: XCTestCase {

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private let fields = HookPayload.RouteFields(
        hostPID: 4242,
        hostBundlePath: "/Applications/Claude.app",
        hostBundleID: "com.anthropic.claudefordesktop",
        tty: "/dev/ttys001")

    func testEnrichmentAddsTheRouteFields() {
        let input = #"{"hook_event_name":"SessionStart","session_id":"abc"}"#.data(using: .utf8)!
        let result = object(HookPayload.enriched(input, with: fields))
        XCTAssertEqual(result["host_pid"] as? Int, 4242)
        XCTAssertEqual(result["host_bundle_path"] as? String, "/Applications/Claude.app")
        XCTAssertEqual(result["host_bundle_id"] as? String, "com.anthropic.claudefordesktop")
        XCTAssertEqual(result["tty"] as? String, "/dev/ttys001")
    }

    func testEnrichmentKeepsEveryOriginalField() {
        let input = #"{"hook_event_name":"Notification","session_id":"abc","cwd":"/tmp/p","message":"needs permission"}"#
            .data(using: .utf8)!
        let result = object(HookPayload.enriched(input, with: fields))
        XCTAssertEqual(result["hook_event_name"] as? String, "Notification")
        XCTAssertEqual(result["session_id"] as? String, "abc")
        XCTAssertEqual(result["cwd"] as? String, "/tmp/p")
        XCTAssertEqual(result["message"] as? String, "needs permission")
    }

    func testAbsentFieldsAreOmittedRatherThanWrittenAsNull() {
        let input = #"{"session_id":"abc"}"#.data(using: .utf8)!
        let empty = HookPayload.RouteFields(hostPID: nil, hostBundlePath: nil, hostBundleID: nil, tty: nil)
        let result = object(HookPayload.enriched(input, with: empty))
        XCTAssertNil(result["host_pid"])
        XCTAssertNil(result["tty"])
        XCTAssertEqual(result["session_id"] as? String, "abc")
    }

    /// Enrichment must never be a reason an event is lost: anything that does not
    /// parse as a JSON object is forwarded byte for byte, exactly as before.
    func testMalformedJsonIsForwardedUnchanged() {
        let input = Data("{not json".utf8)
        XCTAssertEqual(HookPayload.enriched(input, with: fields), input)
    }

    func testJsonThatIsNotAnObjectIsForwardedUnchanged() {
        let input = Data("[1,2,3]".utf8)
        XCTAssertEqual(HookPayload.enriched(input, with: fields), input)
    }

    func testEmptyInputIsForwardedUnchanged() {
        XCTAssertEqual(HookPayload.enriched(Data(), with: fields), Data())
    }

    /// The enriched payload must still decode as the event the app consumes.
    func testEnrichedPayloadStillDecodesAsAHookEvent() throws {
        let input = #"{"hook_event_name":"SessionStart","session_id":"abc","cwd":"/tmp/p"}"#.data(using: .utf8)!
        let enriched = HookPayload.enriched(input, with: fields)
        let event = try JSONDecoder().decode(HookEvent.self, from: enriched)
        XCTAssertEqual(event.sessionId, "abc")
        XCTAssertEqual(event.hookEventName, "SessionStart")
    }
}
