import Foundation

public enum IslandPresentation: Equatable, Sendable {
    case compact
    /// The cursor is on the island and the dwell is running — spec §4.3.
    case inhaled
    case peek(PeekItem)
    case expanded
}

/// When the island inhales, opens, peeks and closes — spec §4.3, §5.1, §6.2. Pure:
/// the controller feeds pointer events and `tick`s at `nextDeadline`, and executes
/// whatever `presentation` became. Keeping the timers here and not in AppKit is what
/// lets every one of these rules be tested.
public struct IslandPresenter {
    public static let closeDelay: TimeInterval = 0.15

    public var hoverDelay: TimeInterval
    public private(set) var presentation: IslandPresentation = .compact

    private var pointerInside = false
    private var dwellAt: Date?
    private var closeAt: Date?
    private var peekEndsAt: Date?
    private var peekRemaining: TimeInterval?

    public init(hoverDelay: TimeInterval = 0.3) {
        self.hoverDelay = hoverDelay
    }

    public var nextDeadline: Date? {
        [dwellAt, closeAt, peekEndsAt].compactMap { $0 }.min()
    }

    public mutating func pointerEntered(now: Date) {
        pointerInside = true
        switch presentation {
        case .compact:
            presentation = .inhaled
            dwellAt = now.addingTimeInterval(hoverDelay)
        case .inhaled:
            break
        case .peek:
            // Reading must not be cut short: pause the hold and start the dwell,
            // same as hovering the compact island.
            if let end = peekEndsAt { peekRemaining = max(0, end.timeIntervalSince(now)) }
            peekEndsAt = nil
            dwellAt = now.addingTimeInterval(hoverDelay)
        case .expanded:
            closeAt = nil
        }
    }

    public mutating func pointerLeft(now: Date) {
        pointerInside = false
        dwellAt = nil
        switch presentation {
        case .inhaled:
            presentation = .compact
        case .peek:
            if let remaining = peekRemaining {
                peekEndsAt = now.addingTimeInterval(remaining)
                peekRemaining = nil
            }
        case .expanded:
            closeAt = now.addingTimeInterval(Self.closeDelay)
        case .compact:
            break
        }
    }

    /// Returns the peek that ended on this tick, if any.
    @discardableResult
    public mutating func tick(now: Date) -> PeekItem? {
        if let dwell = dwellAt, now >= dwell, pointerInside {
            dwellAt = nil
            let ended = currentPeek
            clearPeek()
            presentation = .expanded
            return ended
        }
        if let close = closeAt, now >= close {
            closeAt = nil
            presentation = .compact
            return nil
        }
        if let end = peekEndsAt, now >= end {
            let ended = currentPeek
            clearPeek()
            presentation = pointerInside ? .inhaled : .compact
            return ended
        }
        return nil
    }

    /// Show a peek. Refused while the list is open: it already shows everything.
    @discardableResult
    public mutating func show(_ peek: PeekItem, now: Date) -> Bool {
        if case .expanded = presentation { return false }
        presentation = .peek(peek)
        if pointerInside {
            peekRemaining = peek.hold
            peekEndsAt = nil
            dwellAt = now.addingTimeInterval(hoverDelay)
        } else {
            peekRemaining = nil
            peekEndsAt = now.addingTimeInterval(peek.hold)
        }
        return true
    }

    @discardableResult
    public mutating func escape() -> PeekItem? { closeAll() }

    @discardableResult
    public mutating func jumped() -> PeekItem? { closeAll() }

    // MARK: - Private

    private var currentPeek: PeekItem? {
        if case .peek(let item) = presentation { return item }
        return nil
    }

    private mutating func clearPeek() {
        peekEndsAt = nil
        peekRemaining = nil
    }

    private mutating func closeAll() -> PeekItem? {
        let ended = currentPeek
        clearPeek()
        dwellAt = nil
        closeAt = nil
        presentation = .compact
        return ended
    }
}
