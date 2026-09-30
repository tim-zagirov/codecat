import Foundation

/// One self-opening moment of the island — spec §6.
public struct PeekItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case waiting, crashed, done
        /// Several sessions needing attention at once.
        case merged
        /// What happened while the screen was locked.
        case away(done: Int, waiting: Int, crashed: Int)
    }
    public let id: UUID
    public let kind: Kind
    public let sessionIDs: [String]
    public let createdAt: Date

    public init(id: UUID = UUID(), kind: Kind, sessionIDs: [String], createdAt: Date) {
        self.id = id; self.kind = kind; self.sessionIDs = sessionIDs; self.createdAt = createdAt
    }

    /// Done is good news and gets half the time; everything else asks for action.
    public var hold: TimeInterval {
        if case .done = kind { return 1.5 }
        return 3
    }

    /// Waiting and crashed ask the user to act; only those merge.
    public var isAttention: Bool {
        switch kind {
        case .waiting, .crashed, .merged: return true
        case .done, .away: return false
        }
    }
}

public struct PeekSettings: Equatable, Sendable {
    public var onWaiting: Bool
    public var onCrash: Bool
    public var onDone: Bool
    public init(onWaiting: Bool = true, onCrash: Bool = true, onDone: Bool = true) {
        self.onWaiting = onWaiting; self.onCrash = onCrash; self.onDone = onDone
    }
}

/// Turns session transitions into peeks: which ones, in what order, merged or
/// queued, and what to say after a locked screen. Pure — the caller supplies `now`
/// and asks for the next item when the island is free.
///
/// The scheduler remembers the peek it handed out until it is told the peek is
/// over, so the caller drives it together with `IslandPresenter` by one protocol:
///
///  * ask `next(now:)` only while the presentation is `.compact` or `.inhaled` —
///    then `IslandPresenter.show` always accepts the item (it refuses only while
///    the list is open);
///  * hand every `PeekItem` that `IslandPresenter.tick`, `escape`, `jumped` or
///    `open` returns to `peekEnded(now:)`;
///  * call `listOpened()` when the presentation becomes `.expanded`, and again
///    after every `sessionsChanged` while it stays `.expanded`.
///
/// Break the first two and the scheduler waits forever for a peek that is no longer
/// on screen: `next` returns nil for good and new events merge into a phantom.
/// `IslandPeekFlowTests` drives both types through exactly this protocol.
public final class PeekScheduler {
    public static let gap: TimeInterval = 0.4
    public static let mergeWindow: TimeInterval = 1.0

    public var settings: PeekSettings
    public private(set) var queue: [PeekItem] = []

    private var lastStatus: [String: SessionStatus] = [:]
    private var showing: PeekItem?
    private var lastEnded: Date = .distantPast
    private var isLocked = false
    private var away = (done: 0, waiting: 0, crashed: 0)

    public init(settings: PeekSettings = .init()) {
        self.settings = settings
    }

    /// Feed every change of the session list. Returns a replacement for the peek on
    /// screen when a new attention event merges into it; otherwise nil (anything new
    /// is queued for `next`).
    @discardableResult
    public func sessionsChanged(_ sessions: [Session], now: Date) -> PeekItem? {
        var events: [(PeekItem.Kind, String)] = []
        for session in sessions {
            // A session seen for the first time is a restore, not an event.
            guard let before = lastStatus[session.id],
                  let kind = Self.kind(entering: session.status, from: before) else { continue }
            events.append((kind, session.id))
        }
        lastStatus = Dictionary(sessions.map { ($0.id, $0.status) }, uniquingKeysWith: { _, new in new })

        var replacement: PeekItem?
        for (kind, id) in events {
            if isLocked {
                switch kind {
                case .done: away.done += 1
                case .waiting: away.waiting += 1
                case .crashed: away.crashed += 1
                case .merged, .away: break
                }
                continue
            }
            guard isEnabled(kind) else { continue }
            let item = PeekItem(kind: kind, sessionIDs: [id], createdAt: now)
            if item.isAttention, let merged = mergeIntoShowing(id, now: now) {
                replacement = merged
            } else if item.isAttention, mergeIntoQueue(id, now: now) {
                continue
            } else {
                queue.append(item)
            }
        }
        return replacement
    }

