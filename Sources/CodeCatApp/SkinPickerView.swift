import SwiftUI
import CodeCatCore

/// The skin picker: a grid of live previews plus the credits disclosure.
///
/// Eight previews at 36pt would not fit the 290pt panel in one row, and horizontal
/// scrolling inside a popover that closes on any click outside it is a way to miss,
/// not a way to choose — hence a 4x2 grid that fits whole. Fits with room to spare:
/// 4 columns x 34pt + 3 gaps x 8pt = 160pt, against 290 - 2x14 = 262pt of usable
/// width inside the panel's own padding.
struct SkinPickerView: View {
    @ObservedObject var appState: AppState

    /// Previews are small and there are eight of them animating at once, so their
    /// frame rate is capped well below the mascot's own.
    private let previewFPS: Double = 4

    @Environment(\.menuStyle) private var style
    /// Облик под курсором. Ячейка без ответа на наведение читается как картинка,
    /// а не как то, на что можно нажать.
    @State private var hoveredSkin: String?

    private var cell: CGSize { style.cellSize }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cell.width), spacing: style.cellSpacing), count: 4)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            LazyVGrid(columns: columns, alignment: .leading, spacing: style.cellSpacing) {
                ForEach(MascotSkins.all) { skin in
                    preview(skin)
                }
            }
            credits
        }
    }

    @ViewBuilder
    private var header: some View {
        if style.separator == nil {
            Text("Облик").font(.system(size: 12, weight: .medium))
        } else {
            MenuSectionHeader(title: "Облик")
        }
    }

    private func preview(_ skin: MascotSkin) -> some View {
        let isSelected = skin.id == appState.skinID
        // Every preview plays the "waiting" animation: that is the state the
        // mascot exists for. `sessionCount: 0` is what suppresses the badge for
        // the fallback `CatView` (its `MascotBadge` only draws when the count is
        // positive), reachable here only for a skin that failed to load; the sprite
        // path additionally passes `showsBadge: false` since the badge there is a
        // separate view, not gated on the count. At 34pt the badge would cover the
        // cat either way.
        let isHovered = hoveredSkin == skin.id
        // Масштаб берётся по меньшей стороне ячейки: у острова она шире, чем
        // высока, и делить на ширину значило бы обрезать кота сверху и снизу.
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
            .onHover { inside in
                if inside { hoveredSkin = skin.id }
                else if hoveredSkin == skin.id { hoveredSkin = nil }
            }
            .onTapGesture { appState.skinID = skin.id }
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
            SpriteMascotView(loaded: loaded, status: .waiting(1), sessionCount: 0,
                             maxFPS: previewFPS, showsBadge: false)
        } else {
            CatView(status: .waiting(1), sessionCount: 0)
        }
    }

    private var credits: some View {
        DisclosureGroup("Об ассетах", isExpanded: $appState.creditsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(creditedPacks, id: \.author) { pack in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pack.author).font(.system(size: 11, weight: .medium))
                        Text(pack.license).font(.system(size: 10)).foregroundStyle(.secondary)
                        // `URL(string:)` is not force-unwrapped: every `sourceURL` in
                        // `MascotSkins` is a valid literal today, but this view has no
                        // way to enforce that going forward, and a malformed URL must
                        // read as a missing link, not crash the details panel.
                        if let url = URL(string: pack.sourceURL) {
                            Link(pack.sourceURL, destination: url)
                                .font(.system(size: 10))
                        } else {
                            Text(pack.sourceURL).font(.system(size: 10))
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.system(size: 11))
    }

    /// One entry per pack, not per skin: six LuizMelo cats share one author and one
    /// licence, and repeating them six times would bury the one line that is an
    /// actual obligation (mxmaze is CC BY 4.0, where attribution is required).
    private var creditedPacks: [(author: String, license: String, sourceURL: String)] {
        var seen = Set<String>()
        var result: [(author: String, license: String, sourceURL: String)] = []
        for skin in MascotSkins.all {
            guard seen.insert(skin.author).inserted else { continue }
            result.append((author: skin.author,
                           license: licenseText(skin.license),
                           sourceURL: skin.sourceURL))
        }
        return result
    }

    private func licenseText(_ license: SkinLicense) -> String {
        switch license {
        case .cc0: return "CC0 1.0 — общественное достояние"
        // The full attribution string (e.g. "Maze.Bit.Boutique (mxmaze), CC BY
        // 4.0") is deliberately not printed here: the author name it repeats is
        // already the heading directly above this line (`pack.author`), so
        // showing it again would print "Maze.Bit.Boutique (mxmaze)" twice for the
        // same pack. Together the two lines still name both the author and "CC BY
        // 4.0", which is what the licence actually requires.
        case .ccBy4: return "CC BY 4.0"
        case .authorTerms(let summary): return summary
        }
    }
}
