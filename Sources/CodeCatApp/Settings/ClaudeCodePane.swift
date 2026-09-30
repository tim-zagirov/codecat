import SwiftUI
import AppKit
import CodeCatCore

/// Spec §8, Claude Code: whether the hooks are in, what they listen to, and the ways
/// out — the file, removal and the log.
struct ClaudeCodePane: View {
    @ObservedObject var appState: AppState

    var body: some View {
        SettingsPaneScaffold(title: SettingsPane.claude.title) {
            Section {
                if appState.hooksInstalled {
                    // The age of the last event changes every second while nothing else does.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        SettingsStatusRow(tone: .working, title: L10n.t("settings.claude.connected", "Connected"),
                                          detail: connectedDetail(now: context.date))
                    }
                } else {
                    HStack {
                        SettingsStatusRow(tone: .sleeping,
                                          title: L10n.t("settings.claude.disconnected", "Not connected"),
                                          detail: L10n.t("settings.claude.disconnected.detail",
                                                         "CodeCat learns about sessions late — from their transcripts."))
                        Spacer(minLength: 12)
                        Button(L10n.t("onboarding.connect", "Connect…")) { appState.installHooksIfNeeded() }
                    }
                }
            }
            Section {
                ChipFlow(spacing: 6) {
                    ForEach(HooksInstaller.events, id: \.self) { event in
                        Text(event)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 8)
                            .frame(height: 20)
                            .background(Capsule().fill(.quaternary))
                    }
                }
            } header: {
                Text(L10n.t("settings.claude.events", "What CodeCat listens to"))
            } footer: {
                Text(L10n.t("settings.claude.events.footer",
                            "Merged next to your own hooks; nothing else in the file is touched."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack(spacing: 8) {
                    Button(L10n.t("settings.claude.show.file", "Show settings.json")) {
                        NSWorkspace.shared.activateFileViewerSelecting([CodeCatPaths.claudeSettings])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: CodeCatPaths.claudeSettings.path))
                    if appState.hooksInstalled {
                        Button(L10n.t("settings.claude.remove", "Remove hooks…")) { appState.removeHooks() }
                    }
                }
            }
            Section(L10n.t("settings.section.diagnostics", "Diagnostics")) {
                LabeledContent {
                    Button(L10n.t("settings.claude.open.log", "Open log")) { NSWorkspace.shared.open(CodeCatPaths.logURL) }
                } label: {
                    SettingsLabel(title: L10n.t("settings.claude.log", "Log"),
                                  help: (CodeCatPaths.logURL.path as NSString).abbreviatingWithTildeInPath)
                }
            }
        }
    }

    private func connectedDetail(now: Date) -> String {
        let hooks = L10n.f("settings.claude.hooks", "%d hooks in %@", HooksInstaller.events.count,
                           (CodeCatPaths.claudeSettings.path as NSString).abbreviatingWithTildeInPath)
        guard let last = appState.lastHookEventAt else {
            return hooks + " · " + L10n.t("settings.claude.no.events", "no events yet")
        }
        return hooks + " · " + L10n.f("settings.claude.last", "last event %@ ago", Self.age(now.timeIntervalSince(last)))
    }

    /// "4 s", "3 min", "2 h" — the pane's one relative time.
    static func age(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return L10n.f("settings.claude.age.seconds", "%d s", s) }
        if s < 3600 { return L10n.f("settings.claude.age.minutes", "%d min", s / 60) }
        return L10n.f("settings.claude.age.hours", "%d h", s / 3600)
    }
}
