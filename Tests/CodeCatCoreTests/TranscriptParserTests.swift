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
    // ~/.claude/projects/-Users-timzagirov-Projects-vibe-coding-utility--claude-worktrees-codecat-mascot-skins-spec-b6a4de/
    //   4a0d5329-c0ff-4f35-afb2-0a1ffa28f7c1/subagents/agent-a07414a563049c3f9.jsonl
    // sessionId в ней — это UUID родительской сессии, а не отдельная сессия субагента.
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
}
