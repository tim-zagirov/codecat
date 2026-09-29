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

    // A subagent line in the shape Claude Code really writes, with every identifier
    // and path replaced by a synthetic one. What matters is the shape: its sessionId
    // is the UUID of the PARENT session, not a session of the subagent's own.
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


    // MARK: the task the user set

    /// The shape a real typed prompt has in the transcript: `type: "user"` whose
    /// `message.content` is a plain STRING (a tool result is an array instead), with
    /// `origin.kind == "human"`. Verified against live transcripts in
    /// `~/.claude/projects` before this test was written.
    func humanPrompt(_ text: String, extra: String = "") -> String {
        """
        {"type":"user","sessionId":"s1","cwd":"/Users/x/proj",\
        "timestamp":"2026-08-28T10:00:00.123Z","origin":{"kind":"human"},\
        "userType":"external"\(extra),"message":{"role":"user","content":"\(text)"}}
        """
    }

    func testAHumanPromptCarriesTheTask() {
        let a = TranscriptParser.parseLine(humanPrompt("почини пагинацию в ленте"))
        XCTAssertEqual(a?.taskText, "почини пагинацию в ленте")
    }

    /// Tool results travel as `type: "user"` too, with an ARRAY for content. They are
    /// the agent talking to itself; nobody asked for anything.
    func testAToolResultCarriesNoTask() {
        let l = line("user", content: #"{"type":"tool_result","tool_use_id":"t1","content":"ok"}"#)
        XCTAssertNil(TranscriptParser.parseLine(l)?.taskText)
    }

    /// `isMeta` marks entries Claude Code wrote into the conversation itself —
    /// caveats, image placeholders, injected context. Not a task.
    func testAMetaEntryCarriesNoTask() {
        let l = humanPrompt("Caveat: The messages below were generated by the user",
                            extra: #","isMeta":true"#)
        XCTAssertNil(TranscriptParser.parseLine(l)?.taskText)
    }

    /// A background task reporting back is not the user asking for something. Its
    /// `origin.kind` says so: "task-notification", not "human".
    func testATaskNotificationCarriesNoTask() {
        let l = """
        {"type":"user","sessionId":"s1","cwd":"/Users/x/proj",\
        "timestamp":"2026-08-28T10:00:00.123Z","origin":{"kind":"task-notification"},\
        "message":{"role":"user","content":"<task-notification>agent finished</task-notification>"}}
        """
        XCTAssertNil(TranscriptParser.parseLine(l)?.taskText)
    }

    /// A subagent gets its own instructions, and they are not what the user asked
    /// this session for — its entries carry the parent's `sessionId`, so without this
    /// the parent's row would start describing the subagent's errand.
    func testASubagentPromptCarriesNoTask() {
        let l = humanPrompt("ты выступаешь как дизайнер, оцени строку",
                            extra: #","isSidechain":true"#)
        XCTAssertNil(TranscriptParser.parseLine(l)?.taskText)
    }

    /// An assistant entry is the agent working, never the task being set.
    func testAnAssistantLineCarriesNoTask() {
        let l = line("assistant", content: #"{"type":"text","text":"hello"}"#)
        XCTAssertNil(TranscriptParser.parseLine(l)?.taskText)
    }

    /// A transcript written by a Claude Code old enough not to record `origin` at
    /// all: the entry still looks exactly like a typed prompt, so it is taken as one.
    /// The machine-written shapes it cannot rule out this way are ruled out by
    /// `TaskText.sanitized` instead.
    func testAPromptWithoutAnOriginFieldIsStillATask() {
        let l = """
        {"type":"user","sessionId":"s1","cwd":"/Users/x/proj",\
        "timestamp":"2026-08-28T10:00:00.123Z",\
        "message":{"role":"user","content":"собери релиз"}}
        """
        XCTAssertEqual(TranscriptParser.parseLine(l)?.taskText, "собери релиз")
    }

    // MARK: - Task list

    func testTodoWriteReplacesTheWholeList() {
        let l = line("assistant", content: #"""
            {"type":"tool_use","name":"TodoWrite","input":{"todos":[
              {"content":"Read the parser","activeForm":"Reading the parser","status":"completed"},
              {"content":"Write the test","activeForm":"Writing the test","status":"in_progress"},
              {"content":"Ship it","activeForm":"Shipping it","status":"pending"}]}}
            """#)
        let updates = TranscriptParser.parseLine(l)?.stepsUpdates
        XCTAssertEqual(updates, [.replaceAll([
            TaskStep(id: "0", title: "Read the parser", activeForm: "Reading the parser", status: .completed),
            TaskStep(id: "1", title: "Write the test", activeForm: "Writing the test", status: .inProgress),
            TaskStep(id: "2", title: "Ship it", activeForm: "Shipping it", status: .pending),
        ])])
    }

    func testTaskCreateIsReadFromItsResultLine() {
        let l = line("user", content:
            #"{"type":"tool_result","tool_use_id":"toolu_1","content":"Task #3 created successfully: Propose 2-3 approaches"}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.stepsUpdates,
                       [.create(id: "3", title: "Propose 2-3 approaches")])
    }

    func testTaskCreateResultAsTextBlocksIsReadToo() {
        let l = line("user", content:
            #"{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"Task #4 created successfully: Write docs"}]}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.stepsUpdates, [.create(id: "4", title: "Write docs")])
    }

    func testTaskUpdateStatusesAndDeletion() {
        XCTAssertEqual(TranscriptParser.parseLine(line("assistant", content:
            #"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"completed"}}"#))?.stepsUpdates,
            [.update(id: "2", status: .completed)])
        XCTAssertEqual(TranscriptParser.parseLine(line("assistant", content:
            #"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"in_progress"}}"#))?.stepsUpdates,
            [.update(id: "2", status: .inProgress)])
        XCTAssertEqual(TranscriptParser.parseLine(line("assistant", content:
            #"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"deleted"}}"#))?.stepsUpdates,
            [.remove(id: "2")])
        XCTAssertEqual(TranscriptParser.parseLine(line("assistant", content:
            #"{"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"blocked"}}"#))?.stepsUpdates,
            [])
    }

    func testOneLineWithTwoToolBlocksYieldsTwoUpdatesInOrder() {
        let l = line("assistant", content: #"""
            {"type":"tool_use","name":"TaskUpdate","input":{"taskId":"1","status":"completed"}},
            {"type":"tool_use","name":"TaskUpdate","input":{"taskId":"2","status":"in_progress"}}
            """#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.stepsUpdates,
                       [.update(id: "1", status: .completed), .update(id: "2", status: .inProgress)])
    }

    func testASubagentsTodoListDoesNotTouchTheParent() {
        let l = """
        {"type":"assistant","sessionId":"s1","cwd":"/p","agentId":"a1",\
        "timestamp":"2026-08-28T10:00:00.123Z","message":{"content":[\
        {"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"x","status":"pending"}]}}]}}
        """
        XCTAssertEqual(TranscriptParser.parseLine(l)?.stepsUpdates, [])
    }

    func testAnOrdinaryToolLineCarriesNoUpdates() {
        let l = line("assistant", content: #"{"type":"tool_use","name":"Bash","input":{"command":"ls"}}"#)
        XCTAssertEqual(TranscriptParser.parseLine(l)?.stepsUpdates, [])
    }

    // MARK: - Final text

    func testTheTurnEndingLineCarriesItsText() {
        let l = """
        {"type":"assistant","sessionId":"s1","cwd":"/p","timestamp":"2026-09-01T00:00:00.000Z",\
        "message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done."},\
        {"type":"text","text":"See http://localhost:4321"}]}}
        """
        let a = TranscriptParser.parseLine(l)
        XCTAssertEqual(a?.endsTurn, true)
        XCTAssertEqual(a?.finalText, "Done.\nSee http://localhost:4321")
    }

    func testALineThatDoesNotEndTheTurnHasNoFinalText() {
        XCTAssertNil(TranscriptParser.parseLine(assistant(stopReason: "tool_use", tool: "Bash"))?.finalText)
    }

    /// A sidechain's own "end_turn" ends the errand a subagent was sent on, not the
    /// session's turn. Unlike the `agentId` subagent marker, a sidechain entry can
    /// carry no `agentId` at all, so this is the one place `isSidechain` alone has to
    /// gate `finalText` — without it, a subagent's sign-off text would surface as the
    /// parent session's handoff summary.
    func testASidechainEndTurnCarriesNoFinalTextOrStepsUpdates() {
        let l = """
        {"type":"assistant","sessionId":"s1","cwd":"/p","isSidechain":true,\
        "timestamp":"2026-09-01T00:00:00.000Z",\
        "message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Done with the errand."}]}}
        """
        let a = TranscriptParser.parseLine(l)
        XCTAssertEqual(a?.endsTurn, true)
        XCTAssertNil(a?.finalText)
        XCTAssertEqual(a?.stepsUpdates, [])
    }

    // MARK: - Pending action (what a permission prompt is about)

    private func toolUse(_ name: String, _ input: String) -> String {
        line("assistant", content: #"{"type":"tool_use","name":"\#(name)","input":\#(input)}"#)
    }

    func testBashCallIsARunWithItsCommand() {
        let a = TranscriptParser.parseLine(toolUse("Bash", #"{"command":"npm test"}"#))
        XCTAssertEqual(a?.pendingAction, .set(PendingAction(kind: .run(command: "npm test"))))
    }

    /// Only the first line: `cd … && …` scripts often start with the interesting
    /// part, and a multi-line script does not fit a peek anyway. Cut at 40 chars
    /// with an ellipsis.
    func testBashCommandIsItsFirstLineCutAtForty() {
        let long = String(repeating: "a", count: 50)
        let a = TranscriptParser.parseLine(toolUse("Bash", #"{"command":"\#(long)\nsecond line"}"#))
        XCTAssertEqual(a?.pendingAction, .set(PendingAction(kind: .run(command: String(repeating: "a", count: 40) + "…"))))
    }

    func testEditCallIsAnEditOfTheFileName() {
        let a = TranscriptParser.parseLine(toolUse("Edit", #"{"file_path":"/Users/x/proj/src/api.ts"}"#))
        XCTAssertEqual(a?.pendingAction, .set(PendingAction(kind: .edit(file: "api.ts"))))
    }

    func testWebFetchIsAnOpenOfTheHost() {
        let a = TranscriptParser.parseLine(toolUse("WebFetch", #"{"url":"https://docs.swift.org/swift-book/"}"#))
        XCTAssertEqual(a?.pendingAction, .set(PendingAction(kind: .open(host: "docs.swift.org"))))
    }

    func testAnyOtherToolIsAUseOfItsName() {
        let a = TranscriptParser.parseLine(toolUse("Grep", #"{"pattern":"x"}"#))
        XCTAssertEqual(a?.pendingAction, .set(PendingAction(kind: .use(tool: "Grep"))))
    }

    /// A result means the call ran: whatever was pending is not any more.
    func testToolResultClearsThePendingAction() {
        let a = TranscriptParser.parseLine(line("user", content: #"{"type":"tool_result","content":"ok"}"#))
        XCTAssertEqual(a?.pendingAction, .clear)
    }

    func testEndOfTurnClearsThePendingAction() {
        XCTAssertEqual(TranscriptParser.parseLine(assistant(stopReason: "end_turn"))?.pendingAction, .clear)
    }

    func testATypedPromptSaysNothingAboutPendingActions() {
        let l = #"{"type":"user","sessionId":"s1","cwd":"/p","timestamp":"2026-08-28T10:00:00.123Z","message":{"content":"fix the feed"}}"#
        XCTAssertNil(TranscriptParser.parseLine(l)?.pendingAction)
    }

    /// A subagent's call is the errand's, not what the session asks the user for.
    func testSidechainCallIsIgnored() {
        let l = #"{"type":"assistant","sessionId":"s1","cwd":"/p","isSidechain":true,"timestamp":"2026-08-28T10:00:00.123Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#
        XCTAssertNil(TranscriptParser.parseLine(l)?.pendingAction)
    }
}

