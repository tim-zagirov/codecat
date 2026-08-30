# Переход к сессии, которая ждёт ответа — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Клик по строке сессии в панели деталей переключает пользователя туда, где эта сессия живёт — во вкладку терминала по TTY, либо выводит вперёд приложение-владелец.

**Architecture:** `codecat-hook` знает то, чего нет в payload'е хука (он — потомок `claude`), поэтому обогащает пересылаемый JSON четырьмя полями о маршруте: PID приложения-владельца, путь и bundle identifier его бандла, TTY. Эти поля доезжают до `Session` и переживают обновления состояния. Чистый `SessionRouter` в `CodeCatCore` превращает их в `JumpRoute`; слой приложения исполняет маршрут через `NSRunningApplication` / `NSAppleScript` за узким протоколом `JumpExecuting`, который в тестах подменяется.

**Tech Stack:** Swift 5.9, SwiftPM, macOS 14+, AppKit + SwiftUI, XCTest. Никаких новых зависимостей.

## Global Constraints

- Спек: `docs/superpowers/specs/2026-08-30-session-jump-design.md`. Всё, что там сказано, обязательно.
- Хук никогда не тормозит Claude Code: только `sysctl`/`proc_pidpath`/чтение одного `Info.plist`, никаких подпроцессов, никаких сетевых вызовов.
- Хук никогда не теряет событие: если входной JSON не разобрался — пересылаем полученные байты дословно.
- Все новые поля модели — опциональные: сессия, найденная вотчером транскриптов, маршрута не имеет.
- Все пользовательские тексты — по-русски. Молчаливых отказов нет: каждый исход перехода докладывается.
- Комментарии в коде — по-английски (как в существующих файлах `CodeCatCore`), пользовательские строки — по-русски.
- Тесты: `swift test`, все существующие 134 теста должны оставаться зелёными.
- Слой AppKit (реальная активация приложения и запуск AppleScript) юнит-тестами не покрывается — установившаяся граница проекта.
- Коммит после каждой задачи, сообщение по-английски, с `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.

## Уточнения к спеку (проверены на живом дереве процессов)

Спайк `sysctl(KERN_PROC_PID)` на этой машине дал две поправки, обе учтены в задачах ниже:

1. **Владелец — самый внешний `.app` в цепочке предков, а не первый.** Реальная цепочка для десктопного Claude: `claude` (лежит в `~/Library/Application Support/Claude/claude-code/<версия>/claude.app/Contents/MacOS/claude`) → `/Applications/Claude.app/Contents/Helpers/disclaimer` → `/Applications/Claude.app/Contents/MacOS/Claude`. Для сессии из терминала: `zsh` (tty `/dev/ttys001`) → `/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper` → `/Applications/Claude.app/Contents/MacOS/Claude`. Правило «первый предок внутри бандла» выбрало бы `claude.app` из Application Support или `Claude Helper.app` — оба не активируются. Правило «последний по цепочке предок внутри бандла, и в его пути берём самый внешний `.app`» даёт `/Applications/Claude.app` в обоих случаях, и PID у него тот, который нужен для `activate()`.
2. **Хук передаёт ещё и bundle identifier** (`host_bundle_id`, читается из `Info.plist` бандла через `Bundle(path:)`). Спек требует опознавать терминалы по bundle identifier — без этого поля пришлось бы гадать по имени файла бандла. Полей становится четыре вместо трёх.

## File Structure

Создаются:

- `Sources/CodeCatCore/ProcessTree.swift` — снимок процесса, протокол поставщика, живая реализация на `sysctl`, чистый резолвер владельца.
- `Sources/CodeCatCore/HookPayload.swift` — обогащение сырого JSON хука новыми полями.
- `Sources/CodeCatCore/SessionRouter.swift` — `JumpRoute`, `UnavailableReason`, `JumpOutcome`, `JumpExecuting`, выбор маршрута, тексты сообщений.
- `Sources/CodeCatCore/TerminalJumpScript.swift` — построение AppleScript для Terminal.app и iTerm2 с экранированием.
- `Sources/CodeCatApp/SystemJumpExecutor.swift` — реальная реализация `JumpExecuting`.
- `Tests/CodeCatCoreTests/ProcessTreeTests.swift`, `HookPayloadTests.swift`, `SessionRouterTests.swift`, `TerminalJumpScriptTests.swift`.

Модифицируются:

- `Sources/CodeCatCore/SessionModel.swift` — новые поля `HookEvent` и `Session`.
- `Sources/CodeCatCore/SessionStore.swift` — перенос полей маршрута из события в сессию.
- `Sources/codecat-hook/main.swift` — обогащение payload'а.
- `Sources/CodeCatApp/AppState.swift` — точка входа `jump(to:)` и показ сообщений.
- `Sources/CodeCatApp/DetailsPanelView.swift` — кликабельные строки.
- `Resources/Info.plist` — `NSAppleEventsUsageDescription`.
- `Tests/CodeCatCoreTests/SessionStoreTests.swift` — перенос полей.

---

### Task 1: Резолвер приложения-владельца

Чистая логика обхода предков, отделённая от системных вызовов инжектируемым поставщиком.

**Files:**
- Create: `Sources/CodeCatCore/ProcessTree.swift`
- Test: `Tests/CodeCatCoreTests/ProcessTreeTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `public struct ProcessSnapshot: Equatable, Sendable { public let pid: pid_t; public let ppid: pid_t; public let executablePath: String?; public let tty: String?; public init(pid: pid_t, ppid: pid_t, executablePath: String?, tty: String?) }`
  - `public protocol ProcessTreeProviding { func snapshot(for pid: pid_t) -> ProcessSnapshot? }`
  - `public struct HostApplication: Equatable, Sendable { public let pid: pid_t; public let bundlePath: String }`
  - `public enum ProcessTree { public static func outermostBundlePath(forExecutablePath path: String) -> String?; public static func host(startingAt pid: pid_t, provider: ProcessTreeProviding, maxDepth: Int = 24) -> HostApplication?; public static func tty(startingAt pid: pid_t, provider: ProcessTreeProviding) -> String? }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CodeCatCore

/// Fake process tree: pid -> snapshot, so ancestry logic is testable without syscalls.
private struct FakeTree: ProcessTreeProviding {
    var nodes: [pid_t: ProcessSnapshot]
    func snapshot(for pid: pid_t) -> ProcessSnapshot? { nodes[pid] }
}

private func node(_ pid: pid_t, _ ppid: pid_t, _ path: String?, tty: String? = nil) -> (pid_t, ProcessSnapshot) {
    (pid, ProcessSnapshot(pid: pid, ppid: ppid, executablePath: path, tty: tty))
}

final class ProcessTreeTests: XCTestCase {

    // MARK: - Extracting a bundle path from an executable path

    func testOutermostBundlePathOfAPlainExecutableIsNil() {
        XCTAssertNil(ProcessTree.outermostBundlePath(forExecutablePath: "/bin/zsh"))
    }

    func testOutermostBundlePathOfASimpleBundle() {
        XCTAssertEqual(
            ProcessTree.outermostBundlePath(
                forExecutablePath: "/Applications/Claude.app/Contents/MacOS/Claude"),
            "/Applications/Claude.app")
    }

    /// A helper nested inside its host bundle must resolve to the host, not to itself:
    /// activating the helper does nothing the user can see.
    func testNestedHelperBundleResolvesToTheOutermostBundle() {
        XCTAssertEqual(
            ProcessTree.outermostBundlePath(
                forExecutablePath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"),
            "/Applications/Claude.app")
    }

    func testPathContainingDotAppInAFolderNameIsNotABundle() {
        XCTAssertNil(ProcessTree.outermostBundlePath(forExecutablePath: "/Users/me/my.apple/bin/tool"))
    }

    // MARK: - Walking up to the owning application

    /// The real chain measured on macOS: the Claude Code CLI itself lives in an
    /// .app bundle under Application Support, and there is a helper bundle in
    /// between, so only the *last* bundle ancestor is the app the user sees.
    func testHostIsTheOutermostBundleAncestorNotTheFirstOne() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(500, 400, "/Users/me/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude"),
            node(400, 300, "/Applications/Claude.app/Contents/Helpers/disclaimer"),
            node(300, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
            node(1, 0, "/sbin/launchd"),
        ]))
        let host = ProcessTree.host(startingAt: 500, provider: tree)
        XCTAssertEqual(host, HostApplication(pid: 300, bundlePath: "/Applications/Claude.app"))
    }

    func testHostOfATerminalSessionIsTheTerminalApp() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude", tty: "/dev/ttys001"),
            node(600, 500, "/bin/zsh", tty: "/dev/ttys001"),
            node(500, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            node(1, 0, "/sbin/launchd"),
        ]))
        XCTAssertEqual(ProcessTree.host(startingAt: 700, provider: tree),
                       HostApplication(pid: 500, bundlePath: "/System/Applications/Utilities/Terminal.app"))
    }

    func testNoBundleAncestorMeansNoHost() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude"),
            node(600, 1, "/bin/zsh"),
            node(1, 0, "/sbin/launchd"),
        ]))
        XCTAssertNil(ProcessTree.host(startingAt: 700, provider: tree))
    }

    func testMissingSnapshotStopsTheWalkWithoutCrashing() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude"),
        ]))
        XCTAssertNil(ProcessTree.host(startingAt: 700, provider: tree))
    }

    /// A corrupt tree must not spin forever inside a hook that Claude Code waits on.
    func testCyclicParentChainTerminates() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(10, 20, "/bin/a"),
            node(20, 10, "/bin/b"),
        ]))
        XCTAssertNil(ProcessTree.host(startingAt: 10, provider: tree))
    }

    func testWalkStopsAtMaxDepth() {
        var nodes: [(pid_t, ProcessSnapshot)] = []
        for pid in pid_t(2)...pid_t(60) {
            nodes.append(node(pid, pid + 1, "/bin/link"))
        }
        nodes.append(node(61, 1, "/Applications/Far.app/Contents/MacOS/Far"))
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: nodes))
        XCTAssertNil(ProcessTree.host(startingAt: 2, provider: tree, maxDepth: 5))
    }

    // MARK: - TTY

    func testTtyIsTakenFromTheStartingProcess() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude", tty: "/dev/ttys003"),
            node(600, 1, "/bin/zsh", tty: "/dev/ttys003"),
        ]))
        XCTAssertEqual(ProcessTree.tty(startingAt: 700, provider: tree), "/dev/ttys003")
    }

    /// A GUI-launched session has no controlling terminal anywhere up the chain.
    func testNoTtyAnywhereMeansNil() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude"),
            node(600, 1, "/bin/zsh"),
        ]))
        XCTAssertNil(ProcessTree.tty(startingAt: 700, provider: tree))
    }

    /// Claude Code may sit under a wrapper that has no tty of its own while the
    /// shell above it does; the terminal tab is still the right destination.
    func testTtyFallsBackToAnAncestor() {
        let tree = FakeTree(nodes: Dictionary(uniqueKeysWithValues: [
            node(700, 600, "/opt/homebrew/bin/claude"),
            node(600, 500, "/bin/zsh", tty: "/dev/ttys004"),
            node(500, 1, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ]))
        XCTAssertEqual(ProcessTree.tty(startingAt: 700, provider: tree), "/dev/ttys004")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProcessTreeTests`
