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
        XCTAssertEqual(a?.description, "редактирует api.ts")
        XCTAssertEqual(a?.sessionId, "s1")
        XCTAssertEqual(a?.projectPath, "/Users/x/proj")
    }

    func testBashToolProducesCommandDescription() {
        let l = line("assistant", content:
            #"{"type":"tool_use","name":"Bash","input":{"command":"ls"}}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "выполняет команду")
    }

    func testReadToolProducesReadDescription() {
        let l = line("assistant", content:
            #"{"type":"tool_use","name":"Read","input":{"file_path":"/a/b/config.json"}}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "читает config.json")
    }

    func testSearchToolsProduceSearchDescription() {
        let l = line("assistant", content:
            #"{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "ищет по коду")
    }

    func testUnknownToolProducesGenericToolDescription() {
        let l = line("assistant", content:
            #"{"type":"tool_use","name":"WebSearch","input":{}}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "использует WebSearch")
    }

    func testTextOnlyAssistantMessageMeansThinking() {
        let l = line("assistant", content: #"{"type":"text","text":"hello"}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "думает")
    }

    func testUserMessageMeansGotTask() {
        let l = line("user", content: #"{"type":"text","text":"do it"}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.description, "работает над задачей")
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
        // без sessionId — тоже nil
        XCTAssertNil(TranscriptParser.parseLine(
            #"{"type":"assistant","timestamp":"2026-08-28T10:00:00.123Z"}"#))
    }

    // Реальная строка субагента, взятая из архива этой же машины:
    // ~/.claude/projects/-Users-dev-Projects-example--claude-worktrees-example-branch/
    //   bbbbbbbb-cccc-dddd-eeee-ffffffffffff/subagents/agent-a1b2c3d4e5f60718.jsonl
    // sessionId в ней — это UUID родительской сессии, а не отдельная сессия субагента.
    func testRealSubagentLineParsesAsSubagentWithParentSessionId() {
        let l = """
        {"parentUuid":"11111111-2222-3333-4444-555555555555","isSidechain":true,"agentId":"a1b2c3d4e5f60718","message":{"model":"claude-sonnet-5","id":"msg_01ExampleExampleExample","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01ExampleExampleExampl","name":"Bash","input":{"command":"cd /Users/dev/Projects/example/.claude/worktrees/example-branch\\nswift build 2>&1 | tail -80"},"caller":{"type":"direct"}}],"stop_reason":null,"stop_sequence":null,"stop_details":null,"usage":{"input_tokens":2,"cache_creation_input_tokens":465,"cache_read_input_tokens":91762,"cache_creation":{"ephemeral_5m_input_tokens":465,"ephemeral_1h_input_tokens":0},"output_tokens":3,"service_tier":"standard","inference_geo":"not_available"},"diagnostics":null},"requestId":"req_01ExampleExampleExample","attributionAgent":"general-purpose","type":"assistant","uuid":"66666666-7777-8888-9999-aaaaaaaaaaaa","timestamp":"2026-08-30T20:50:24.858Z","effort":"high","userType":"external","entrypoint":"claude-desktop","cwd":"/Users/dev/Projects/example/.claude/worktrees/example-branch","sessionId":"bbbbbbbb-cccc-dddd-eeee-ffffffffffff","version":"2.1.0","gitBranch":"claude/example-branch"}
        """
        let a = TranscriptParser.parseLine(l)
        XCTAssertEqual(a?.isSubagent, true)
        XCTAssertEqual(a?.sessionId, "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")
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
}
