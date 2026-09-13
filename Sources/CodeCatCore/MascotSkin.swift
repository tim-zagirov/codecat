import Foundation

/// One frame: which sprite sheet it lives in, and where in that sheet.
///
/// The sheet's column count is deliberately *not* declared anywhere. It is derived
/// at load time from the image's real width (`width / frameWidth`), and the frame's
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

/// One stretch of movement: frames, speed, and how many times to play it.
public struct SpritePhase: Equatable, Sendable {
    public let frames: [SpriteFrame]
    public let framesPerSecond: Double
    /// How many times to play the phase before yielding to the next. `nil` means loop
    /// forever; only the last phase may be marked that way, or everything after it is
    /// unreachable.
    public let repeats: Int?

    public init(frames: [SpriteFrame], framesPerSecond: Double, repeats: Int? = nil) {
        self.frames = frames
        self.framesPerSecond = framesPerSecond
        self.repeats = repeats
    }
}

/// The movement for one state — a sequence of phases, the last of which loops forever.
///
/// One loop is not enough: some movements in these sprite packs are one-shot by
/// nature. A stretch is a stretch, not something a cat does without stopping for ten
/// minutes; LuizMelo has a separate `Laying` sheet for exactly this — a sit-down-then-
/// lie-down transition that in a loop would look like endless getting up and lying
/// down again. So "done" is described as "stretch a couple of times → lie down →
/// breathe in sleep": a few frames of action, a transition, rest.
public struct SpriteAnimation: Equatable, Sendable {
    public let phases: [SpritePhase]

    /// The first phase's frames. Kept for callers that want not the chronology but
    /// "what it looks like" — the panel's previews, the registry's checks.
    public var frames: [SpriteFrame] { phases.first?.frames ?? [] }
    public var framesPerSecond: Double { phases.first?.framesPerSecond ?? 1 }

    public init(phases: [SpritePhase]) {
        self.phases = phases
    }

    /// An ordinary endless loop — as it was before phases existed.
    public init(frames: [SpriteFrame], framesPerSecond: Double) {
        self.phases = [SpritePhase(frames: frames, framesPerSecond: framesPerSecond)]
    }
}

/// The terms each pack ships under, re-read from the source pages rather than from
/// any secondary table. Only CC BY 4.0 makes attribution a legal obligation; the
/// rest are shown out of courtesy.
public enum SkinLicense: Equatable, Sendable {
    case cc0
    /// The credited name lives in `MascotSkin.author`, which is what the UI
    /// actually shows and what the tests actually guard — this case carries no
    /// payload of its own to avoid a second, unread copy of that name.
    case ccBy4
    /// Elthen publishes no formal licence — the terms are the author's own words.
    case authorTerms(summary: String)

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

/// Where a skin's sheets live.
public enum SkinLocation: Equatable, Sendable {
    /// A directory under the app bundle's `Skins/`, by relative path. Every
    /// built-in skin.
    case bundled(String)
    /// A directory anywhere on disk — a pet imported from a folder the user owns.
    case external(URL)

    /// The relative path for a bundled skin, nil for an external one.
    public var bundledPath: String? {
        if case .bundled(let path) = self { return path }
        return nil
    }

    /// Tells two skins' sheets apart in a cache: a bundled "duck" and an
    /// external ".../duck" must never share an entry.
    public var cacheKey: String {
        switch self {
        case .bundled(let path): return "bundled:\(path)"
        case .external(let url): return "external:\(url.standardizedFileURL.path)"
        }
    }
}

public struct MascotSkin: Equatable, Sendable, Identifiable {
    /// Persisted in `UserDefaults` — never rename one of these.
    public let id: String
    /// The label the user sees, already localised.
    public let name: String
    public let author: String
    public let license: SkinLicense
    /// The itch.io page the sprites came from.
    public let sourceURL: String
    /// Where the sheets are.
    public let location: SkinLocation
    /// One frame's size in sheet pixels. 50×50 for LuizMelo, 32×32 for Elthen,
    /// 16×16 for mxmaze; 192×208 for a pet in the Codex format.
    public let frameWidth: Int
    public let frameHeight: Int
    /// Whether this skin's sheets are committed to the repository and therefore
    /// present in every build.
    ///
    /// `false` means the author forbids redistributing the assets themselves, so
    /// they are downloaded onto the build machine instead (see
    /// `scripts/fetch-optional-assets.sh`) and may legitimately be missing. A
    /// skin like that disappears from the picker rather than failing anything —
    /// which is why this is a declared fact about the skin and not something the
    /// UI infers from a failed load.
    public let bundled: Bool
    /// Free text shown under the skin in the credits — a pet's own description.
    public let note: String?
    public let animations: [AggregateStatusKey: SpriteAnimation]

    public init(id: String, name: String, author: String, license: SkinLicense,
                sourceURL: String, location: SkinLocation,
                frameWidth: Int, frameHeight: Int,
                bundled: Bool = true, note: String? = nil,
                animations: [AggregateStatusKey: SpriteAnimation]) {
        self.id = id
        self.name = name
        self.author = author
        self.license = license
        self.sourceURL = sourceURL
        self.location = location
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.bundled = bundled
        self.note = note
        self.animations = animations
    }

    /// The built-ins' spelling: square frames in a directory under `Skins/`.
    public init(id: String, name: String, author: String, license: SkinLicense,
                sourceURL: String, directory: String, frameSize: Int,
                bundled: Bool = true,
                animations: [AggregateStatusKey: SpriteAnimation]) {
        self.init(id: id, name: name, author: author, license: license,
                  sourceURL: sourceURL, location: .bundled(directory),
                  frameWidth: frameSize, frameHeight: frameSize,
                  bundled: bundled, animations: animations)
    }

    /// Every sheet file this skin declares, de-duplicated. Used to answer "are this
    /// skin's assets on disk?" without decoding a single PNG.
    public var declaredSheets: [String] {
        var seen = Set<String>()
        var result: [String] = []
        // Every phase, not just the first: `.done` is a transition whose later
        // phases ("laying", "sleeping") live in their own files, and a sheet that
        // is only reachable after the first phase is exactly the one that would go
        // missing unnoticed.
        for animation in animations.values {
            for phase in animation.phases {
                for frame in phase.frames where seen.insert(frame.sheet).inserted {
                    result.append(frame.sheet)
                }
            }
        }
        return result.sorted()
    }

    public func animation(for key: AggregateStatusKey) -> SpriteAnimation? {
        animations[key]
    }
}
