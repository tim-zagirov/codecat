import Foundation

public struct AwayEntry: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let date: Date
}

public final class AwayLog: ObservableObject {
    @Published public private(set) var lastSummary: [AwayEntry] = []
    public private(set) var isAway = false
    private var collecting: [AwayEntry] = []

    public init() {}

    public func lock() {
        guard !isAway else { return }
        isAway = true
        collecting = []
        lastSummary = []
    }

    public func unlock() {
        guard isAway else { return }
        isAway = false
        lastSummary = collecting
        collecting = []
    }

    public func record(_ text: String, at date: Date) {
        guard isAway else { return }
        collecting.append(AwayEntry(id: UUID(), text: text, date: date))
    }
}
