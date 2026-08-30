import Foundation

/// The decisions the jump executor makes around sending its Apple event, separated
/// from the system calls that feed them so they can be tested on fixed values — the
/// executor itself lives in the app target, which has no tests.
///
/// The status codes are spelled as literals rather than imported from the AE
/// framework: `CodeCatCore` stays dependency-free, and these four numbers are a
/// stable part of the OS ABI.
public enum JumpExecutionPolicy {

    /// What the automation-permission query means for the jump about to be made.
    public enum Permission: Equatable, Sendable {
        /// Already allowed: send now, and hold it to the short deadline.
        case granted
        /// Refused. Never send — report it and fall back instead.
        case denied
        /// Undecided: sending puts up the system consent panel and blocks until a
        /// human answers, so the short deadline must not be used.
        case awaitingConsent
        /// Nothing is running under that bundle identifier any more.
        case hostGone
    }

    /// Classifies the result of `AEDeterminePermissionToAutomateTarget`.
    ///
    /// - `noErr` → granted.
    /// - `errAEEventNotPermitted` (-1743) and `errAETargetAddressNotPermitted`
    ///   (-1742) → denied. They differ in why the send is refused, but the user
    ///   needs the same actionable message either way, not a raw AppleScript error.
    /// - `errAEEventWouldRequireUserConsent` (-1744) → awaiting consent.
    /// - `procNotFound` (-600) → host gone.
    ///
    /// Anything unrecognised is treated as awaiting consent rather than granted:
    /// guessing "granted" would put the short deadline on a send that may still be
    /// blocked on a human, which is exactly the misreport this classification exists
    /// to prevent.
    public static func permission(forStatus status: OSStatus) -> Permission {
        switch status {
        case 0: return .granted
        case -1743, -1742: return .denied
        case -1744: return .awaitingConsent
        case -600: return .hostGone
        default: return .awaitingConsent
        }
    }

    /// Deadline for a wedged terminal: selecting a tab is a local Apple event that
    /// normally returns in milliseconds, so past a few seconds the terminal is stuck
    /// (a hung ssh, a beachballing tab), not slow. Long enough not to libel a loaded
    /// machine, short enough that the user is not left staring at nothing.
    public static let scriptTimeout: TimeInterval = 8

    /// Deadline for a send that is waiting on the consent panel. It exists only so a
    /// genuinely wedged terminal cannot hold the queue forever; it must never be so
    /// short that it runs out while a human is reading a dialog.
    public static let consentTimeout: TimeInterval = 120

    public static func timeout(for permission: Permission) -> TimeInterval {
        permission == .awaitingConsent ? consentTimeout : scriptTimeout
    }

    /// Whether a new jump has to be refused because an earlier script is wedged and
    /// owns the serial queue. A script that is merely still running does not block:
    /// the new jump queues behind it and runs in a moment. One that is past its
    /// deadline does, because queuing behind it would be a silent refusal.
    public static func isBlocked(outstanding: Int, deadlinePassed: Bool) -> Bool {
        outstanding > 0 && deadlinePassed
    }
}
