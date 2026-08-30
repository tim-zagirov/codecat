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
