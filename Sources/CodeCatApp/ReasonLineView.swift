import SwiftUI
import CodeCatCore

/// What a session says in one line — `PeekReason`'s segments: words in body text,
/// commands, file names and hosts as inline code (§5.4, §6.3). One line: the command
/// is cut in the middle rather than the line wrapping.
struct ReasonLineView: View {
    let segments: [PeekReason.Segment]
    /// Commands, files and hosts as words of the line, not tokens: the floating
    /// peek's 300 pt capsule (Figma 06 "Peek") has no room for a token's padding and
    /// gaps — measured, `codecat wants to run npm test` and Open ↗ need 298 pt of its
    /// 272 with them, and the command was cut down to "…".
    var codeAsText = false

    var body: some View {
        if codeAsText {
            Text(segments.map(\.words).joined(separator: " "))
                .font(IslandPalette.bodyFont)
                .foregroundStyle(IslandPalette.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        } else {
            tokens
        }
    }

    private var tokens: some View {
        HStack(spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let text):
                    Text(text)
                        .font(IslandPalette.bodyFont)
                        .foregroundStyle(IslandPalette.secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                case .code(let text):
                    CodeToken(text)
                }
            }
        }
    }
}

/// Inline code: 13 medium on white 10 %, 5 pt corners.
struct CodeToken: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(IslandPalette.codeFont)
            .foregroundStyle(IslandPalette.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(IslandPalette.pill))
    }
}

private extension PeekReason.Segment {
    var words: String {
        switch self {
        case .text(let text), .code(let text): return text
        }
    }
}
