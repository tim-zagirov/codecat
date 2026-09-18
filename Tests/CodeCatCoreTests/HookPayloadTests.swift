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
        tty: "/dev/ttys001",
        agentPID: 777)

    func testEnrichmentAddsTheRouteFields() {
        let input = #"{"hook_event_name":"SessionStart","session_id":"abc"}"#.data(using: .utf8)!
        let result = object(HookPayload.enriched(input, with: fields))
        XCTAssertEqual(result["host_pid"] as? Int, 4242)
        XCTAssertEqual(result["host_bundle_path"] as? String, "/Applications/Claude.app")
        XCTAssertEqual(result["host_bundle_id"] as? String, "com.anthropic.claudefordesktop")
        XCTAssertEqual(result["host_tty"] as? String, "/dev/ttys001")
        XCTAssertEqual(result["agent_pid"] as? Int, 777)
    }

    /// Every field CodeCat adds is namespaced `host_*`: an un-namespaced `tty` key
    /// would collide with anything Claude Code might ship under that name, and a
    /// non-string value in the payload would break decoding of *every* event.
    func testTheTtyKeyIsNamespacedAndDoesNotTouchAPlainTtyField() {
        let input = #"{"session_id":"abc","tty":{"not":"a string"}}"#.data(using: .utf8)!
        let result = object(HookPayload.enriched(input, with: fields))
        XCTAssertEqual(result["host_tty"] as? String, "/dev/ttys001")
        XCTAssertNotNil(result["tty"] as? [String: Any])
    }

    /// A payload that already carries a foreign `tty` of a type `HookEvent` cannot
    /// decode must still decode as a `HookEvent` after enrichment.
    func testEnrichedPayloadWithAForeignTtyFieldStillDecodes() throws {
        let input = #"{"hook_event_name":"Stop","session_id":"abc","tty":17}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(HookEvent.self, from: HookPayload.enriched(input, with: fields))
        XCTAssertEqual(event.sessionId, "abc")
        XCTAssertEqual(event.tty, "/dev/ttys001")
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
        XCTAssertNil(result["host_tty"])
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

    // MARK: - The prompt, and the datagram it has to fit in

    /// Measured, not assumed: `net.local.dgram.maxdgram` on macOS is 2 048 bytes, and
    /// `sendto` fails outright above it — the event is not truncated, it is lost. A
    /// `UserPromptSubmit` payload carries the whole prompt, so before this trim every
    /// prompt longer than ~1.4 KB meant CodeCat never learned the session had started
    /// working. Confirmed in the field: across 1 760 delivered hook events not one
    /// exceeded 2 045 B, and no delivered `UserPromptSubmit` ever matched a prompt
    /// longer than 1 500 characters.
    func testALongPromptIsTrimmedSoTheDatagramFits() {
        let prompt = String(repeating: "почини пагинацию ", count: 400)
        let input = try! JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit", "session_id": "abc",
            "cwd": "/Users/x/proj", "prompt": prompt,
        ])
        XCTAssertGreaterThan(input.count, 2048, "the untrimmed payload is over the limit")
        let result = HookPayload.enriched(input, with: fields)
        XCTAssertLessThan(result.count, 2048, "a payload that fits is a payload that arrives")
        let trimmed = object(result)["prompt"] as? String
        XCTAssertNotNil(trimmed, "trimmed, never dropped — the row still has something to show")
        XCTAssertLessThanOrEqual(trimmed?.count ?? .max, TaskText.maxLength)
    }

    /// A prompt that is already short reaches the app exactly as it was typed.
    func testAShortPromptIsPassedThroughUnchanged() {
        let input = #"{"hook_event_name":"UserPromptSubmit","session_id":"abc","prompt":"собери релиз"}"#
            .data(using: .utf8)!
        XCTAssertEqual(object(HookPayload.enriched(input, with: fields))["prompt"] as? String,
                       "собери релиз")
    }

    /// Nothing else has a prompt, and nothing else grows a key that was not there.
    func testAPayloadWithNoPromptGrowsNoPromptKey() {
        let input = #"{"hook_event_name":"Stop","session_id":"abc"}"#.data(using: .utf8)!
        XCTAssertNil(object(HookPayload.enriched(input, with: fields))["prompt"])
    }
}

