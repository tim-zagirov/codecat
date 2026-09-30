import SwiftUI
import AppKit
import CodeCatCore

/// Spec §8, Cat: the chosen skin in all five states, the grid to choose from, the
/// Codex pets folder, and the credits.
@MainActor
struct CatPane: View {
    @ObservedObject var appState: AppState
    @State private var creditsExpanded = false

    var body: some View {
        SettingsPaneScaffold(title: SettingsPane.cat.title) {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(appState.skin.name).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text(appState.skin.author).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    CatStage(skin: appState.skin)
                }
            }
            Section(L10n.t("skins.title", "Skins")) {
                SkinGrid(appState: appState)
            }
            Section {
                LabeledContent {
                    Button(L10n.t("settings.cat.pets.open", "Open folder")) {
                        CodeCatPaths.ensureAppSupportExists()
                        NSWorkspace.shared.open(CodeCatPaths.petsRoot)
                    }
                } label: {
                    SettingsLabel(title: L10n.t("settings.cat.pets", "Codex pets"),
                                  help: L10n.t("settings.cat.pets.help",
                                               "Drop a pet folder here or into ~/.codex/pets and it appears in the grid."))
                }
            }
            Section {
                DisclosureGroup(isExpanded: $creditsExpanded) {
                    CreditsList(skins: appState.availableSkins)
                } label: {
                    Text(L10n.t("skins.credits", "Artists and licences"))
                }
            }
        }
        // `rescanPets` publishes `registry`; publishing from inside `onAppear`'s own
        // update pass is what SwiftUI warns about, so it waits for the next turn.
        .onAppear { DispatchQueue.main.async { appState.rescanPets() } }
    }
}

/// The chosen skin in every state, on the island's black, at the island's size — what
/// the user will actually see (Figma 05 "Stage").
@MainActor
struct CatStage: View {
    let skin: MascotSkin

    private static let states: [(AggregateStatus, MascotTone?, String)] = [
        (.sleeping, nil, L10n.t("settings.cat.state.asleep", "Asleep")),
        (.working(1), .working, L10n.t("settings.cat.state.working", "Working")),
        (.waiting(1), .waiting, L10n.t("settings.cat.state.waiting", "Waiting")),
        (.done, .done, L10n.t("settings.cat.state.done", "Done")),
        (.problem, .problem, L10n.t("settings.cat.state.crashed", "Crashed")),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.states.enumerated()), id: \.offset) { _, state in
                VStack(spacing: 8) {
                    pose(state.0)
                    HStack(spacing: 5) {
                        if let tone = state.1 {
                            Circle().fill(ToneColor.island(tone)).frame(width: 6, height: 6)
                        }
                        Text(state.2).font(.system(size: 11)).foregroundStyle(IslandPalette.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black))
    }

    @ViewBuilder
    private func pose(_ status: AggregateStatus) -> some View {
        if let loaded = SpriteSheetStore.shared.load(skin) {
            SpriteMascotView(loaded: loaded, status: status,
                             indicator: MascotIndicator(tone: .sleeping, count: 0, crashedMarker: false),
                             maxFPS: 4, showsBadge: false,
                             drawingSize: loaded.drawingSize(targetHeight: SpriteScale.islandTargetHeight,
                                                             maxWidth: SpriteScale.islandMaxWidth),
                             canvasSize: CGSize(width: 60, height: 32))
        } else {
            Color.clear.frame(width: 60, height: 32)
        }
    }
}

/// Every installed skin, four to a row, each playing its working walk (spec §8).
@MainActor
struct SkinGrid: View {
    @ObservedObject var appState: AppState
    @State private var hovered: String?

    private let columns = Array(repeating: GridItem(.fixed(106), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(appState.availableSkins) { skin in
                cell(skin)
            }
        }
    }

