import XCTest
@testable import CodeCatCore

final class HandoffExtractorTests: XCTestCase {
    /// Every path exists and is a file, except ones ending in "/" which are folders.
    private func kind(_ path: String) -> HandoffExtractor.PathKind? {
        path.hasSuffix("/dist") ? .folder : .file
    }
    private func extract(_ text: String) -> Handoff? {
        HandoffExtractor.extract(from: text, pathKind: kind)
    }

    func testLocalhostChipShowsHostAndPort() {
        let h = extract("Dev server: http://localhost:4321/app")
        XCTAssertEqual(h?.links.map(\.kind), [.localhost])
        XCTAssertEqual(h?.links.first?.title, "localhost:4321")
        XCTAssertEqual(h?.links.first?.target.absoluteString, "http://localhost:4321/app")
        XCTAssertEqual(extract("http://127.0.0.1:5180")?.links.first?.title, "127.0.0.1:5180")
        XCTAssertEqual(extract("http://localhost/")?.links.first?.title, "localhost")
    }

    func testPullRequestAndOtherGitHubLinks() {
        let h = extract("PR: https://github.com/tim/codecat/pull/12 and https://github.com/tim/codecat/issues/3")
        XCTAssertEqual(h?.links.map(\.title), ["PR #12", "GitHub"])
        XCTAssertEqual(h?.links.map(\.kind), [.pullRequest, .github])
    }

    func testFigmaArtifactAndPlainWeb() {
        let h = extract("""
            https://www.figma.com/design/abc/File
            https://claude.ai/code/artifact/xyz
            https://www.example.com/docs
            """)
        XCTAssertEqual(h?.links.map(\.kind), [.figma, .artifact, .web])
        XCTAssertEqual(h?.links.map(\.title), ["Figma", "Artifact", "example.com"])
    }

    func testTrailingMarkdownAndSentencePunctuationIsStripped() {
        let h = extract("Open **http://localhost:4321**, then (https://github.com/a/b/pull/7).")
        XCTAssertEqual(h?.links.map { $0.target.absoluteString },
                       ["http://localhost:4321", "https://github.com/a/b/pull/7"])
    }

    func testExistingFileAndFolderPathsBecomeChips() {
        let h = extract("Wrote /Users/dev/Projects/app/index.html and the bundle at ~/Projects/app/dist")
        XCTAssertEqual(h?.links.map(\.kind), [.file, .folder])
        XCTAssertEqual(h?.links.map(\.title), ["index.html", "dist/"])
        XCTAssertEqual(h?.links[1].target.path, NSString(string: "~/Projects/app/dist").expandingTildeInPath)
    }

    func testAPathThatDoesNotExistIsDropped() {
        let h = HandoffExtractor.extract(from: "See /Users/dev/gone.txt", pathKind: { _ in nil })
        XCTAssertNil(h?.links.first)
    }

    func testTheAgentsOwnBookkeepingIsNotADeliverable() {
        let h = extract("Log: ~/.claude/projects/x/y.jsonl and ~/Library/Application Support/CodeCat/codecat.log")
        XCTAssertEqual(h?.links ?? [], [])
    }

    func testLinksAreDedupedAndCappedAtFour() {
        let h = extract("""
            http://localhost:1 http://localhost:1 http://localhost:2 http://localhost:3
            http://localhost:4 http://localhost:5
            """)
        XCTAssertEqual(h?.links.map(\.title), ["localhost:1", "localhost:2", "localhost:3", "localhost:4"])
    }

    func testSummaryIsTheFirstLineWithMarkdownStripped() {
        let h = extract("## **Done**, tests green.\n\nSee http://localhost:4321")
        XCTAssertEqual(h?.summary, "Done, tests green.")
    }

    func testSummarySkipsFencesBulletsAndLinesThatAreOnlyALink()  {
        let h = extract("```\nhttp://localhost:4321\n- **http://localhost:4321**\nDeployed to staging.")
        XCTAssertEqual(h?.summary, "Deployed to staging.")
    }

    func testMarkdownLinksCollapseToTheirText() {
        let h = extract("Created [PR #12](https://github.com/tim/codecat/pull/12).")
        XCTAssertEqual(h?.summary, "Created PR #12.")
    }

    func testMarkdownLinkOnlyLineIsStillLinkOnly() {
        let h = extract("[http://localhost:4321](http://localhost:4321)\nDone.")
        XCTAssertEqual(h?.summary, "Done.")
        XCTAssertEqual(h?.links.map(\.title), ["localhost:4321"])
    }

    func testSummaryIsCappedLikeTheTaskText() {
        let long = String(repeating: "word ", count: 60)
        XCTAssertLessThanOrEqual(extract(long)?.summary?.count ?? 0, TaskText.maxLength)
    }

    func testNothingUsefulYieldsNil() {
        XCTAssertNil(extract(""))
        XCTAssertNil(extract("```\n```"))
    }
}
