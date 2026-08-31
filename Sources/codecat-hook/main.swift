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
    // Идём от РОДИТЕЛЯ, а не от себя: сам хук лежит внутри CodeCat.app, и старт с
    // getpid() записал бы владельцем сессии сам CodeCat всякий раз, когда выше по
    // цепочке нет ни одного .app (tmux, screen, ssh, нативно установленный claude).
    // По спецификации host_pid — первый ПРЕДОК внутри .app-бандла; сам хук предком
    // себе не является. Плюс подстраховка: свой бандл исключаем в любом случае.
    let parent = getppid()
    let host = ProcessTree.host(startingAt: parent, provider: tree,
                                excludingBundlePath: Bundle.main.bundlePath)
    let fields = HookPayload.RouteFields(
        hostPID: host?.pid,
        hostBundlePath: host?.bundlePath,
        // Чтение Info.plist бандла — одно обращение к маленькому файлу; опознание
        // терминала идёт по идентификатору, а не по имени файла бандла.
        hostBundleID: host.flatMap { Bundle(path: $0.bundlePath)?.bundleIdentifier },
        // А вот tty ищем от себя: контролирующий терминал наследуется, у хука он
        // тот же, что у родителя, и старт от getpid() переживает случай, когда хук
        // осиротел (getppid() == 1) — иначе сессия молча потеряла бы вкладку.
        tty: ProcessTree.tty(startingAt: getpid(), provider: tree),
        // Процесс самой сессии — ближайший предок с именем `claude` (обычно через
        // `sh -c`, которым Claude Code запускает хук). Ищем от родителя по той же
        // причине, что и host: сам хук предком себе не является. По этому pid
        // приложение потом точно знает, жива ли сессия, вместо того чтобы гадать по
        // общему числу процессов `claude` в системе.
        agentPID: ProcessTree.agent(startingAt: parent, provider: tree))
    HookSocketClient.send(HookPayload.enriched(input, with: fields), to: CodeCatPaths.socketURL)
}
exit(0)