Expected: FAIL — `cannot find 'ProcessTree' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// One process, reduced to what routing needs. Kept separate from the syscalls that
/// produce it so ancestry logic can be tested on a modelled tree.
public struct ProcessSnapshot: Equatable, Sendable {
    public let pid: pid_t
    public let ppid: pid_t
    public let executablePath: String?
    public let tty: String?

    public init(pid: pid_t, ppid: pid_t, executablePath: String?, tty: String?) {
        self.pid = pid
        self.ppid = ppid
        self.executablePath = executablePath
        self.tty = tty
    }
}

public protocol ProcessTreeProviding {
    func snapshot(for pid: pid_t) -> ProcessSnapshot?
}

/// The application a session belongs to: the window-owning app the user can be sent to.
public struct HostApplication: Equatable, Sendable {
    public let pid: pid_t
    public let bundlePath: String

    public init(pid: pid_t, bundlePath: String) {
        self.pid = pid
        self.bundlePath = bundlePath
    }
}

public enum ProcessTree {

    /// The outermost `.app` bundle containing `path`, or nil if it is not inside one.
    ///
    /// Outermost, not innermost: an executable at
    /// `/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper`
    /// belongs to `/Applications/Claude.app` — activating the nested helper bundle
    /// shows the user nothing.
    public static func outermostBundlePath(forExecutablePath path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        var prefix: [Substring] = []
        for component in components {
            prefix.append(component)
            if component.hasSuffix(".app") {
                return prefix.joined(separator: "/")
            }
        }
        return nil
    }

    /// Walks up from `pid` and returns the *last* ancestor that lives inside an
    /// `.app` bundle — the outermost application in the chain, which is the one
    /// that owns a window and answers to `activate()`. See the plan's notes: the
    /// first such ancestor is routinely a nested helper or the CLI's own bundle.
    ///
    /// `maxDepth` and the visited set are hook-safety guards: this runs inside
    /// `codecat-hook`, which Claude Code waits on, so a corrupt or cyclic parent
    /// chain must terminate rather than spin.
    public static func host(startingAt pid: pid_t,
                            provider: ProcessTreeProviding,
                            maxDepth: Int = 24) -> HostApplication? {
        var found: HostApplication?
        var visited: Set<pid_t> = []
        var current = pid
        for _ in 0..<maxDepth {
            guard !visited.contains(current), let snapshot = provider.snapshot(for: current) else { break }
            visited.insert(current)
            if let path = snapshot.executablePath,
               let bundle = outermostBundlePath(forExecutablePath: path) {
                found = HostApplication(pid: snapshot.pid, bundlePath: bundle)
            }
            guard snapshot.ppid > 1 else { break }
            current = snapshot.ppid
        }
        return found
    }

    /// The controlling terminal of the session, taken from the first ancestor that
    /// has one: a wrapper process may have no tty while the shell above it does.
    public static func tty(startingAt pid: pid_t,
                           provider: ProcessTreeProviding,
                           maxDepth: Int = 24) -> String? {
        var visited: Set<pid_t> = []
        var current = pid
        for _ in 0..<maxDepth {
            guard !visited.contains(current), let snapshot = provider.snapshot(for: current) else { return nil }
            visited.insert(current)
            if let tty = snapshot.tty, !tty.isEmpty { return tty }
            guard snapshot.ppid > 1 else { return nil }
            current = snapshot.ppid
        }
        return nil
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProcessTreeTests`
Expected: PASS, все тесты.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/ProcessTree.swift Tests/CodeCatCoreTests/ProcessTreeTests.swift
git commit -m "feat: resolve the application that owns a Claude session"
```

---

### Task 2: Живой поставщик дерева процессов

Реализация `ProcessTreeProviding` поверх `sysctl`. Системный слой юнит-тестами не покрывается, но проверяется одним тестом на собственном процессе.

**Files:**
- Modify: `Sources/CodeCatCore/ProcessTree.swift` (добавить в конец)
- Test: `Tests/CodeCatCoreTests/ProcessTreeTests.swift` (добавить в конец файла)

**Interfaces:**
- Consumes: `ProcessSnapshot`, `ProcessTreeProviding` из Task 1.
- Produces: `public struct LiveProcessTree: ProcessTreeProviding { public init(); public func snapshot(for pid: pid_t) -> ProcessSnapshot? }`

- [ ] **Step 1: Write the failing test**

```swift
// Добавить в конец Tests/CodeCatCoreTests/ProcessTreeTests.swift

