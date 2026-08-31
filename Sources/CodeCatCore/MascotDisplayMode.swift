import Foundation

/// Способ показывать маскота на экране. Режимы взаимоисключающие: одновременно
/// на экране всегда ровно один.
public enum MascotDisplayMode: String, CaseIterable, Sendable {
    /// Плавающее окно, которое пользователь таскает мышью. Поведение с MVP.
    case floating
    /// Чёрная плашка вокруг физического выреза встроенного экрана.
    case island

    /// Установка новой версии не должна менять вид сама по себе.
    public static let `default` = MascotDisplayMode.floating

    /// Читает значение из настроек. Всё, чего не знаем, — режим по умолчанию:
    /// в `UserDefaults` может лежать строка от старой или будущей версии.
    public static func mode(withID id: String?) -> MascotDisplayMode {
        guard let id, let mode = MascotDisplayMode(rawValue: id) else { return .default }
        return mode
    }

    /// Подпись в интерфейсе.
    public var title: String {
        switch self {
        case .floating: return "Кот"
        case .island: return "Остров"
        }
    }
}
