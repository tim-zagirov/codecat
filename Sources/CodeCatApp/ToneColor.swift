import SwiftUI
import CodeCatCore

/// The four state colours, written once. The island glow, the island dots, the
/// floating badge, the session-row dots and the details panel all read from
/// here, so a green on one surface is the same green everywhere — three copies
/// of this switch used to exist and only agreed by discipline.
enum ToneColor {
    static func color(for tone: MascotTone) -> Color {
        switch tone {
        case .working: return .green
        case .waiting: return .orange
        case .done: return .blue
        case .problem: return .red
        case .sleeping: return Color.white.opacity(0.35)
        }
    }
}
