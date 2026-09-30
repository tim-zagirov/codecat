import SwiftUI
import CodeCatCore

/// The Settings window's panes, in sidebar order (spec §8).
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, alerts, power, cat, claude
    var id: Self { self }

    var title: String {
        switch self {
        case .general: return L10n.t("settings.pane.general", "General")
        case .alerts: return L10n.t("settings.pane.alerts", "Alerts")
        case .power: return L10n.t("settings.pane.power", "Power")
        case .cat: return L10n.t("settings.pane.cat", "Cat")
        case .claude: return L10n.t("settings.pane.claude", "Claude Code")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .alerts: return "bell.badge"
        case .power: return "bolt"
        case .cat: return "cat"
        case .claude: return "terminal"
        }
    }

    /// `--demo-settings=<name>`.
    static func named(_ name: String) -> SettingsPane? { SettingsPane(rawValue: name) }
}

/// The selected pane, shared by the window controller (which opens on a pane) and the
/// sidebar.
final class SettingsSelection: ObservableObject {
    @Published var pane: SettingsPane = .general
}

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding<SettingsPane?>(
                get: { selection.pane }, set: { if let pane = $0 { selection.pane = pane } })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            // `.navigationSplitViewColumnWidth` is only an ideal, and inside this
            // window's `NSHostingView` (`sizingOptions = []`, a fixed-size window —
            // see `SettingsWindowController.makeWindow()`) it was never honoured at
            // all: measured on a capture, the sidebar came out ~139 pt wide against
            // Figma's 196 pt regardless of what was asked for here. A `.frame`
            // directly on the column's content is what the split view actually
            // measures against in that situation.
            .frame(width: 196)
            .navigationSplitViewColumnWidth(196)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane(selection.pane)
        }
        .frame(width: 720, height: 520)
    }

    @ViewBuilder
    private func pane(_ pane: SettingsPane) -> some View {
        switch pane {
        case .general: GeneralPane(appState: appState)
        case .alerts: AlertsPane(appState: appState)
        case .power: PowerPane(appState: appState)
        case .cat: CatPane(appState: appState)
        case .claude: ClaudeCodePane(appState: appState)
        }
    }
}

/// A pane: its title as Figma sets it (20 pt bold, 28 pt in, 20 pt down), then the
/// grouped form.
struct SettingsPaneScaffold<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .padding(.horizontal, 28)
                .padding(.top, 20)
            Form { content }
                .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A row's label with its one sentence of help under it (Figma 05: 13 regular, 11
/// secondary).
struct SettingsLabel: View {
    let title: String
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A switch row.
struct SettingsToggle: View {
    let title: String
    var help: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) { SettingsLabel(title: title, help: help) }
            .toggleStyle(.switch)
    }
}
