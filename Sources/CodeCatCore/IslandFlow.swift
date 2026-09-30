import Foundation

/// The island's presentation and its peeks, kept by the one protocol `PeekScheduler`
/// documents — so the notch island and the floating cat cannot drift apart in how they
/// keep it. Pure: the caller feeds the pointer, the session list, the screen lock and
/// the clock, ticks at `nextDeadline`, and draws `presentation`.
///
/// Every presenter call that can end a peek goes through `ended`, which tells the
/// scheduler; every change ends in `settle`, which reports an open list and asks for
/// the next peek while the island is free. Those two rules are the whole protocol.
public final class IslandFlow {
    public private(set) var presenter: IslandPresenter
    private let scheduler: PeekScheduler
    public private(set) var isLocked = false

    /// `sessions` is a baseline: a session seen for the first time is a restore, not
    /// an event, so the list the app starts with never peeks.
    public init(hoverDelay: TimeInterval, settings: PeekSettings, sessions: [Session], now: Date) {
        presenter = IslandPresenter(hoverDelay: hoverDelay)
        scheduler = PeekScheduler(settings: settings)
        scheduler.sessionsChanged(sessions, now: now)
    }

    public var presentation: IslandPresentation { presenter.presentation }
    public var peekHold: IslandPresenter.PeekHold? { presenter.peekHold }

    public var hoverDelay: TimeInterval {
        get { presenter.hoverDelay }
        set { presenter.hoverDelay = newValue }
    }

    public var settings: PeekSettings {
        get { scheduler.settings }
        set { scheduler.settings = newValue }
    }

    /// The one moment the caller must `tick` at: the presenter's dwell, close delay or
    /// peek hold, or the end of the gap before a queued peek.
    public var nextDeadline: Date? {
        [presenter.nextDeadline, scheduler.readyAt].compactMap { $0 }.min()
    }

    /// Feed every change of the session list, from the store's `$sessions` value —
    /// synchronously: transitions are diffs between consecutive snapshots (Part 1
    /// handover, contract 1).
    public func sessionsChanged(_ sessions: [Session], now: Date) {
        if let replacement = scheduler.sessionsChanged(sessions, now: now), case .peek = presenter.presentation {
            presenter.show(replacement, now: now)
        }
        // A peek about sessions that are gone — SessionEnd, the crashed card's × —
        // ends (contract 3). The away summary names none and stays.
        if case .peek(let item) = presenter.presentation, !item.sessionIDs.isEmpty {
            let present = Set(sessions.map(\.id))
            if !item.sessionIDs.contains(where: present.contains) {
                ended(presenter.escape(), now: now)
                return
            }
        }
        settle(now: now)
    }

    public func pointerEntered(now: Date) {
        presenter.pointerEntered(now: now)
        settle(now: now)
    }

    public func pointerLeft(now: Date) {
        presenter.pointerLeft(now: now)
        settle(now: now)
    }

    public func tick(now: Date) { ended(presenter.tick(now: now), now: now) }
    public func open(now: Date) { ended(presenter.open(now: now), now: now) }
    public func escape(now: Date) { ended(presenter.escape(), now: now) }
    public func jumped(now: Date) { ended(presenter.jumped(), now: now) }

    /// The screen locked: nobody is there to read a peek, so the one on screen ends and
    /// what happens until the unlock is counted for one summary (spec §6.2). The queue
    /// goes into the count first (`PeekScheduler.lock`), so ending the peek cannot
    /// bring the next one up.
    public func lock(now: Date) {
        guard !isLocked else { return }
        isLocked = true
        scheduler.lock()
        if case .peek = presenter.presentation {
            presenter.escape()
            scheduler.peekEnded(now: now)
        }
    }

    public func unlock(now: Date) {
        guard isLocked else { return }
        isLocked = false
        scheduler.unlock(now: now)
        settle(now: now)
    }

    private func ended(_ item: PeekItem?, now: Date) {
        if item != nil { scheduler.peekEnded(now: now) }
        settle(now: now)
    }

    private func settle(now: Date) {
        switch presenter.presentation {
        case .expanded:
            scheduler.listOpened()
        case .compact, .inhaled:
            guard !isLocked, let item = scheduler.next(now: now) else { return }
            presenter.show(item, now: now)
        case .peek:
            break
        }
    }
}
