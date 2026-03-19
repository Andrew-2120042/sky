import Foundation

/// In-memory log of the last 20 actions executed by Sky. Never persisted to disk.
final class ActionLogService: @unchecked Sendable {

    static let shared = ActionLogService()

    struct LogEntry: Sendable {
        let id: UUID
        let summary: String
        let executedAt: Date
        let succeeded: Bool
    }

    private var _recentActions: [LogEntry] = []
    private let lock = NSLock()

    var recentActions: [LogEntry] {
        lock.withLock { _recentActions }
    }

    private init() {}

    /// Prepends a new log entry, capping the list at 20 entries.
    func record(summary: String, succeeded: Bool) {
        let entry = LogEntry(id: UUID(), summary: summary, executedAt: Date(), succeeded: succeeded)
        lock.withLock {
            _recentActions.insert(entry, at: 0)
            if _recentActions.count > 20 {
                _recentActions = Array(_recentActions.prefix(20))
            }
        }
    }
}
