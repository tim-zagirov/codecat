import ServiceManagement
import CodeCatCore

/// Open at login (spec §8, General). Only an assembled `.app` can register; from
/// `swift run` the call fails, the failure is logged, and the switch reads the real
/// state back and returns to off.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool, log: DiagnosticLog) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.write("login item: \(on ? "register" : "unregister") failed — \(error)")
        }
    }
}