extension ProcessTreeTests {

    /// The syscall layer cannot be modelled, so it is pinned against the one process
    /// whose facts the test already knows: itself.
    func testLiveTreeReportsThisProcessCorrectly() {
        let snapshot = LiveProcessTree().snapshot(for: getpid())
        XCTAssertEqual(snapshot?.pid, getpid())
        XCTAssertEqual(snapshot?.ppid, getppid())
        XCTAssertNotNil(snapshot?.executablePath)
        XCTAssertTrue(snapshot?.executablePath?.hasPrefix("/") == true)
    }

    func testLiveTreeReturnsNilForAPidThatCannotExist() {
        XCTAssertNil(LiveProcessTree().snapshot(for: -1))
    }

    /// Walking from the test process must reach launchd's children without hanging
    /// or crashing, whatever the real machine's tree looks like.
    func testWalkingTheRealTreeTerminates() {
        _ = ProcessTree.host(startingAt: getpid(), provider: LiveProcessTree())
        _ = ProcessTree.tty(startingAt: getpid(), provider: LiveProcessTree())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProcessTreeTests`
Expected: FAIL — `cannot find 'LiveProcessTree' in scope`.

- [ ] **Step 3: Write minimal implementation**

Дописать в `Sources/CodeCatCore/ProcessTree.swift`:

```swift
/// `ProcessTreeProviding` backed by `sysctl(KERN_PROC_PID)` plus `proc_pidpath`.
///
/// A few syscalls and no subprocesses: this runs inside `codecat-hook`, which
/// Claude Code blocks on, so shelling out to `ps` would be paying milliseconds of
/// process spawn on every hook event.
public struct LiveProcessTree: ProcessTreeProviding {
    public init() {}

    public func snapshot(for pid: pid_t) -> ProcessSnapshot? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, 4, &kp, &size, nil, 0)
        // A dead pid returns 0 with size 0 rather than an error.
        guard rc == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        return ProcessSnapshot(pid: pid,
                               ppid: kp.kp_eproc.e_ppid,
                               executablePath: Self.executablePath(for: pid),
                               tty: Self.ttyName(kp.kp_eproc.e_tdev))
    }

