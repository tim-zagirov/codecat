import SwiftUI
import AppKit
import CodeCatCore

/// One link a finished turn handed over: a symbol, a short title, a click that
/// opens it and a drag that carries it out of the island into a browser or Finder
/// window — the one scene from the concept video that is pure use.
struct HandoffChipView: View {
    let link: HandoffLink
    /// Position in the row, for the stagger.
    let index: Int

    @Environment(\.menuStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var appeared = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Image(systemName: link.kind.symbol).font(.system(size: 10))
                Text(shortTitle).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(style.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(hovering ? style.chipHover : style.chipFill))
        }
        .buttonStyle(ChipButtonStyle())
        .onDrag { NSItemProvider(object: link.target as NSURL) }
        // `HoverPhase.active` carries a `CGPoint` payload, so it cannot be compared
        // with `==` the way the brief's snippet wrote it (that does not compile) —
        // matched with `if case`, the same idiom `HoverHighlight` and
        // `PointingHandOnHover` already use in `MenuStyle.swift`.
        .onHoverRegion { phase in
            if case .active = phase {
                hovering = true
                NSCursor.pointingHand.set()
            } else {
                hovering = false
            }
        }
        .help(link.target.absoluteString)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.95)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            let delay = reduceMotion ? 0 : Double(index) * Motion.chipStagger
            withAnimation(Motion.chipAppear.delay(delay)) { appeared = true }
        }
    }

    /// Eighteen characters: a `localhost:4321` fits, a long file name is cut.
    private var shortTitle: String {
        link.title.count > 18 ? String(link.title.prefix(17)) + "…" : link.title
    }

    private func open() {
        switch link.kind {
        case .folder: NSWorkspace.shared.activateFileViewerSelecting([link.target])
        default: NSWorkspace.shared.open(link.target)
        }
    }
}

/// Lays chips left to right at their own ideal width and wraps to a new line
/// instead of letting a fixed-width row crush them: a chip's title is a name —
/// "localhost:4321" — and a name cut off mid-digit is not the name it names, so
/// truncation was never an option here the way it is for a summary line.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var usedWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                totalHeight += lineHeight + spacing
                usedWidth = max(usedWidth, lineWidth)
                lineWidth = 0
                lineHeight = 0
            }
            lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
            lineHeight = max(lineHeight, size.height)
        }
        usedWidth = max(usedWidth, lineWidth)
        totalHeight += lineHeight
        return CGSize(width: usedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x - bounds.minX + size.width > bounds.width {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Press feedback on mouse-down, not on release — the interface is listening.
private struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.chipPress, value: configuration.isPressed)
    }
}

extension HandoffLink.Kind {
    var symbol: String {
        switch self {
        case .localhost: return "globe"
        case .pullRequest: return "arrow.triangle.pull"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .figma: return "paintpalette"
        case .artifact: return "doc.richtext"
        case .web: return "link"
        case .file: return "doc"
        case .folder: return "folder"
        }
    }
}

/// The summary and the chips, under a finished or waiting row.
struct HandoffBlockView: View {
    let handoff: Handoff
    /// Island rows have one line for the summary; panel rows two.
    let compact: Bool
    @Environment(\.menuStyle) private var style

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let summary = handoff.summary {
                Text(summary)
                    .font(.system(size: compact ? 10 : 11))
                    .foregroundStyle(style.secondary)
                    .lineLimit(compact ? 1 : 2)
                    .truncationMode(.tail)
            }
            if !handoff.links.isEmpty {
                ChipFlow(spacing: 6) {
                    ForEach(Array(handoff.links.enumerated()), id: \.element.id) { index, link in
                        HandoffChipView(link: link, index: index)
                    }
                }
            }
        }
        // A click on a chip's `Button` must not also trigger the row's own
        // `onTapGesture` (which jumps to the session and closes the menu). SwiftUI
        // resolves a `Button` before an ancestor's `onTapGesture` on macOS, but a
        // second, empty `onTapGesture` right here still wins any tie closer to the
        // chips than the row's — cheap insurance verified on the rendered check.
        .onTapGesture {}
    }
}
