import Foundation

/// One frame: which sprite sheet it lives in, and where in that sheet.
///
/// The sheet's column count is deliberately *not* declared anywhere. It is derived
/// at load time from the image's real width (`width / frameSize`), and the frame's
/// position from `index`. Declaring it would be a fourth place where the data could
/// drift away from the file, and LuizMelo's horizontal strips are all different
/// lengths, so each would have to be described separately.
public struct SpriteFrame: Equatable, Sendable {
    /// File name inside the skin's directory.
    public let sheet: String
    /// Frame number within the sheet, left to right then top to bottom.
    public let index: Int

    public init(sheet: String, index: Int) {
        self.sheet = sheet
        self.index = index
    }
}

/// A looping animation for one state.
public struct SpriteAnimation: Equatable, Sendable {
    public let frames: [SpriteFrame]
    public let framesPerSecond: Double

    public init(frames: [SpriteFrame], framesPerSecond: Double) {
        self.frames = frames
        self.framesPerSecond = framesPerSecond
    }
}

/// The terms each pack ships under, re-read from the source pages rather than from
/// any secondary table. Only CC BY 4.0 makes attribution a legal obligation; the
/// rest are shown out of courtesy.
public enum SkinLicense: Equatable, Sendable {
    case cc0
    case ccBy4(attributionTo: String)
    /// Elthen publishes no formal licence — the terms are the author's own words.
    case authorTerms(summary: String)
    /// The hand-drawn cat: ours, no third-party terms involved.
    case builtIn

    public var requiresAttribution: Bool {
        if case .ccBy4 = self { return true }
        return false
    }
}

/// A flat projection of `AggregateStatus`: the animation depends on the *kind* of
/// state, never on the session count, so `.working(1)` and `.working(9)` map to the
/// same key.
public enum AggregateStatusKey: String, CaseIterable, Sendable {
    case sleeping, working, waiting, done, problem

    public init(_ status: AggregateStatus) {
        switch status {
        case .sleeping: self = .sleeping
        case .working: self = .working
        case .waiting: self = .waiting
        case .done: self = .done
        case .problem: self = .problem
        }
    }
}

public struct MascotSkin: Equatable, Sendable, Identifiable {
    /// Persisted in `UserDefaults` — never rename one of these.
    public let id: String
    /// The label the user sees, in Russian.
    public let name: String
    public let author: String
    public let license: SkinLicense
    /// The itch.io page the sprites came from; nil for the drawn cat, which has no
    /// upstream source to link to (it was drawn for CodeCat, not downloaded).
    public let sourceURL: String?
    /// Directory holding the sheets inside the app's resources; nil for the drawn cat.
    public let directory: String?
    /// 50 for LuizMelo, 32 for Elthen, 16 for mxmaze.
    public let frameSize: Int
    public let animations: [AggregateStatusKey: SpriteAnimation]

    public init(id: String, name: String, author: String, license: SkinLicense,
                sourceURL: String?, directory: String?, frameSize: Int,
                animations: [AggregateStatusKey: SpriteAnimation]) {
        self.id = id
        self.name = name
        self.author = author
        self.license = license
        self.sourceURL = sourceURL
        self.directory = directory
        self.frameSize = frameSize
        self.animations = animations
    }

    /// Whether this skin is drawn from sprite sheets (as opposed to the hand-drawn cat).
    public var isSpriteBased: Bool { directory != nil }

    public func animation(for key: AggregateStatusKey) -> SpriteAnimation? {
        animations[key]
    }
}
