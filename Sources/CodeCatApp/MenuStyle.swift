import SwiftUI

/// Оформление меню. Один и тот же список сессий, та же сетка обликов и те же
/// тумблеры показываются на двух совершенно разных поверхностях, и правила
/// читаемости у них противоположные.
///
/// Панель плавающего режима лежит на `.regularMaterial`, то есть на системном
/// фоне: там уместны системные семантические цвета (`.secondary`, `.tertiary`,
/// `Color.primary`, акцентный синий), которые сами подстраиваются под светлую и
/// тёмную тему.
///
/// Меню острова лежит на **чистом чёрном** — не на системном фоне, а на цвете,
/// подобранном под физический вырез экрана. Системная семантика там врёт:
/// `.secondary` считает, что знает фон, и на светлой теме выдаёт почти чёрный
/// текст на чёрном. Поэтому у острова уровни белого заданы числами, цвет живёт
/// только в точках статуса, а выделение — белой рамкой, потому что системный
/// синий уже занят статусом «закончил».
///
/// Стиль передаётся через `Environment`, а не параметром в каждый вид: он нужен
/// вглубь, до строки сессии и ячейки облика, и протаскивать его руками через все
/// уровни — значит гарантированно где-то забыть.
struct MenuStyle {

    /// Как раскладывается строка сессии.
    enum RowLayout {
        /// Три строки: проект / статус · активность / длительность. Вид панели
        /// плавающего режима, каким он был с самого начала.
        case threeLine
        /// Две строки: проект, под ним статус · активность слева и длительность,
        /// прижатая вправо. Длительности выстраиваются в колонку у правого края —
        /// это и есть сетка, которая держит список.
        case twoLine
    }

    var rowLayout: RowLayout

    // MARK: - Текст

    /// То, ради чего смотрят: имя проекта, число, подпись тумблера.
    var primary: Color
    /// Пояснение к нему: статус, активность.
    var secondary: Color
    /// Справка: длительность, подсказки, заголовки секций, недоступная строка.
    var tertiary: Color

    // MARK: - Поверхности

    /// Строка сессии под курсором.
    var rowHover: Color
    var rowRadius: CGFloat
    /// Подложка ячейки облика и её состояния.
    var cellFill: Color
    var cellHover: Color
    var cellSelected: Color
    var cellRadius: CGFloat
    /// Размер ячейки облика и зазор между ячейками. Ячейка шире, чем высока: коты
    /// в наборах четвероногие и низкие, и в квадрате они висят в пустоте.
    var cellSize: CGSize
    var cellSpacing: CGFloat
    /// Обводка выбранного облика.
    var selectionBorder: Color
    var selectionBorderWidth: CGFloat
    /// Толщина и цвет разделителя. `nil` — использовать системный `Divider()`.
    var separator: Color?
    /// Цвет включённого тумблера. `nil` — системный акцентный.
    var toggleTint: Color?
    /// Растягивать ли строку тумблера на всю ширину. Без этого `Toggle` ужимается
    /// по своей подписи, и переключатели встают лесенкой — каждый там, где кончился
    /// его текст. Колонка справа собирает их в одну вертикаль.
    var togglesFillWidth: Bool

    // MARK: - Отступы

    /// Поля формы.
    var padding: CGFloat
    /// Расстояние между смысловыми блоками.
    var blockSpacing: CGFloat
    /// Расстояние между строками текста внутри блока.
    var lineSpacing: CGFloat

    /// Панель плавающего режима. Значения переписаны один в один с того, как она
    /// выглядела до появления стилей: этот пресет обязан быть тождественным
    /// прежнему виду, иначе смысл разделения теряется.
    static let panel = MenuStyle(
        rowLayout: .threeLine,
        primary: .primary,
        secondary: .secondary,
        tertiary: Color.primary.opacity(0.4),
        rowHover: Color.primary.opacity(0.08),
        rowRadius: 6,
        cellFill: Color.primary.opacity(0.05),
        cellHover: Color.primary.opacity(0.05),
        cellSelected: Color.primary.opacity(0.05),
        cellRadius: 6,
        cellSize: CGSize(width: 34, height: 34),
        cellSpacing: 8,
        selectionBorder: .accentColor,
        selectionBorderWidth: 2,
        separator: nil,
        toggleTint: nil,
        togglesFillWidth: false,
        padding: 14,
        blockSpacing: 10,
        lineSpacing: 2)

    /// Меню острова. Уровни белого заданы числами: фон здесь не системный, и
    /// системная семантика о нём ничего не знает.
    static let island = MenuStyle(
        rowLayout: .twoLine,
        primary: .white,
        secondary: Color.white.opacity(0.62),
        tertiary: Color.white.opacity(0.38),
        rowHover: Color.white.opacity(0.08),
        rowRadius: 6,
        cellFill: Color.white.opacity(0.06),
        cellHover: Color.white.opacity(0.10),
        cellSelected: Color.white.opacity(0.16),
        cellRadius: 8,
        cellSize: CGSize(width: 60, height: 40),
        cellSpacing: 6,
        selectionBorder: .white,
        selectionBorderWidth: 1,
        separator: Color.white.opacity(0.12),
        toggleTint: .white,
        togglesFillWidth: true,
        padding: 12,
        blockSpacing: 8,
        lineSpacing: 4)
}

private struct MenuStyleKey: EnvironmentKey {
    /// Панель плавающего режима — исходная поверхность проекта, поэтому она же и
    /// значение по умолчанию: вид, не объявивший стиль, выглядит как раньше.
    static let defaultValue = MenuStyle.panel
}

extension EnvironmentValues {
    var menuStyle: MenuStyle {
        get { self[MenuStyleKey.self] }
        set { self[MenuStyleKey.self] = newValue }
    }
}

/// Разделитель, знающий про стиль: у панели — системный `Divider()`, у острова —
/// линия заданного цвета во всю ширину формы. Разделитель во всю ширину читается
/// как членение плашки, а вставленный с отступами — как украшение списка.
struct MenuSeparator: View {
    @Environment(\.menuStyle) private var style

    var body: some View {
        if let color = style.separator {
            Rectangle()
                .fill(color)
                .frame(height: 1)
                .padding(.horizontal, -style.padding)
        } else {
            Divider()
        }
    }
}

/// Заголовок смысловой секции меню. У панели его не было вовсе — там секции
/// разделялись только линиями, — поэтому вид ничего не рисует, пока стиль не
/// попросит: `title` показывается только там, где заголовки предусмотрены.
struct MenuSectionHeader: View {
    let title: String
    @Environment(\.menuStyle) private var style

    var body: some View {
        if style.separator != nil {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(style.tertiary)
        }
    }
}
