import AppKit
import CodeCatCore

/// The menu-bar symbol (spec §10): the mark with its eyes knocked out, as a template so
/// macOS tints it for light and dark bars, and a 5.5 pt dot at its bottom right only
/// when an agent waits (orange) or a session died (red) — the island does the
/// talking. Every state draws on the same 20 × 11 canvas (Figma 07's badged symbol,
/// 181 × 101 at 1/9), so the status item never changes width.
enum BrandMark {
    private static let canvas = NSSize(width: 20, height: 11)
    /// Where the 18 × 10 template sits: at the top, like Figma's badged frame.
    private static let symbolRect = NSRect(x: 0, y: 1, width: 18, height: 10)
    /// Figma's badge: centre (155.7, 75.2), radius 24.75, in the 181 × 101 frame.
    private static let dotRect = NSRect(x: 155.7 / 9 - 2.75, y: 11 - 75.2 / 9 - 2.75, width: 5.5, height: 5.5)

    /// `Contents/Resources/menubar.pdf` in the app; the repository's copy under `swift run`.
    private static let symbol: NSImage? = {
        if let url = Bundle.main.url(forResource: "menubar", withExtension: "pdf") { return NSImage(contentsOf: url) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        return NSImage(contentsOf: exe.appendingPathComponent("../../../Resources/Brand/menubar.pdf"))
    }()

    static func statusImage(for aggregate: AggregateStatus) -> NSImage? {
        guard let symbol else { return nil }
        let dot: NSColor? = {
            switch aggregate {
            case .waiting: return NSColor(ToneColor.island(.waiting))
            case .problem: return NSColor(ToneColor.island(.problem))
            case .sleeping, .working, .done: return nil
            }
        }()
        let image = NSImage(size: canvas, flipped: false) { _ in
            symbol.draw(in: symbolRect)
            if let dot {
                // A drawn image is not tinted by the menu bar, so the mark takes the
                // label colour itself — resolved here, at draw time, in the bar's
                // appearance.
                NSColor.labelColor.set()
                symbolRect.fill(using: .sourceAtop)
                dot.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = dot == nil
        return image
    }
}
