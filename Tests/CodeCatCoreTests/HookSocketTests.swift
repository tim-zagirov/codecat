import XCTest
@testable import CodeCatCore

final class HookSocketTests: XCTestCase {
    func testClientDatagramReachesServerAndDecodes() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codecat-test-\(UUID().uuidString.prefix(8)).sock")
        let exp = expectation(description: "event received")
        var received: HookEvent?
        let server = HookSocketServer(path: path) { event in
            received = event
            exp.fulfill()
        }
        try server.start()
        defer { server.stop() }

        let json = #"{"hook_event_name":"Stop","session_id":"s1","cwd":"/p"}"#
        XCTAssertTrue(HookSocketClient.send(json.data(using: .utf8)!, to: path))

        wait(for: [exp], timeout: 2)
        XCTAssertEqual(received?.hookEventName, "Stop")
        XCTAssertEqual(received?.sessionId, "s1")
    }

    func testGarbageDatagramIsIgnored() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codecat-test-\(UUID().uuidString.prefix(8)).sock")
        var count = 0
        let server = HookSocketServer(path: path) { _ in count += 1 }
        try server.start()
        defer { server.stop() }
        XCTAssertTrue(HookSocketClient.send("not json".data(using: .utf8)!, to: path))
        // даём серверу шанс обработать
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(count, 0)
    }

    func testSendToMissingSocketFailsQuietly() {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("codecat-none.sock")
        XCTAssertFalse(HookSocketClient.send(Data("x".utf8), to: path))
    }
}
