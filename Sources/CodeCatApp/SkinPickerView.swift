import SwiftUI
import CodeCatCore

/// The skin picker: a grid of live previews plus the credits disclosure.
///
/// Nine previews at 36pt would not fit the 290pt panel in one row, and horizontal
/// scrolling inside a popover that closes on any click outside it is a way to miss,
/// not a way to choose — hence a 5x2 grid that fits whole. Fits with room to spare:
/// 5 columns x 34pt + 4 gaps x 8pt = 202pt, against 290 - 2x14 = 262pt of usable
/// width inside the panel's own padding.
struct SkinPickerView: View {
    @ObservedObject var appState: AppState

    /// Previews are small and there are nine of them animating at once, so their
    /// frame rate is capped well below the mascot's own.
    private let previewFPS: Double = 4
    private let previewSize: CGFloat = 34

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(previewSize), spacing: 8), count: 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Облик").font(.system(size: 12, weight: .medium))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(MascotSkins.all) { skin in
                    preview(skin)
                }
            }
            credits
        }
    }

    private func preview(_ skin: MascotSkin) -> some View {
        let isSelected = skin.id == appState.skinID
        // Every preview plays the "waiting" animation: that is the state the
        // mascot exists for. `sessionCount: 0` is what suppresses the badge for
        // the drawn cat (its `MascotBadge` only draws when the count is positive);
        // the sprite path additionally passes `showsBadge: false` since the badge
        // there is a separate view, not gated on the count. At 34pt the badge
        // would cover the cat either way.
        return previewContent(skin)
            .scaleEffect(previewSize / MascotLayout.canvasSize)
            .frame(width: previewSize, height: previewSize)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture { appState.skinID = skin.id }
            .help(skin.name)
            .accessibilityLabel(skin.name)
    }

    @ViewBuilder
    private func previewContent(_ skin: MascotSkin) -> some View {
        // Both `SpriteMascotView` and `CatView` already lay themselves out on a
        // `MascotLayout.canvasSize` canvas internally, so no extra outer frame is
        // needed before scaling them down to `previewSize`.
        if skin.isSpriteBased, let loaded = SpriteSheetStore.shared.load(skin) {
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
        for skin in MascotSkins.all where skin.isSpriteBased {
            guard seen.insert(skin.author).inserted else { continue }
            result.append((author: skin.author,
                           license: licenseText(skin.license),
                           // Every sprite-based skin's `sourceURL` is set in
                           // `MascotSkins` — only the drawn cat (excluded by the
                           // `where` above) leaves it nil — but nil-coalesce rather
                           // than force-unwrap so a future skin added without one
                           // degrades to a missing link instead of a crash.
                           sourceURL: skin.sourceURL ?? ""))
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
        case .builtIn: return "Нарисован для CodeCat"
        }
    }
}
