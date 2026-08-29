import Foundation

/// Abstraction over a system sleep assertion so `PowerManager`'s policy is testable
/// without touching IOKit. The real implementation is `IOKitSleepAssertion`.
public protocol SleepAssertionHolding: AnyObject {
    func acquire()
    func release()
    var isHeld: Bool { get }
}

/// Decides when the Mac should be kept awake while Claude Code agents are working.
///
/// Call contract (owned by the caller, typically driven from the app's main thread):
/// - Call `update(anyWorking:now:)` whenever the aggregate "is any session working" bit
///   changes (see `AggregateStatus`). A session waiting on the user does not count as
///   working.
/// - Call `tick(now:)` from a repeating timer (the app uses 15s) so the grace-period
///   release and battery-floor checks/re-checks happen even without a work-state change.
/// - Toggle `isEnabled` to reflect the user's on/off preference for the feature.
///
/// As long as the caller keeps calling `tick` periodically, `PowerManager` guarantees it
/// never leaves a `SleepAssertionHolding` held while no work is in progress (or while
/// disabled, or while below the battery floor).
public final class PowerManager {
    private let assertion: SleepAssertionHolding
    private let gracePeriod: TimeInterval
    private let batteryFloor: Int
    private let batteryLevel: () -> Int?

    private var pendingReleaseAt: Date?
    private var anyWorking = false

    /// Turning this off releases an already-held assertion immediately (not at the next
    /// tick) and prevents any future acquisition until it is turned back on.
    public var isEnabled = true {
        didSet {
            guard !isEnabled else { return }
            assertion.release()
            pendingReleaseAt = nil
        }
    }

    public var isHolding: Bool { assertion.isHeld }

    public init(assertion: SleepAssertionHolding,
                gracePeriod: TimeInterval = 120,
                batteryFloor: Int = 15,
                batteryLevel: @escaping () -> Int? = { nil }) {
        self.assertion = assertion
        self.gracePeriod = gracePeriod
        self.batteryFloor = batteryFloor
        self.batteryLevel = batteryLevel
    }

    public func update(anyWorking: Bool, now: Date) {
        self.anyWorking = anyWorking
        reconcile(now: now)
    }

    public func tick(now: Date) {
        reconcile(now: now)
    }

    /// Single source of truth for all state transitions, so every entry point
    /// (`update`, `tick`, disabling) leaves the assertion in a consistent state and
    /// never leaks one held with no work in progress.
    private func reconcile(now: Date) {
        guard isEnabled else {
            assertion.release()
            pendingReleaseAt = nil
            return
        }

        if batteryTooLow() {
            assertion.release()
            pendingReleaseAt = nil
            return
        }

        if anyWorking {
            // Work resuming (even mid grace-period) cancels any pending release.
            pendingReleaseAt = nil
            if !assertion.isHeld {
                assertion.acquire()
            }
            return
        }

        guard assertion.isHeld else {
            pendingReleaseAt = nil
            return
        }

        guard let deadline = pendingReleaseAt else {
            // Work just stopped: start the grace period instead of releasing right away.
            pendingReleaseAt = now.addingTimeInterval(gracePeriod)
            return
        }

        if now >= deadline {
            assertion.release()
            pendingReleaseAt = nil
        }
    }

    private func batteryTooLow() -> Bool {
        guard let level = batteryLevel() else { return false }
        return level < batteryFloor
    }
}