    /// The next peek to show, or nil while one is on screen, within the gap after the
    /// last, or when nothing queued is still true.
    public func next(now: Date) -> PeekItem? {
        guard showing == nil, now.timeIntervalSince(lastEnded) >= Self.gap else { return nil }
        while !queue.isEmpty {
            let item = queue.removeFirst()
            if isStillTrue(item) {
                showing = item
                return item
            }
        }
        return nil
    }

    public func peekEnded(now: Date) {
        showing = nil
        lastEnded = now
    }

    /// The list is open — spec §6: it already shows every session, so a peek on top
    /// of it or after it would repeat what the user has just seen. Forgets the peek
    /// on screen (the dwell that opened the list ended it) and drops the queue, which
    /// is why the caller repeats this after every change while the list stays open.
    /// The gap is left alone: it spaces peeks out, and the list was not one. Counting
    /// for the away summary is unaffected — a locked screen shows no list.
    public func listOpened() {
        showing = nil
        queue.removeAll()
    }

    /// The queue is dropped — nothing peeks on a locked screen — but what in it is
    /// still true goes into the away summary first: an event a moment before the lock
    /// was queued behind the peek on screen, and dropping it silently would lose it.
    public func lock() {
        isLocked = true
        away = (0, 0, 0)
        for item in queue where isStillTrue(item) {
            if case .away(let done, let waiting, let crashed) = item.kind {
                away.done += done; away.waiting += waiting; away.crashed += crashed
                continue
            }
            for id in item.sessionIDs {
                switch lastStatus[id] {
                case .done: away.done += 1
                case .crashed: away.crashed += 1
                case .waitingForYou(.permission), .waitingForYou(.question): away.waiting += 1
                default: break
                }
            }
        }
        queue.removeAll()
    }

    public func unlock(now: Date) {
        isLocked = false
        guard away.done + away.waiting + away.crashed > 0 else { return }
        queue.append(PeekItem(kind: .away(done: away.done, waiting: away.waiting, crashed: away.crashed),
                              sessionIDs: [], createdAt: now))
        away = (0, 0, 0)
    }

    // MARK: - Rules

    static func kind(entering status: SessionStatus, from before: SessionStatus) -> PeekItem.Kind? {
        switch status {
        case .waitingForYou(.permission), .waitingForYou(.question):
            switch before {
            case .waitingForYou(.permission), .waitingForYou(.question): return nil
            default: return .waiting
            }
        case .crashed:
            return before == .crashed ? nil : .crashed
        case .done:
            switch before {
            case .working, .waitingForYou(.idle): return .done
            default: return nil
            }
        case .idle, .working, .waitingForYou(.idle):
            return nil
        }
    }

    private func isEnabled(_ kind: PeekItem.Kind) -> Bool {
        switch kind {
        case .waiting: return settings.onWaiting
        case .crashed: return settings.onCrash
        case .done: return settings.onDone
        case .merged, .away: return true
        }
    }

    private func mergeIntoShowing(_ id: String, now: Date) -> PeekItem? {
        guard let current = showing, current.isAttention, !current.sessionIDs.contains(id),
              now.timeIntervalSince(current.createdAt) <= Self.mergeWindow else { return nil }
        let merged = PeekItem(id: current.id, kind: .merged, sessionIDs: current.sessionIDs + [id],
                              createdAt: current.createdAt)
        showing = merged
        return merged
    }

    private func mergeIntoQueue(_ id: String, now: Date) -> Bool {
        guard let index = queue.lastIndex(where: { $0.isAttention }),
              !queue[index].sessionIDs.contains(id),
              now.timeIntervalSince(queue[index].createdAt) <= Self.mergeWindow else { return false }
        let old = queue[index]
        queue[index] = PeekItem(id: old.id, kind: .merged, sessionIDs: old.sessionIDs + [id],
                                createdAt: old.createdAt)
        return true
    }

    private func isStillTrue(_ item: PeekItem) -> Bool {
        func status(_ id: String) -> SessionStatus? { lastStatus[id] }
        switch item.kind {
        case .waiting:
            return item.sessionIDs.contains { id in
                if case .waitingForYou(let r) = status(id) { return r == .permission || r == .question }
                return false
            }
        case .crashed: return item.sessionIDs.contains { status($0) == .crashed }
        case .done: return item.sessionIDs.contains { status($0) == .done }
        case .merged:
            return item.sessionIDs.contains { id in
                switch status(id) {
                case .crashed, .waitingForYou(.permission), .waitingForYou(.question): return true
                default: return false
                }
            }
        case .away: return true
        }
    }
}
