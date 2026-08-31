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

/// Один отрезок движения: кадры, скорость и сколько раз его проиграть.
public struct SpritePhase: Equatable, Sendable {
    public let frames: [SpriteFrame]
    public let framesPerSecond: Double
    /// Сколько раз проиграть фазу, прежде чем уступить следующей. `nil` — крутиться
    /// бесконечно; так может быть помечена только последняя фаза, иначе всё, что за
    /// ней, недостижимо.
    public let repeats: Int?

    public init(frames: [SpriteFrame], framesPerSecond: Double, repeats: Int? = nil) {
        self.frames = frames
        self.framesPerSecond = framesPerSecond
        self.repeats = repeats
    }
}

/// Движение для одного состояния — последовательность фаз, последняя из которых
/// крутится бесконечно.
///
/// Одной петли мало: часть движений в наборах спрайтов одноразовые по своей природе.
/// Потягивание — это потягивание, а не то, что кот делает без остановки десять минут;
/// у LuizMelo для этого есть отдельный лист `Laying` — переход «сесть и лечь»,
/// который в петле выглядел бы как бесконечное вставание и укладывание. Поэтому
/// «закончил» описывается как «потянулся пару раз → улёгся → дышит во сне»: пара
/// кадров действия, переход, покой.
public struct SpriteAnimation: Equatable, Sendable {
    public let phases: [SpritePhase]

    /// Кадры первой фазы. Оставлено ради вызывающих, которым нужна не хронология, а
    /// «как это выглядит» — превью в панели, проверки реестра.
    public var frames: [SpriteFrame] { phases.first?.frames ?? [] }
    public var framesPerSecond: Double { phases.first?.framesPerSecond ?? 1 }

    public init(phases: [SpritePhase]) {
        self.phases = phases
    }

    /// Обычная бесконечная петля — как было до появления фаз.
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

public struct MascotSkin: Equatable, Sendable, Identifiable {
    /// Persisted in `UserDefaults` — never rename one of these.
    public let id: String
    /// The label the user sees, in Russian.
    public let name: String
    public let author: String
    public let license: SkinLicense
    /// The itch.io page the sprites came from.
    public let sourceURL: String
    /// Directory holding the sheets inside the app's resources.
    public let directory: String
    /// 50 for LuizMelo, 32 for Elthen, 16 for mxmaze.
    public let frameSize: Int
    public let animations: [AggregateStatusKey: SpriteAnimation]

    public init(id: String, name: String, author: String, license: SkinLicense,
                sourceURL: String, directory: String, frameSize: Int,
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

    public func animation(for key: AggregateStatusKey) -> SpriteAnimation? {
        animations[key]
    }
}
