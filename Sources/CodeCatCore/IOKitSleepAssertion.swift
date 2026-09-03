import Foundation
import IOKit.pwr_mgt
import IOKit.ps

/// Real `SleepAssertionHolding` backed by IOKit's `PreventUserIdleSystemSleep`
/// assertion. Deliberately NOT a display-sleep assertion: the screen is allowed to
/// sleep and the Mac may be locked while agents keep working — only idle *system*
/// sleep is prevented.
public final class IOKitSleepAssertion: SleepAssertionHolding {
    private var assertionID: IOPMAssertionID = 0
    public private(set) var isHeld = false

    public init() {}

    public func acquire() {
        guard !isHeld else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            // English regardless of the UI language: this is the reason string that shows
            // up in `pmset -g assertions`, which is a diagnostic surface, not the UI.
            "CodeCat: Claude Code agents are working" as CFString,
            &assertionID)
        isHeld = (result == kIOReturnSuccess)
    }

    public func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        isHeld = false
    }

    deinit { release() }
}

public enum Battery {
    /// nil means the level is unknown, or the Mac is on mains power (in which case the
    /// limit is not applied).
    public static func currentLevelIfOnBattery() -> Int? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let state = desc[kIOPSPowerSourceStateKey as String] as? String
            guard state == kIOPSBatteryPowerValue as String else { continue }
            if let current = desc[kIOPSCurrentCapacityKey as String] as? Int,
               let max = desc[kIOPSMaxCapacityKey as String] as? Int, max > 0 {
                return current * 100 / max
            }
        }
        return nil
    }
}
