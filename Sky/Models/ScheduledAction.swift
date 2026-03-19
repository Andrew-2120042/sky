import Foundation

/// Recurrence options for scheduled actions.
enum Recurrence: String, Codable {
    case none
    case daily
    case weekly
    case monthly
    case custom
}

/// A persisted scheduled action stored in the SQLite database.
struct ScheduledAction: Identifiable {
    let id: String
    let actionType: String
    let paramsJson: String
    let displaySummary: String
    let runAt: Date
    let recurrence: Recurrence
    let recurrenceDetail: String?
    let lastRunAt: Date?
    var nextRunAt: Date
    var isActive: Bool
    let createdAt: Date

    /// Parses the stored JSON back into an IntentParams struct.
    func parsedParams() throws -> IntentParams {
        let data = Data(paramsJson.utf8)
        return try JSONDecoder().decode(IntentParams.self, from: data)
    }

    /// Calculates the next run date based on recurrence, or nil if non-recurring.
    func calculatedNextRunAt(from date: Date = Date()) -> Date? {
        let calendar = Calendar.current
        switch recurrence {
        case .none:
            return nil
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: date)
        case .weekly:
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        case .monthly:
            return calendar.date(byAdding: .month, value: 1, to: date)
        case .custom:
            // Custom recurrence requires human-readable parsing; default to weekly as fallback.
            return calendar.date(byAdding: .weekOfYear, value: 1, to: date)
        }
    }
}
