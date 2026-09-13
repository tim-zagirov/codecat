import SwiftUI
import CodeCatCore

/// The skin picker: a grid of live previews plus the credits disclosure.
///
/// Eight previews at 36pt would not fit the 290pt panel in one row, and horizontal
/// scrolling inside a popover that closes on any click outside it is a way to miss,
/// not a way to choose — hence a 4x2 grid that fits whole. Fits with room to spare:
/// 4 columns x 34pt + 3 gaps x 8pt = 160pt, against 290 - 2x14 = 262pt of usable
/// width inside the panel's own padding.
@MainActor
struct SkinPickerView: View {
    @ObservedObject var appState: AppState

    /// Previews are small and there are eight of them animating at once, so their
    /// frame rate is capped well below the mascot's own.
    private let previewFPS: Double = 4

    @Environment(\.menuStyle) private var style
    /// The skin under the cursor. A cell that does not answer hover reads as a
    /// picture rather than as something you can press. Read through `onHoverRegion`,
    /// so the tile answers on the island too, where SwiftUI's own hover is silent.
    @State private var hoveredSkin: String?

    private var cell: CGSize { style.cellSize }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cell.width), spacing: style.cellSpacing), count: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            LazyVGrid(columns: columns, alignment: .leading, spacing: style.cellSpacing) {
                ForEach(appState.availableSkins) { skin in
                    preview(skin)
                }
            }
            credits
        }
        // `rescanPets` publishes `registry`; publishing synchronously from
        // inside `onAppear`'s own view-update pass is exactly what SwiftUI's
        // "Publishing changes from within view updates" warning is about, so the
        // call is deferred to the next run-loop turn instead.
        .onAppear { DispatchQueue.main.async { appState.rescanPets() } }
    }

    private static var title: String { L10n.t("skins.title", "Skin") }

    @ViewBuilder
    private var header: some View {
        if style.separator == nil {
            Text(Self.title).font(.system(size: 12, weight: .medium))
        } else {
            MenuSectionHeader(title: Self.title)
        }
    }

    private func preview(_ skin: MascotSkin) -> some View {
        let isSelected = skin.id == appState.skinID
        // Every preview plays the "waiting" animation: that is the state the
        // mascot exists for. A `.sleeping`-tone indicator is what suppresses the badge
        // for the fallback `CatView` (its `MascotBadge` draws nothing for that tone),
        // reachable here only for a skin that failed to load; the sprite path
        // additionally passes `showsBadge: false` since the badge there is a separate
        // view, not gated on the tone. At 34pt the badge would cover the cat either way.
        let isHovered = hoveredSkin == skin.id
        // Scaled by the cell's smaller side: on the island the cell is wider than it is
        // tall, and dividing by the width would crop the cat top and bottom.
        return previewContent(skin)
            .scaleEffect(min(cell.width, cell.height) / MascotLayout.canvasSize)
            .frame(width: cell.width, height: cell.height)
            .background(RoundedRectangle(cornerRadius: style.cellRadius)
                .fill(isSelected ? style.cellSelected : (isHovered ? style.cellHover : style.cellFill)))
            .overlay(
                RoundedRectangle(cornerRadius: style.cellRadius)
                    .strokeBorder(isSelected ? style.selectionBorder : Color.clear,
                                  lineWidth: style.selectionBorderWidth))
            .contentShape(Rectangle())
            .onHoverRegion { phase in
                if case .active = phase { hoveredSkin = skin.id }
                else if hoveredSkin == skin.id { hoveredSkin = nil }
            }
            .onTapGesture { appState.skinID = skin.id }
            .pointingHandOnHover()
            .help(skin.name)
            .accessibilityLabel(skin.name)
    }

    @ViewBuilder
    private func previewContent(_ skin: MascotSkin) -> some View {
        // Both `SpriteMascotView` and `CatView` already lay themselves out on a
        // `MascotLayout.canvasSize` canvas internally, so no extra outer frame is
        // needed before scaling them down to `previewSize`.
        //
        // The `CatView` branch only fires for a skin whose sheets fail to load —
        // every registered skin is sprite-backed now, so this is purely the
        // emergency render, kept here so a broken skin still shows something in its
        // tile instead of an empty square.
        if let loaded = SpriteSheetStore.shared.load(skin) {
            SpriteMascotView(loaded: loaded, status: .waiting(1),
                             indicator: MascotIndicator(tone: .sleeping, count: 0, crashedMarker: false),
                             maxFPS: previewFPS, showsBadge: false)
        } else {
            CatView(status: .waiting(1),
                    indicator: MascotIndicator(tone: .sleeping, count: 0, crashedMarker: false))
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

    /// The credits row is drawn by hand rather than as a `DisclosureGroup`: the
    /// system control gives no hover feedback and no cursor, so the one line in the
    /// picker that hides content behind a click looked like a caption. The chevron
    /// turns and the row highlights like every other pressable line.
    private var credits: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(style.tertiary)
                    .rotationEffect(.degrees(appState.creditsExpanded ? 90 : 0))
                    .animation(.easeOut(duration: 0.15), value: appState.creditsExpanded)
                Text(L10n.t("skins.credits", "About the assets"))
                    .foregroundStyle(style.primary)
                Spacer(minLength: 0)
            }
            .hoverHighlight()
            .onTapGesture { appState.creditsExpanded.toggle() }
            .accessibilityAddTraits(.isButton)

            if appState.creditsExpanded {
                creditList
            }
        }
        .font(.system(size: 11))
    }

    private var creditList: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(creditRows) { credit in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(credit.heading).font(.system(size: 11, weight: .medium))
                        if let note = credit.note {
                            // Third-party text — a pet's own description — must
                            // not be able to grow the panel without bound.
                            Text(note).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                        Text(credit.terms).font(.system(size: 10)).foregroundStyle(.secondary)
                        if credit.isFolder {
                            Text(L10n.f("skins.imported.from", "From %@", credit.source))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        } else if let url = URL(string: credit.source) {
                            // `URL(string:)` is not force-unwrapped: every `sourceURL` in
                            // `MascotSkins` is a valid literal today, but this view has no
                            // way to enforce that going forward, and a malformed URL must
                            // read as a missing link, not crash the details panel.
                            Link(credit.source, destination: url).font(.system(size: 10))
                        } else {
                            Text(credit.source).font(.system(size: 10))
                        }
                    }
                }
            }
            .padding(.leading, 4)
    }

    /// One entry per built-in pack (not per skin — six LuizMelo cats share one
    /// author and one licence, and repeating them six times would bury the one line
    /// that is an actual obligation: mxmaze is CC BY 4.0), then one per imported pet.
    private var creditRows: [Credit] {
        var seen = Set<String>()
        var result: [Credit] = []
        for skin in appState.availableSkins {
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