    private func cell(_ skin: MascotSkin) -> some View {
        let selected = skin.id == appState.skinID
        return VStack(spacing: 6) {
            preview(skin)
                .scaleEffect(48 / MascotLayout.canvasSize)
                .frame(width: 48, height: 48)
            Text(skin.name).font(.system(size: 11)).lineLimit(1)
        }
        .frame(width: 106, height: 85)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(selected || hovered == skin.id ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        // `primary`, not the spec's white: white is invisible on the light form
        // (decision 6); `primary` is white in dark mode, where Figma drew it.
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(selected ? Color.primary : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? skin.id : (hovered == skin.id ? nil : hovered) }
        .onTapGesture { appState.skinID = skin.id }
        .help(skin.name)
        .accessibilityLabel(skin.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func preview(_ skin: MascotSkin) -> some View {
        if let loaded = SpriteSheetStore.shared.load(skin) {
            SpriteMascotView(loaded: loaded, status: .working(1),
                             indicator: MascotIndicator(tone: .sleeping, count: 0, crashedMarker: false),
                             maxFPS: 4, showsBadge: false)
        } else {
            Color.clear.frame(width: MascotLayout.canvasSize, height: MascotLayout.canvasSize)
        }
    }
}

/// Every credited artist: one row per built-in author (six LuizMelo cats share one
/// author and one licence — repeating them six times would bury the one line that is
/// an actual obligation: mxmaze is CC BY 4.0), then one per imported pet. Drawn with
/// system colours since the Settings window sits on system materials, unlike the
/// island's and panel's own `MenuStyle` greys.
@MainActor
struct CreditsList: View {
    let skins: [MascotSkin]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(creditRows) { credit in
                VStack(alignment: .leading, spacing: 1) {
                    Text(credit.heading).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    if let note = credit.note {
                        // Third-party text — a pet's own description — must not be
                        // able to grow the pane without bound.
                        Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
                            .lineLimit(3)
                    }
                    Text(credit.terms).font(.system(size: 10)).foregroundStyle(.tertiary)
                    if credit.isFolder {
                        // An imported pet shows just the folder's own name; the full
                        // `~/.codex/pets/...` path lives in the tooltip so the line
                        // stays short but the provenance is still one hover away.
                        Text(L10n.f("skins.imported.from", "From %@",
                                    (credit.source as NSString).lastPathComponent))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                            .help(credit.source)
                    } else if let url = URL(string: credit.source) {
                        // `URL(string:)` is not force-unwrapped: every `sourceURL` in
                        // `MascotSkins` is a valid literal today, but this view has no
                        // way to enforce that going forward, and a malformed URL must
                        // read as a missing link, not crash the pane.
                        Link(credit.source, destination: url).font(.system(size: 10))
                    } else {
                        Text(credit.source).font(.system(size: 10))
                    }
                }
            }
        }
    }

    /// What one credits row shows. Built-in packs are grouped by author (six
    /// LuizMelo cats are one line); imported pets are one row each, with the pet's
    /// own description and the folder it came from instead of a web link.
    private struct Credit: Identifiable {
        let id: String
        let heading: String
        let terms: String
        let note: String?
        /// A link for the built-ins, a folder path for imported pets.
        let source: String
        let isFolder: Bool
    }

    private var creditRows: [Credit] {
        var seen = Set<String>()
        var result: [Credit] = []
        for skin in skins {
            if SkinRegistry.isImported(skin) {
                result.append(Credit(id: skin.id, heading: skin.name,
                                     terms: licenseText(skin.license), note: skin.note,
                                     source: (skin.sourceURL as NSString).abbreviatingWithTildeInPath,
                                     isFolder: true))
            } else if seen.insert(skin.author).inserted {
                result.append(Credit(id: skin.author, heading: skin.author,
                                     terms: licenseText(skin.license), note: nil,
                                     source: skin.sourceURL, isFolder: false))
            }
        }
        return result
    }

    private func licenseText(_ license: SkinLicense) -> String {
        switch license {
        case .cc0: return L10n.t("license.cc0", "CC0 1.0 — public domain")
        // The full attribution string (e.g. "Maze.Bit.Boutique (mxmaze), CC BY
        // 4.0") is deliberately not printed here: the author name it repeats is
        // already the heading directly above this line (`credit.heading`), so
        // showing it again would print "Maze.Bit.Boutique (mxmaze)" twice for the
        // same pack. Together the two lines still name both the author and "CC BY
        // 4.0", which is what the licence actually requires.
        case .ccBy4: return "CC BY 4.0"
        case .authorTerms(let summary): return summary
        }
    }
}
