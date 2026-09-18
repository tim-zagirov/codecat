import XCTest
@testable import CodeCatCore

/// The text of what the user actually asked for — the line the session row shows so
/// "what is this session working on" has an answer. Everything here is about turning
/// a raw prompt into that one line, or deciding it has no answer at all.
final class TaskTextTests: XCTestCase {

    // MARK: sanitising

    /// A prompt is written as prose, over several lines. The row is one ribbon of
    /// text, so the line breaks become spaces — the first line alone is often only a
    /// preamble ("Проект X, репозиторий ~/…") with the actual request below it.
    func testMultilinePromptBecomesOneRibbon() {
        XCTAssertEqual(
            TaskText.sanitized("почини пагинацию\n\nпри скролле дублируются карточки"),
            "почини пагинацию при скролле дублируются карточки")
    }

    func testSurroundingWhitespaceIsDropped() {
        XCTAssertEqual(TaskText.sanitized("   fix the cursor   "), "fix the cursor")
    }

    func testAPromptOfNothingButWhitespaceHasNoTask() {
        XCTAssertNil(TaskText.sanitized(" \n\t "))
    }

    /// Claude Code renders a typed slash command into the transcript as a
    /// `<command-name>` block. What the user typed is the command itself, so that is
    /// what the row shows — the wrapper is not text anyone wrote.
    func testSlashCommandKeepsTheCommandAndDropsTheWrapper() {
        let raw = """
            <command-name>/code-review</command-name>
            <command-message>code-review</command-message>
            <command-args>--fix</command-args>
            """
        XCTAssertEqual(TaskText.sanitized(raw), "/code-review --fix")
    }

    /// The other machine-written shapes that sit in the same field: a command's
    /// output, the caveat block, an image placeholder. None of them is a task.
    func testMachineWrittenEntriesHaveNoTask() {
        XCTAssertNil(TaskText.sanitized("<local-command-stdout>Set model to `claude-opus-5`</local-command-stdout>"))
        XCTAssertNil(TaskText.sanitized("[Image: original 1206x2622, displayed at 920x2000]"))
        XCTAssertNil(TaskText.sanitized("[Request interrupted by user]"))
    }

    /// Storage, not display: the row clamps by lines, but a pasted 27 000-character
    /// prompt has no business living in memory — or in a hook payload (see
    /// `HookPayload`, where the datagram limit is 2 048 bytes).
    func testAVeryLongPromptIsCappedAtAWordBoundary() throws {
        let raw = String(repeating: "word ", count: 500)
        let text = try XCTUnwrap(TaskText.sanitized(raw))
        XCTAssertLessThanOrEqual(text.count, TaskText.maxLength)
        XCTAssertTrue(text.hasSuffix("…"), "the cut is marked, not silent")
        XCTAssertFalse(text.dropLast().hasSuffix(" "), "no space left hanging before the ellipsis")
    }

    /// A single "word" longer than the cap — a path, a URL, a base64 blob — has no
    /// boundary to cut on, so it is cut by character rather than dropped entirely.
    func testAnUnbrokenRunLongerThanTheCapIsStillCut() {
        let raw = String(repeating: "x", count: TaskText.maxLength * 2)
        XCTAssertEqual(TaskText.sanitized(raw)?.count, TaskText.maxLength)
    }

    // MARK: replacing

    /// The heart of the rule. In 1 012 real prompts on one machine, 28 % had a first
    /// line of 15 characters or less — "продолжай", "газ", "не открылся". Letting
    /// those overwrite the task turns the row back into something that says nothing,
    /// which is the bug this whole line exists to fix.
    func testAShortFollowUpDoesNotReplaceTheTask() {
        XCTAssertFalse(TaskText.replaces(current: "почини пагинацию в ленте", with: "продолжай"))
    }

    /// With nothing to lose, even "газ" is better than silence: it is what the user
    /// said, and it is the whole session so far.
    func testAShortPromptIsTakenWhenThereIsNoTaskYet() {
        XCTAssertTrue(TaskText.replaces(current: nil, with: "газ"))
    }

    /// A real new request replaces the old one — the session moved on, and the row
    /// must not keep describing what it was asked an hour ago.
    func testASubstantialPromptReplacesTheTask() {
        XCTAssertTrue(TaskText.replaces(current: "почини пагинацию в ленте",
                                        with: "теперь собери релиз и обнови CHANGELOG"))
    }
}