    private static func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `e_tdev` is the controlling terminal's device number, or `NODEV` (-1) when
    /// the process has none — a GUI-launched session.
    private static func ttyName(_ device: dev_t) -> String? {
        guard device != dev_t(bitPattern: UInt(UInt32.max)), device != 0 else { return nil }
        guard let name = devname(device, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProcessTreeTests`
Expected: PASS. Если `devname`/`proc_pidpath` не находятся — добавить `import Darwin` в начало файла рядом с `import Foundation`.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/ProcessTree.swift Tests/CodeCatCoreTests/ProcessTreeTests.swift
git commit -m "feat: read the live process tree through sysctl"
```

---

### Task 3: Обогащение payload'а хука

**Files:**
- Create: `Sources/CodeCatCore/HookPayload.swift`
- Test: `Tests/CodeCatCoreTests/HookPayloadTests.swift`

**Interfaces:**
- Consumes: ничего (чистая работа с JSON).
- Produces: `public enum HookPayload { public struct RouteFields: Equatable { public let hostPID: pid_t?; public let hostBundlePath: String?; public let hostBundleID: String?; public let tty: String?; public init(hostPID: pid_t?, hostBundlePath: String?, hostBundleID: String?, tty: String?) }; public static func enriched(_ data: Data, with fields: RouteFields) -> Data }`
- Ключи JSON: `host_pid`, `host_bundle_path`, `host_bundle_id`, `tty`.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HookPayloadTests`
Expected: FAIL — `cannot find 'HookPayload' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Adds the routing facts `codecat-hook` knows (being a child of `claude`) to the
/// JSON payload Claude Code hands it, before forwarding it to the app.
public enum HookPayload {

    public struct RouteFields: Equatable, Sendable {
        public let hostPID: pid_t?
        public let hostBundlePath: String?
        public let hostBundleID: String?
        public let tty: String?

        public init(hostPID: pid_t?, hostBundlePath: String?, hostBundleID: String?, tty: String?) {
            self.hostPID = hostPID
            self.hostBundlePath = hostBundlePath
            self.hostBundleID = hostBundleID
            self.tty = tty
        }
    }

    /// Returns `data` with the route fields added. Anything that is not a JSON
    /// object — or that fails to re-encode — comes back byte for byte: enrichment
    /// must never be the reason an event is lost.
    public static func enriched(_ data: Data, with fields: RouteFields) -> Data {
        guard !data.isEmpty,
              let parsed = try? JSONSerialization.jsonObject(with: data),
              var object = parsed as? [String: Any] else { return data }

        if let pid = fields.hostPID { object["host_pid"] = Int(pid) }
        if let path = fields.hostBundlePath { object["host_bundle_path"] = path }
        if let id = fields.hostBundleID { object["host_bundle_id"] = id }
        if let tty = fields.tty { object["tty"] = tty }

        guard let encoded = try? JSONSerialization.data(withJSONObject: object) else { return data }
        return encoded
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HookPayloadTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/HookPayload.swift Tests/CodeCatCoreTests/HookPayloadTests.swift
git commit -m "feat: enrich the hook payload with routing fields"
```

---

### Task 4: Хук собирает и отправляет маршрут

**Files:**
- Modify: `Sources/codecat-hook/main.swift` (весь файл)

**Interfaces:**
- Consumes: `ProcessTree`, `LiveProcessTree`, `HostApplication`, `HookPayload.RouteFields`, `HookPayload.enriched`, `HookSocketClient.send`, `CodeCatPaths.socketURL`.
- Produces: ничего для других задач.

- [ ] **Step 1: Write the failing test**

Юнит-теста здесь нет: файл — это точка входа исполняемого файла, его логика уже покрыта задачами 1–3. Вместо теста — исполняемая проверка на живой машине, она же Step 4.

- [ ] **Step 2: Записать ожидаемое поведение до правки**

Run: `swift build && echo '{"hook_event_name":"SessionStart","session_id":"plan-check","cwd":"/tmp/p"}' | ./.build/debug/codecat-hook`
Expected: команда завершается кодом 0 и ничего не печатает (приложение может быть не запущено — это штатно).

- [ ] **Step 3: Write minimal implementation**

Полное новое содержимое `Sources/codecat-hook/main.swift`:

```swift
import Foundation
import CodeCatCore

// Claude Code передаёт JSON события на stdin. Пересылаем в сокет приложения,
// добавив то, что знает только этот процесс: он — потомок `claude`, поэтому
// может пройти по предкам и найти приложение-владелец и терминал сессии.
// Приложение не запущено / любая ошибка → тихий выход 0: хук не имеет права
// мешать работе Claude Code.
let input = FileHandle.standardInput.readDataToEndOfFile()
if !input.isEmpty {
    let tree = LiveProcessTree()
    let host = ProcessTree.host(startingAt: getpid(), provider: tree)
    let fields = HookPayload.RouteFields(
        hostPID: host?.pid,
        hostBundlePath: host?.bundlePath,
        // Reading the bundle's Info.plist is a single small file read; the terminal
        // recognition in `SessionRouter` keys off the identifier, not the file name.
        hostBundleID: host.flatMap { Bundle(path: $0.bundlePath)?.bundleIdentifier },
        tty: ProcessTree.tty(startingAt: getpid(), provider: tree))
    HookSocketClient.send(HookPayload.enriched(input, with: fields), to: CodeCatPaths.socketURL)
}
exit(0)
```

- [ ] **Step 4: Проверить на живой машине**

Run:
```bash
swift build && echo '{"hook_event_name":"SessionStart","session_id":"plan-check","cwd":"/tmp/p"}' | ./.build/debug/codecat-hook && echo "exit=$?"
```
Expected: `exit=0`, вывода нет, команда возвращается мгновенно (меньше секунды).

Затем убедиться, что обход по живому дереву работает и завершается:

Run: `swift test --filter ProcessTreeTests`
Expected: PASS, включая `testWalkingTheRealTreeTerminates` и `testLiveTreeReportsThisProcessCorrectly`.

- [ ] **Step 5: Commit**

```bash
git add Sources/codecat-hook/main.swift
git commit -m "feat: send the session's host application and tty from the hook"
```

---

### Task 5: Поля маршрута в модели и хранилище

**Files:**
- Modify: `Sources/CodeCatCore/SessionModel.swift` (`HookEvent`, `Session`)
- Modify: `Sources/CodeCatCore/SessionStore.swift` (`upsert`)
- Test: `Tests/CodeCatCoreTests/SessionStoreTests.swift` (добавить в конец файла)

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `HookEvent` получает `public let hostPID: pid_t?`, `public let hostBundlePath: String?`, `public let hostBundleID: String?`, `public let tty: String?` с ключами `host_pid`, `host_bundle_path`, `host_bundle_id`, `tty`; его `init` получает те же параметры **со значениями по умолчанию `nil`**, чтобы существующие вызовы в тестах не ломались.
  - `Session` получает `public var hostPID: pid_t? = nil`, `public var hostBundlePath: String? = nil`, `public var hostBundleID: String? = nil`, `public var tty: String? = nil`.

- [ ] **Step 1: Write the failing test**

```swift
// Добавить в конец Tests/CodeCatCoreTests/SessionStoreTests.swift

extension SessionStoreTests {

    private func routedEvent(_ name: String, id: String = "s1") -> HookEvent {
        HookEvent(hookEventName: name, sessionId: id, cwd: "/tmp/project", message: nil,
                  hostPID: 4242, hostBundlePath: "/Applications/Claude.app",
                  hostBundleID: "com.anthropic.claudefordesktop", tty: "/dev/ttys001")
    }

    func testHookEventDecodesTheRouteFields() throws {
        let json = #"""
        {"hook_event_name":"SessionStart","session_id":"abc","cwd":"/tmp/p",
         "host_pid":4242,"host_bundle_path":"/Applications/Claude.app",
         "host_bundle_id":"com.anthropic.claudefordesktop","tty":"/dev/ttys001"}
        """#.data(using: .utf8)!
        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.hostPID, 4242)
        XCTAssertEqual(event.hostBundlePath, "/Applications/Claude.app")
        XCTAssertEqual(event.hostBundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(event.tty, "/dev/ttys001")
    }

    /// Events from an older hook binary have none of the new fields; decoding must
    /// still succeed rather than dropping the event.
    func testHookEventDecodesWithoutTheRouteFields() throws {
        let json = #"{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp/p"}"#.data(using: .utf8)!
        let event = try JSONDecoder().decode(HookEvent.self, from: json)
        XCTAssertNil(event.hostPID)
        XCTAssertNil(event.hostBundlePath)
        XCTAssertNil(event.hostBundleID)
        XCTAssertNil(event.tty)
    }

    func testStoreCarriesTheRouteFromTheEventToTheSession() {
        let store = SessionStore()
        store.apply(hook: routedEvent("SessionStart"), now: Date())
        let session = store.sessions["s1"]
        XCTAssertEqual(session?.hostPID, 4242)
        XCTAssertEqual(session?.hostBundlePath, "/Applications/Claude.app")
        XCTAssertEqual(session?.hostBundleID, "com.anthropic.claudefordesktop")
        XCTAssertEqual(session?.tty, "/dev/ttys001")
    }

    /// A transcript update must not wipe the route: the watcher knows nothing about
    /// the host, and losing the route would silently disable the jump mid-session.
    func testTranscriptActivityKeepsAnAlreadyKnownRoute() {
        let store = SessionStore()
        let start = Date()
        store.apply(hook: routedEvent("SessionStart"), now: start)
        store.apply(activity: TranscriptActivity(
            sessionId: "s1", projectPath: "/tmp/project",
            description: "правит файл", timestamp: start.addingTimeInterval(5)))
        XCTAssertEqual(store.sessions["s1"]?.hostPID, 4242)
        XCTAssertEqual(store.sessions["s1"]?.tty, "/dev/ttys001")
    }

    /// An event that carries no route (older hook) must not erase a route already
    /// recorded for that session.
    func testEventWithoutRouteDoesNotEraseAKnownRoute() {
        let store = SessionStore()
        let start = Date()
        store.apply(hook: routedEvent("SessionStart"), now: start)
        store.apply(hook: HookEvent(hookEventName: "Notification", sessionId: "s1",
                                    cwd: "/tmp/project", message: "permission"),
                    now: start.addingTimeInterval(1))
        XCTAssertEqual(store.sessions["s1"]?.hostPID, 4242)
        XCTAssertEqual(store.sessions["s1"]?.hostBundlePath, "/Applications/Claude.app")
    }

    /// A session that only ever appeared through the transcript watcher has no route.
    func testTranscriptOnlySessionHasNoRoute() {
        let store = SessionStore()
        store.apply(activity: TranscriptActivity(
            sessionId: "only-transcript", projectPath: "/tmp/p",
            description: "работает", timestamp: Date()))
        XCTAssertNil(store.sessions["only-transcript"]?.hostPID)
        XCTAssertNil(store.sessions["only-transcript"]?.tty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionStoreTests`
Expected: FAIL — у `HookEvent.init` нет параметров `hostPID:` и т. д.

- [ ] **Step 3: Write minimal implementation**

В `Sources/CodeCatCore/SessionModel.swift` заменить `HookEvent` целиком на:

```swift
public struct HookEvent: Codable, Equatable, Sendable {
    public let hookEventName: String
    public let sessionId: String
    public let cwd: String?
    public let message: String?
    /// Route to the session, added by `codecat-hook` (see `HookPayload`). All
    /// optional: an older hook binary, or a payload that failed to parse, sends none
    /// of them and the event must still be accepted.
    public let hostPID: pid_t?
    public let hostBundlePath: String?
    public let hostBundleID: String?
    public let tty: String?

    public init(hookEventName: String, sessionId: String, cwd: String?, message: String?,
                hostPID: pid_t? = nil, hostBundlePath: String? = nil,
                hostBundleID: String? = nil, tty: String? = nil) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.cwd = cwd
        self.message = message
        self.hostPID = hostPID
        self.hostBundlePath = hostBundlePath
        self.hostBundleID = hostBundleID
        self.tty = tty
    }

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd, message, tty
        case hostPID = "host_pid"
        case hostBundlePath = "host_bundle_path"
        case hostBundleID = "host_bundle_id"
    }
}
```

В `Session` добавить после `public var finishedAt: Date? = nil`:

```swift
    /// Where this session lives, as recorded by `codecat-hook`. Nil for a session
    /// the transcript watcher discovered on its own — it has no route.
    public var hostPID: pid_t? = nil
    public var hostBundlePath: String? = nil
    public var hostBundleID: String? = nil
    public var tty: String? = nil
```

В `SessionStore.upsert` добавить перед `mutate(&s)`:

```swift
        // Only ever fill the route in, never clear it: a `Notification` from an older
        // hook binary, or any event that lost its enrichment, must not disable the
        // jump for a session whose route is already known.
        if let pid = event.hostPID { s.hostPID = pid }
        if let path = event.hostBundlePath, !path.isEmpty { s.hostBundlePath = path }
        if let id = event.hostBundleID, !id.isEmpty { s.hostBundleID = id }
        if let tty = event.tty, !tty.isEmpty { s.tty = tty }
```

Для этого `upsert` должен получать событие целиком. Заменить его сигнатуру на
`private func upsert(event: HookEvent, now: Date, _ mutate: (inout Session) -> Void)`,
внутри использовать `event.sessionId` и `event.cwd`, и обновить все четыре вызова в
`apply(hook:now:)` на `upsert(event: event, now: now) { s in ... }`.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test`
Expected: PASS, включая все существующие тесты.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/SessionModel.swift Sources/CodeCatCore/SessionStore.swift Tests/CodeCatCoreTests/SessionStoreTests.swift
git commit -m "feat: carry the session route from hook events into the store"
```

---

### Task 6: SessionRouter — выбор маршрута

**Files:**
- Create: `Sources/CodeCatCore/SessionRouter.swift`
- Test: `Tests/CodeCatCoreTests/SessionRouterTests.swift`

**Interfaces:**
- Consumes: `Session` из Task 5.
- Produces:
  - `public enum JumpRoute: Equatable, Sendable { case terminalTab(bundleID: String, bundlePath: String, pid: pid_t, tty: String); case application(pid: pid_t, bundlePath: String); case unavailable(reason: UnavailableReason) }`
  - `public enum UnavailableReason: Equatable, Sendable { case noHostRecorded; case hostGone }`
  - `public enum SessionRouter { public static let terminalBundleIDs: Set<String>; public static func route(for session: Session, isHostRunning: (pid_t) -> Bool) -> JumpRoute; public static func isProcessRunning(_ pid: pid_t) -> Bool }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CodeCatCore

final class SessionRouterTests: XCTestCase {

    private func session(hostPID: pid_t? = 4242,
                         bundlePath: String? = "/Applications/Claude.app",
                         bundleID: String? = "com.anthropic.claudefordesktop",
                         tty: String? = nil) -> Session {
        var s = Session(id: "s1", projectPath: "/tmp/p", status: .working,
                        activityDescription: "", startedAt: Date(), lastActivity: Date())
        s.hostPID = hostPID
        s.hostBundlePath = bundlePath
        s.hostBundleID = bundleID
        s.tty = tty
        return s
    }

    private let running: (pid_t) -> Bool = { _ in true }
    private let gone: (pid_t) -> Bool = { _ in false }

    /// Most precise route: a recognised terminal plus a tty means the exact tab.
    func testTerminalWithATtyRoutesToTheTab() {
        let s = session(bundlePath: "/System/Applications/Utilities/Terminal.app",
                        bundleID: "com.apple.Terminal", tty: "/dev/ttys001")
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .terminalTab(bundleID: "com.apple.Terminal",
                                    bundlePath: "/System/Applications/Utilities/Terminal.app",
                                    pid: 4242, tty: "/dev/ttys001"))
    }

    func testITermIsRecognisedAsATerminal() {
        let s = session(bundlePath: "/Applications/iTerm.app",
                        bundleID: "com.googlecode.iterm2", tty: "/dev/ttys002")
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .terminalTab(bundleID: "com.googlecode.iterm2",
                                    bundlePath: "/Applications/iTerm.app",
                                    pid: 4242, tty: "/dev/ttys002"))
    }

    /// A terminal without a tty cannot be aimed at a tab — bring the app forward.
    func testTerminalWithoutATtyFallsBackToTheApplication() {
        let s = session(bundlePath: "/System/Applications/Utilities/Terminal.app",
                        bundleID: "com.apple.Terminal", tty: nil)
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .application(pid: 4242, bundlePath: "/System/Applications/Utilities/Terminal.app"))
    }

    /// A tty in an app that is not a supported terminal is not actionable: there is
    /// no scripting interface to select a tab with.
    func testTtyInAnUnsupportedHostFallsBackToTheApplication() {
        let s = session(tty: "/dev/ttys001")
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .application(pid: 4242, bundlePath: "/Applications/Claude.app"))
    }

    func testDesktopAppRoutesToTheApplication() {
        XCTAssertEqual(SessionRouter.route(for: session(), isHostRunning: running),
                       .application(pid: 4242, bundlePath: "/Applications/Claude.app"))
    }

    /// A session the transcript watcher found on its own carries no route at all.
    func testSessionWithoutAHostIsUnavailable() {
        let s = session(hostPID: nil, bundlePath: nil, bundleID: nil)
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .unavailable(reason: .noHostRecorded))
    }

    func testSessionWithABundleButNoPidIsUnavailable() {
        let s = session(hostPID: nil)
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .unavailable(reason: .noHostRecorded))
    }

    func testSessionWithAPidButNoBundleIsUnavailable() {
        let s = session(bundlePath: nil, bundleID: nil)
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .unavailable(reason: .noHostRecorded))
    }

    /// The owning app quit: the row must say so instead of offering a dead click.
    func testHostThatIsNoLongerRunningIsUnavailable() {
        XCTAssertEqual(SessionRouter.route(for: session(), isHostRunning: gone),
                       .unavailable(reason: .hostGone))
    }

    func testTerminalHostThatIsGoneIsUnavailableRatherThanATab() {
        let s = session(bundlePath: "/System/Applications/Utilities/Terminal.app",
                        bundleID: "com.apple.Terminal", tty: "/dev/ttys001")
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: gone),
                       .unavailable(reason: .hostGone))
    }

    func testAnEmptyTtyStringIsTreatedAsNoTty() {
        let s = session(bundlePath: "/System/Applications/Utilities/Terminal.app",
                        bundleID: "com.apple.Terminal", tty: "")
        XCTAssertEqual(SessionRouter.route(for: s, isHostRunning: running),
                       .application(pid: 4242, bundlePath: "/System/Applications/Utilities/Terminal.app"))
    }

    // MARK: - Liveness of a real process

    func testThisProcessIsSeenAsRunning() {
        XCTAssertTrue(SessionRouter.isProcessRunning(getpid()))
    }

    func testAnImpossiblePidIsNotSeenAsRunning() {
        XCTAssertFalse(SessionRouter.isProcessRunning(-1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionRouterTests`
Expected: FAIL — `cannot find 'SessionRouter' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Where a click on a session row should send the user, in descending precision.
public enum JumpRoute: Equatable, Sendable {
    /// A terminal whose scripting interface can select the exact tab by tty.
    case terminalTab(bundleID: String, bundlePath: String, pid: pid_t, tty: String)
    /// The owning application, brought forward. No window-level aiming: sessions of
    /// the desktop Claude app are child processes with no windows of their own, so
    /// picking a window would be guesswork (see the design spec).
    case application(pid: pid_t, bundlePath: String)
    case unavailable(reason: UnavailableReason)
}

public enum UnavailableReason: Equatable, Sendable {
    /// The session was discovered by the transcript watcher; the hook never saw it,
    /// so nothing is known about where it runs.
    case noHostRecorded
    /// The owning application is no longer running.
    case hostGone
}

/// Pure choice of a jump route. No system access beyond the injected liveness check,
/// so every combination of inputs is testable on fixed values.
public enum SessionRouter {

    /// Terminals whose AppleScript interface exposes a tab's tty, so the exact tab
    /// can be selected. Any other host falls back to bringing the app forward.
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
    ]

    public static func route(for session: Session, isHostRunning: (pid_t) -> Bool) -> JumpRoute {
        guard let pid = session.hostPID,
              let bundlePath = session.hostBundlePath, !bundlePath.isEmpty else {
            return .unavailable(reason: .noHostRecorded)
        }
        guard isHostRunning(pid) else { return .unavailable(reason: .hostGone) }

        if let bundleID = session.hostBundleID, terminalBundleIDs.contains(bundleID),
           let tty = session.tty, !tty.isEmpty {
            return .terminalTab(bundleID: bundleID, bundlePath: bundlePath, pid: pid, tty: tty)
        }
        return .application(pid: pid, bundlePath: bundlePath)
    }

    /// `kill(pid, 0)` performs the permission and existence check without sending a
    /// signal. `EPERM` means the process exists but belongs to someone else, which
    /// still counts as running.
    public static func isProcessRunning(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionRouterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/SessionRouter.swift Tests/CodeCatCoreTests/SessionRouterTests.swift
git commit -m "feat: choose a jump route for a session"
```

---

### Task 7: AppleScript для перехода во вкладку

**Files:**
- Create: `Sources/CodeCatCore/TerminalJumpScript.swift`
- Test: `Tests/CodeCatCoreTests/TerminalJumpScriptTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces: `public enum TerminalJumpScript { public static let successMarker: String; public static let notFoundMarker: String; public static func escaped(_ value: String) -> String; public static func script(bundleID: String, tty: String) -> String? }`
- Скрипт печатает `successMarker` («codecat-ok») при попадании и `notFoundMarker` («codecat-notfound»), если вкладки с таким tty нет.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import CodeCatCore

final class TerminalJumpScriptTests: XCTestCase {

    // MARK: - Escaping into an AppleScript string literal

    func testPlainValueIsUnchanged() {
        XCTAssertEqual(TerminalJumpScript.escaped("/dev/ttys001"), "/dev/ttys001")
    }

    func testDoubleQuoteIsEscaped() {
        XCTAssertEqual(TerminalJumpScript.escaped(#"a"b"#), #"a\"b"#)
    }

    func testBackslashIsEscaped() {
        XCTAssertEqual(TerminalJumpScript.escaped(#"a\b"#), #"a\\b"#)
    }

    /// Backslashes must be doubled before quotes are escaped, otherwise the
    /// backslash inserted for the quote gets doubled too and the literal breaks.
    func testBackslashBeforeQuoteIsEscapedInTheRightOrder() {
        XCTAssertEqual(TerminalJumpScript.escaped(#"a\"b"#), #"a\\\"b"#)
    }

    func testSpacesSurviveEscaping() {
        XCTAssertEqual(TerminalJumpScript.escaped("/dev/tty with space"),
                       "/dev/tty with space")
    }

    // MARK: - Script contents

    func testTerminalScriptTargetsTerminalAndTheGivenTty() {
        let script = TerminalJumpScript.script(bundleID: "com.apple.Terminal", tty: "/dev/ttys001")
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains(#"id "com.apple.Terminal""#))
        XCTAssertTrue(script!.contains(#""/dev/ttys001""#))
        XCTAssertTrue(script!.contains(TerminalJumpScript.successMarker))
        XCTAssertTrue(script!.contains(TerminalJumpScript.notFoundMarker))
    }

    func testITermScriptTargetsITerm() {
        let script = TerminalJumpScript.script(bundleID: "com.googlecode.iterm2", tty: "/dev/ttys002")
        XCTAssertNotNil(script)
        XCTAssertTrue(script!.contains(#"id "com.googlecode.iterm2""#))
        XCTAssertTrue(script!.contains(#""/dev/ttys002""#))
    }

    func testUnknownTerminalHasNoScript() {
        XCTAssertNil(TerminalJumpScript.script(bundleID: "com.example.other", tty: "/dev/ttys001"))
    }

    /// A tty containing a quote must not be able to close the literal and inject
    /// AppleScript of its own.
    func testHostileTtyCannotEscapeTheStringLiteral() {
        let script = TerminalJumpScript.script(
            bundleID: "com.apple.Terminal", tty: #"/dev/x" & (do shell script "echo pwned") & ""#)
        XCTAssertNotNil(script)
        XCTAssertFalse(script!.contains(#"& (do shell script "echo pwned")"#))
        XCTAssertTrue(script!.contains(#"\""#))
    }

    /// Every bundle id the router can route to a tab must have a script, or a jump
    /// would silently have nowhere to go.
    func testEveryRecognisedTerminalHasAScript() {
        for id in SessionRouter.terminalBundleIDs {
            XCTAssertNotNil(TerminalJumpScript.script(bundleID: id, tty: "/dev/ttys001"),
                            "no script for \(id)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TerminalJumpScriptTests`
Expected: FAIL — `cannot find 'TerminalJumpScript' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// Builds the AppleScript that selects the terminal tab a session runs in.
///
/// Terminals are addressed by bundle id (`tell application id "..."`) rather than by
/// name, so a renamed or relocated copy still resolves, and the tty is embedded as a
/// string literal — escaped, never interpolated raw, the same discipline as
/// `LidHelperInstall.appleScript(forScriptAt:)`.
public enum TerminalJumpScript {
    /// Printed by the script when the tab was found and selected.
    public static let successMarker = "codecat-ok"
    /// Printed when no tab with that tty exists any more (the user closed it).
    public static let notFoundMarker = "codecat-notfound"

    /// Escapes a value for an AppleScript string literal. Backslashes first, then
    /// quotes: doing it the other way round would double the backslash that escaping
    /// a quote just inserted.
    public static func escaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func script(bundleID: String, tty: String) -> String? {
        let tty = escaped(tty)
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "\(successMarker)"
                        end if
                    end repeat
                end repeat
            end tell
            return "\(notFoundMarker)"
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return "\(successMarker)"
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return "\(notFoundMarker)"
            """
        default:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TerminalJumpScriptTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/TerminalJumpScript.swift Tests/CodeCatCoreTests/TerminalJumpScriptTests.swift
git commit -m "feat: build the AppleScript that selects a session's terminal tab"
```

---

### Task 8: Исходы перехода и сообщения пользователю

**Files:**
- Modify: `Sources/CodeCatCore/SessionRouter.swift` (добавить в конец)
- Test: `Tests/CodeCatCoreTests/SessionRouterTests.swift` (добавить в конец файла)

**Interfaces:**
- Consumes: `JumpRoute`, `UnavailableReason` из Task 6.
- Produces:
  - `public enum JumpOutcome: Equatable, Sendable { case switchedToTab; case switchedToApplication; case automationDenied; case tabNotFound; case hostGone; case failed(String) }`
  - `public protocol JumpExecuting { func perform(_ route: JumpRoute, completion: @escaping (JumpOutcome) -> Void) }`
  - `public enum JumpMessages { public static func alert(for outcome: JumpOutcome) -> (title: String, body: String)?; public static func rowHint(for reason: UnavailableReason) -> String }`
- `alert(for:)` возвращает `nil` для успешных исходов (`switchedToTab`, `switchedToApplication`) — успех не требует сообщения.

- [ ] **Step 1: Write the failing test**

```swift
// Добавить в конец Tests/CodeCatCoreTests/SessionRouterTests.swift

extension SessionRouterTests {

    /// A successful jump speaks for itself — the user is already looking at the
    /// destination, an alert would be noise.
    func testSuccessfulOutcomesProduceNoAlert() {
        XCTAssertNil(JumpMessages.alert(for: .switchedToTab))
        XCTAssertNil(JumpMessages.alert(for: .switchedToApplication))
    }

    /// Every failure is reported: the spec forbids silent refusals.
    func testEveryFailingOutcomeHasARussianMessage() {
        let outcomes: [JumpOutcome] = [
            .automationDenied, .tabNotFound, .hostGone, .failed("boom"),
        ]
        for outcome in outcomes {
            guard let alert = JumpMessages.alert(for: outcome) else {
                return XCTFail("no message for \(outcome)")
            }
            XCTAssertFalse(alert.title.isEmpty)
            XCTAssertFalse(alert.body.isEmpty)
            XCTAssertTrue(alert.body.range(of: "\\p{Cyrillic}", options: .regularExpression) != nil,
                          "message for \(outcome) is not in Russian: \(alert.body)")
        }
    }

    /// Denied automation is not the end of the road: the executor still brings the
    /// app forward, and the message must say what happened and what to do.
    func testAutomationDeniedMentionsThePermissionAndTheFallback() {
        let alert = JumpMessages.alert(for: .automationDenied)
        XCTAssertTrue(alert!.body.contains("разрешение"))
        XCTAssertTrue(alert!.body.contains("вперёд"))
    }

    func testTabNotFoundMentionsTheClosedTab() {
        XCTAssertTrue(JumpMessages.alert(for: .tabNotFound)!.body.contains("вкладк"))
    }

    func testFailedCarriesTheUnderlyingDetail() {
        XCTAssertTrue(JumpMessages.alert(for: .failed("osascript error -1743"))!
            .body.contains("osascript error -1743"))
    }

    func testRowHintsExplainWhyAJumpIsUnavailable() {
        XCTAssertTrue(JumpMessages.rowHint(for: .noHostRecorded).contains("до CodeCat"))
        XCTAssertFalse(JumpMessages.rowHint(for: .hostGone).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SessionRouterTests`
Expected: FAIL — `cannot find 'JumpMessages' in scope`.

- [ ] **Step 3: Write minimal implementation**

Дописать в `Sources/CodeCatCore/SessionRouter.swift`:

```swift
/// What actually happened when a route was executed.
public enum JumpOutcome: Equatable, Sendable {
    case switchedToTab
    case switchedToApplication
    /// The user declined the one-time automation permission for the terminal.
    case automationDenied
    /// The tab is gone — it was closed since the session started.
    case tabNotFound
    case hostGone
    case failed(String)
}

/// Executing a route is the app layer's job (AppKit + AppleScript); the protocol is
/// what keeps `AppState`'s handling of outcomes testable, the same way `runner` does
/// for `LidSleepController`.
public protocol JumpExecuting {
    /// Never blocks the caller: the completion is invoked on the main queue.
    func perform(_ route: JumpRoute, completion: @escaping (JumpOutcome) -> Void)
}

/// User-facing Russian text for jump outcomes. Kept next to the outcomes so the
/// "no silent refusals" rule can be enforced by a test over every case.
public enum JumpMessages {

    /// The alert to show, or nil when the outcome needs none — a jump that worked
    /// already put the user where they wanted to be.
    public static func alert(for outcome: JumpOutcome) -> (title: String, body: String)? {
        switch outcome {
        case .switchedToTab, .switchedToApplication:
            return nil
        case .automationDenied:
            return ("Нет разрешения на автоматизацию",
                    "Чтобы попадать сразу во вкладку терминала, нужно разрешение на автоматизацию — его можно выдать в Системных настройках, «Конфиденциальность и безопасность» → «Автоматизация». Пока вывел приложение вперёд.")
        case .tabNotFound:
            return ("Вкладку найти не удалось",
                    "Похоже, вкладку с этой сессией уже закрыли. Вывел приложение вперёд.")
        case .hostGone:
            return ("Сессия закрыта",
                    "Приложение, в котором работала эта сессия, больше не запущено.")
        case .failed(let detail):
            return ("Не удалось перейти к сессии", detail)
        }
    }

    /// The small caption under a row that cannot be clicked.
    public static func rowHint(for reason: UnavailableReason) -> String {
        switch reason {
        case .noHostRecorded:
            return "переход недоступен — сессия запущена до CodeCat"
        case .hostGone:
            return "переход недоступен — приложение сессии закрыто"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter SessionRouterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatCore/SessionRouter.swift Tests/CodeCatCoreTests/SessionRouterTests.swift
git commit -m "feat: define jump outcomes and their user-facing messages"
```

---

### Task 9: Реальный исполнитель маршрута

**Files:**
- Create: `Sources/CodeCatApp/SystemJumpExecutor.swift`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Consumes: `JumpRoute`, `JumpOutcome`, `JumpExecuting`, `TerminalJumpScript`, `SessionRouter.isProcessRunning`.
- Produces: `final class SystemJumpExecutor: JumpExecuting` (internal, только для `AppState`).

- [ ] **Step 1: Записать проверку до реализации**

Юнит-тестов у слоя AppKit нет (граница проекта). Проверка — ручная, в Task 11. Перед правкой убедиться, что сборка зелёная:

Run: `swift build && swift test`
Expected: build succeeded, все тесты проходят.

- [ ] **Step 2: Добавить объяснение разрешения в Info.plist**

Без `NSAppleEventsUsageDescription` macOS не покажет запрос на автоматизацию, и `NSAppleScript` вернёт ошибку вместо диалога. Добавить в `Resources/Info.plist` перед закрывающим `</dict>`:

```xml
    <key>NSAppleEventsUsageDescription</key><string>CodeCat переключает вас во вкладку терминала, где ждёт ответа агент Claude Code.</string>
```

- [ ] **Step 3: Write minimal implementation**

```swift
import AppKit
import CodeCatCore

/// Executes a `JumpRoute` for real: `NSRunningApplication` for bringing an app
/// forward (no permission needed) and `NSAppleScript` for selecting a terminal tab
/// (a one-time automation permission, prompted by macOS on first use).
///
/// `NSAppleScript` is run on a private serial queue — it is not thread-safe and can
/// block for as long as the target app takes to answer, which must never happen on
/// the main thread while the panel is open. The completion always lands back on the
/// main queue.
final class SystemJumpExecutor: JumpExecuting {
    private let queue = DispatchQueue(label: "com.codecat.jump")

    func perform(_ route: JumpRoute, completion: @escaping (JumpOutcome) -> Void) {
        switch route {
        case .unavailable:
            finish(.hostGone, completion)
        case .application(let pid, _):
            finish(activate(pid: pid) ? .switchedToApplication : .hostGone, completion)
        case .terminalTab(let bundleID, _, let pid, let tty):
            guard let source = TerminalJumpScript.script(bundleID: bundleID, tty: tty) else {
                finish(activate(pid: pid) ? .switchedToApplication : .hostGone, completion)
                return
            }
            queue.async { [weak self] in
                guard let self else { return }
                let outcome = self.runTabScript(source)
                // Every non-terminal outcome still owes the user a destination: fall
                // back to bringing the app forward, then report what really happened.
                switch outcome {
                case .automationDenied, .tabNotFound, .failed:
                    _ = self.activate(pid: pid)
                default:
                    break
                }
                self.finish(outcome, completion)
            }
        }
    }

    private func finish(_ outcome: JumpOutcome, _ completion: @escaping (JumpOutcome) -> Void) {
        DispatchQueue.main.async { completion(outcome) }
    }

    private func activate(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate(options: [.activateAllWindows])
    }

    /// Runs the tab-selection script and classifies the result.
    ///
    /// A refused automation permission surfaces as AppleScript error -1743
    /// (`errAEEventNotPermitted`); -600 (`procNotFound`) means the target app went
    /// away between routing and execution.
    private func runTabScript(_ source: String) -> JumpOutcome {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return .failed("не удалось собрать AppleScript")
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            switch code {
            case -1743, -1744:
                return .automationDenied
            case -600, -609:
                return .hostGone
            default:
                let message = (error[NSAppleScript.errorMessage] as? String) ?? "код \(code)"
                return .failed("AppleScript: \(message)")
            }
        }
        switch result.stringValue {
        case TerminalJumpScript.successMarker: return .switchedToTab
        case TerminalJumpScript.notFoundMarker: return .tabNotFound
        default: return .failed("неожиданный ответ терминала")
        }
    }
}
```

- [ ] **Step 4: Verify it builds**

Run: `swift build && swift test`
Expected: build succeeded, все тесты по-прежнему зелёные.

- [ ] **Step 5: Commit**

```bash
git add Sources/CodeCatApp/SystemJumpExecutor.swift Resources/Info.plist
git commit -m "feat: execute jump routes through AppKit and AppleScript"
```

---

### Task 10: Кликабельные строки сессий

**Files:**
- Modify: `Sources/CodeCatApp/AppState.swift`
- Modify: `Sources/CodeCatApp/DetailsPanelView.swift`

**Interfaces:**
- Consumes: `SessionRouter.route(for:isHostRunning:)`, `SessionRouter.isProcessRunning`, `JumpMessages`, `SystemJumpExecutor`.
- Produces:
  - в `AppState`: `let jumpExecutor: JumpExecuting` (инициализируется `SystemJumpExecutor()`), `func route(for session: Session) -> JumpRoute`, `func jump(to session: Session)`.
  - в `DetailsPanelView`: клик по строке вызывает `appState.jump(to:)` и закрывает панель через `onJump` — замыкание, которое `OverlayController` передаёт при создании панели.

- [ ] **Step 1: Записать проверку до реализации**

Run: `swift build && swift test`
Expected: build succeeded, тесты зелёные.

- [ ] **Step 2: Добавить точку входа в AppState**

В `Sources/CodeCatApp/AppState.swift` добавить свойство рядом с `let lidController: LidSleepController`:

```swift
    let jumpExecutor: JumpExecuting
```

в `init()` перед `powerManager = PowerManager(...)`:

```swift
        jumpExecutor = SystemJumpExecutor()
```

и в конец класса:

```swift
    // MARK: - Jumping to a session

    /// Where a click on this session's row would send the user. Cheap enough to call
    /// during a view body: one `kill(pid, 0)` per visible row.
    func route(for session: Session) -> JumpRoute {
        SessionRouter.route(for: session, isHostRunning: SessionRouter.isProcessRunning)
    }

    /// Executes the jump and reports the outcome. Successful jumps say nothing — the
    /// user is already looking at the destination; everything else gets an alert, so
    /// there are no silent refusals.
    func jump(to session: Session) {
        let route = route(for: session)
        if case .unavailable = route { return }
        jumpExecutor.perform(route) { outcome in
            guard let message = JumpMessages.alert(for: outcome) else { return }
            let alert = NSAlert()
            alert.messageText = message.title
            alert.informativeText = message.body
            alert.runModal()
        }
    }
```

- [ ] **Step 3: Сделать строки кликабельными**

В `Sources/CodeCatApp/DetailsPanelView.swift` добавить свойство рядом с `@ObservedObject var appState: AppState`:

```swift
    /// Called after a jump is started, so the panel can close itself: the user asked
    /// to be somewhere else.
    var onJump: () -> Void = {}
```

и заменить тело `ForEach(appState.store.ordered)` на:

```swift
                ForEach(appState.store.ordered) { session in
                    sessionRow(session)
                }
```

добавив в конец структуры:

```swift
    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        let route = appState.route(for: session)
        let unavailableReason: UnavailableReason? = {
            if case .unavailable(let reason) = route { return reason }
            return nil
        }()

        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color(for: session.status))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.projectName).font(.system(size: 12, weight: .medium))
                Text("\(label(for: session.status)) · \(session.activityDescription)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("длится \(duration(session))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if let reason = unavailableReason {
                    Text(JumpMessages.rowHint(for: reason))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovered == session.id && unavailableReason == nil
                      ? Color.primary.opacity(0.08) : Color.clear))
        .onHover { inside in
            guard unavailableReason == nil else { return }
            hovered = inside ? session.id : (hovered == session.id ? nil : hovered)
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .onTapGesture {
            guard unavailableReason == nil else { return }
            appState.jump(to: session)
            onJump()
        }
    }
```

и объявить состояние наведения рядом с `onJump`:

```swift
    @State private var hovered: String?
```

Импорт `AppKit` в этом файле нужен для `NSCursor` — добавить `import AppKit` в начало.

- [ ] **Step 4: Прокинуть закрытие панели**

В `Sources/CodeCatApp/OverlayPanel.swift`, в `makeDetailsPanel()`, заменить строку создания hosting view на:

```swift
        panel.contentView = NSHostingView(rootView: DetailsPanelView(
            appState: appState,
            onJump: { [weak self] in self?.hideDetails() }))
```

Проверить, что `resizeDetailsToFitContent()` по-прежнему компилируется: он приводит `panel.contentView` к `NSHostingView<DetailsPanelView>`, тип не изменился.

- [ ] **Step 5: Verify and commit**

Run: `swift build && swift test`
Expected: build succeeded, все тесты зелёные.

```bash
git add Sources/CodeCatApp/AppState.swift Sources/CodeCatApp/DetailsPanelView.swift Sources/CodeCatApp/OverlayPanel.swift
git commit -m "feat: make session rows jump to where the session lives"
```

---

### Task 11: Проверка на живой машине и документация

**Files:**
- Modify: `README.md`
- Modify: `docs/HANDOFF.md`

- [ ] **Step 1: Собрать и установить**

Run:
```bash
make app && pkill -x CodeCat; rm -rf /Applications/CodeCat.app && cp -R dist/CodeCat.app /Applications/ && open -a /Applications/CodeCat.app
```
Expected: приложение запускается, котик на месте.

- [ ] **Step 2: Проверить сбор маршрута**

Запустить `claude` в Terminal.app в любом проекте, дождаться появления сессии в панели деталей (клик по котику).
Expected: у строки сессии **нет** подписи «переход недоступен», при наведении строка подсвечивается.

- [ ] **Step 3: Проверить переход во вкладку**

Кликнуть по строке сессии, запущенной в Terminal.app.
Expected: macOS один раз спрашивает разрешение на автоматизацию Terminal; после «Разрешить» — переключение ровно в ту вкладку, панель закрывается. Если отказать — приложение всё равно выводится вперёд и показывается сообщение про разрешение.

- [ ] **Step 4: Проверить переход к десктопному Claude**

Кликнуть по строке сессии, запущенной в приложении Claude.
Expected: приложение Claude выходит на передний план, панель закрывается, сообщений нет.

- [ ] **Step 5: Проверить недоступный переход**

Найти сессию, о которой знает только вотчер транскриптов (например, запущенную до старта CodeCat).
Expected: подпись «переход недоступен — сессия запущена до CodeCat», подсветки при наведении нет, клик ничего не делает.

- [ ] **Step 6: Обновить документацию и закоммитить**

В `README.md` добавить в раздел о панели деталей абзац о том, что клик по строке сессии переключает к ней, что для вкладок терминала при первом использовании нужно разрешение на автоматизацию, и что сессии, о которых знает только вотчер транскриптов, перехода не имеют.

В `docs/HANDOFF.md` отметить фичу как реализованную.

```bash
git add README.md docs/HANDOFF.md
git commit -m "docs: document jumping to a waiting session"
```

---

## Self-Review

**Покрытие спека:**

| Требование спека | Задача |
|---|---|
| Хук добавляет `host_pid`, `host_bundle_path`, `tty` | 3, 4 (плюс `host_bundle_id`, см. уточнения) |
| Обход предков и TTY через `sysctl`, без подпроцессов | 1, 2 |
| Битый JSON → пересылка дословно | 3 |
| Данные собираются на каждом событии | 4 |
| Новые опциональные поля в `HookEvent` и `Session` | 5 |
| `SessionRouter`, `JumpRoute`, `UnavailableReason` | 6 |
| Опознание терминалов по bundle identifier списком-константой | 6 |
| Протокол `JumpExecuting`, `JumpOutcome` | 8 |
| `automationDenied`/`tabNotFound` не терминальны, запасной вариант | 9 |
| AppleScript с экранированием, как в `LidHelperInstall` | 7 |
| `NSRunningApplication.activate()` для приложения | 9 |
| Кликабельные строки, подсветка, курсор, закрытие панели | 10 |
| Подпись под недоступной строкой | 8 (текст), 10 (показ) |
| Клик по котику не меняется | не трогаем `CatHostingView` |
| Все сообщения по-русски, без молчаливых отказов | 8 (тест на каждый исход) |
| Исполнитель не блокирует главный поток | 9 |
| Тесты: маршруты, обход предков, экранирование, разбор payload'а, исходы | 1, 3, 5, 6, 7, 8 |

**За скобками спека и здесь:** наведение на окно десктопного Claude, глобальная горячая клавиша, переход по клику на котика, терминалы помимо Terminal.app и iTerm2.
