import XCTest
@testable import CodeCatCore

final class TranscriptParserTests: XCTestCase {
    func line(_ type: String, content: String) -> String {
        """
        {"type":"\(type)","sessionId":"s1","cwd":"/Users/x/proj",\
        "timestamp":"2026-08-28T10:00:00.123Z","message":{"content":[\(content)]}}
        """
    }

    func testEditToolProducesEditDescription() {
        let l = line("assistant", content:
            #"{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/x/proj/src/api.ts"}}"#)
        let a = TranscriptParser.parseLine(l)
        XCTAssertEqual(a?.description, "editing api.ts")
        XCTAssertEqual(a?.sessionId, "s1")
        XCTAssertEqual(a?.projectPath, "/Users/x/proj")
    }

    func testBashToolProducesCommandDescription() {
        let l = line("assistant", content:
            #"{"type":"tool_use","name":"Bash","input":{"command":"ls"}}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "running a command")
    }

    func testReadToolProducesReadDescription() {
        let l = line("assistant", content:
            #"{"type":"tool_use","name":"Read","input":{"file_path":"/a/b/config.json"}}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "reading config.json")
    }

    func testSearchToolsProduceSearchDescription() {
        let l = line("assistant", content:
            #"{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "searching the code")
    }

    func testUnknownToolProducesGenericToolDescription() {
        let l = line("assistant", content:
            #"{"type":"tool_use","name":"WebSearch","input":{}}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "using WebSearch")
    }

    func testTextOnlyAssistantMessageMeansThinking() {
        let l = line("assistant", content: #"{"type":"text","text":"hello"}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "thinking")
    }

    func testUserMessageMeansGotTask() {
        let l = line("user", content: #"{"type":"text","text":"do it"}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "working on the task")
    }

    func testTimestampParsed() {
        let l = line("assistant", content: #"{"type":"text","text":"x"}"#)
        let a = TranscriptParser.parseLine(l)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(a?.timestamp, f.date(from: "2026-08-28T10:00:00.123Z"))
    }

    func testGarbageAndUnknownTypesReturnNil() {
        XCTAssertNil(TranscriptParser.parseLine("not json at all"))
        XCTAssertNil(TranscriptParser.parseLine(#"{"type":"summary","summary":"x"}"#))
        XCTAssertNil(TranscriptParser.parseLine(""))
        // no sessionId — nil as well
        XCTAssertNil(TranscriptParser.parseLine(
            #"{"type":"assistant","timestamp":"2026-08-28T10:00:00.123Z"}"#))
    }

    // A real subagent line, taken from this machine's own archive. Its sessionId is
    // the UUID of the PARENT session, not a session of the subagent's own.
    func testRealSubagentLineParsesAsSubagentWithParentSessionId() {
        let l = """
        {"parentUuid":"5f076459-26e1-4797-8fce-44631197ee44","isSidechain":true,"agentId":"a07414a563049c3f9","message":{"model":"claude-sonnet-5","id":"msg_011CeZbM5syeCksdghiXNpSU","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01X2GfzCULGks4E6AbFPAvSv","name":"Bash","input":{"command":"cd /Users/timzagirov/Projects/vibe-coding-utility/.claude/worktrees/codecat-mascot-skins-spec-b6a4de\\nswift build 2>&1 | tail -80"},"caller":{"type":"direct"}}],"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":465,"cache_read_input_tokens":91762,"cache_creation":{"ephemeral_5m_input_tokens":465,"ephemeral_1h_input_tokens":0},"output_tokens":3,"service_tier":"standard","inference_geo":"not_available"},"diagnostics":null},"requestId":"req_011CeZbM5861NqheXad4BYwg","attributionAgent":"general-purpose","type":"assistant","uuid":"154ceedc-addd-4502-a538-b568c47d7ffd","timestamp":"2026-08-30T20:50:24.858Z","effort":"high","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/timzagirov/Projects/vibe-coding-utility/.claude/worktrees/codecat-mascot-skins-spec-b6a4de","sessionId":"4a0d5329-c0ff-4f35-afb2-0a1ffa28f7c1","version":"2.1.247","gitBranch":"claude/codecat-mascot-skins-spec-b6a4de"}
        """
        let a = TranscriptParser.parseLine(l)
        XCTAssertEqual(a?.isSubagent, true)
        XCTAssertEqual(a?.sessionId, "4a0d5329-c0ff-4f35-afb2-0a1ffa28f7c1")
    }

    func testOrdinaryAssistantLineIsNotASubagent() {
        let l = line("assistant", content: #"{"type":"text","text":"hello"}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.isSubagent, false)
    }

    func testOrdinaryUserLineIsNotASubagent() {
        let l = line("user", content: #"{"type":"text","text":"do it"}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.isSubagent, false)
    }

    func testEmptyAgentIdIsNotTreatedAsSubagent() {
        let l = """
        {"type":"assistant","agentId":"","sessionId":"s1",\
        "cwd":"/Users/x/proj","timestamp":"2026-08-28T10:00:00.123Z",\
        "message":{"content":[{"type":"text","text":"hello"}]}}
        """
        XCTAssertEqual(TranscriptParser.parseLine(l)?.isSubagent, false)
    }

    // MARK: - End of turn

    private func assistant(stopReason: String?, tool: String? = nil, agentId: String? = nil) -> String {
        var message: [String: Any] = ["content": tool.map { [["type": "tool_use", "name": $0, "input": [:]]] } ?? []]
        if let stopReason { message["stop_reason"] = stopReason }
        var obj: [String: Any] = [
            "type": "assistant", "sessionId": "s1", "cwd": "/proj",
            "timestamp": "2026-09-01T00:00:00.000Z", "message": message,
        ]
        if let agentId { obj["agentId"] = agentId }
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    /// `stop_reason == "end_turn"` — the model handed control back to the human. The
    /// only sign of work ending that lives in the transcript itself; the `Stop` hook
    /// cannot be relied on, it does not always arrive.
    func testAssistantEndTurnIsRecognisedAsTheEndOfWork() {
        let activity = TranscriptParser.parseLine(assistant(stopReason: "end_turn"))
        XCTAssertEqual(activity?.endsTurn, true)
        XCTAssertEqual(activity?.description, "finished the task")
    }

    /// Its opposite: a tool call. A real session has twenty times more of those, so
    /// confusing them with the end of a turn is out of the question.
    func testAssistantToolUseIsNotTheEndOfWork() {
        let activity = TranscriptParser.parseLine(assistant(stopReason: "tool_use", tool: "Bash"))
        XCTAssertEqual(activity?.endsTurn, false)
        XCTAssertEqual(activity?.description, "running a command")
    }

    /// An entry with no `stop_reason` (an older format, an intermediate chunk) is not
    /// an ending: silence is not an assertion.
    func testAssistantWithoutAStopReasonIsNotTheEndOfWork() {
        XCTAssertEqual(TranscriptParser.parseLine(assistant(stopReason: nil, tool: "Read"))?.endsTurn, false)
    }

    /// User entries (including tool results) never have a `stop_reason` — and
    /// certainly never end a turn.
    func testUserRecordNeverEndsTheTurn() {
        let line = #"{"type":"user","sessionId":"s1","cwd":"/proj","timestamp":"2026-09-01T00:00:00.000Z"}"#
        XCTAssertEqual(TranscriptParser.parseLine(line)?.endsTurn, false)
    }

    /// A subagent's end of turn is still the end of *that entry's* turn; telling it
    /// apart from the session's work ending is the store's job (see
    /// `SessionStoreTests`), but the subagent marker has to survive.
    func testSubagentEndTurnKeepsTheSubagentMarker() {
        let activity = TranscriptParser.parseLine(assistant(stopReason: "end_turn", agentId: "a1"))
        XCTAssertEqual(activity?.endsTurn, true)
        XCTAssertEqual(activity?.isSubagent, true)
    }
}
