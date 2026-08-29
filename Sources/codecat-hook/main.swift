import Foundation
import CodeCatCore

// Claude Code передаёт JSON события на stdin. Пересылаем как есть в сокет
// приложения. Приложение не запущено / любая ошибка → тихий выход 0:
// хук не имеет права мешать работе Claude Code.
let input = FileHandle.standardInput.readDataToEndOfFile()
if !input.isEmpty {
    HookSocketClient.send(input, to: CodeCatPaths.socketURL)
}
exit(0)
