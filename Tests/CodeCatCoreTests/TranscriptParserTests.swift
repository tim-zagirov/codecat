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
}
