import Foundation
import SQLite

/// Manages the SQLite database for scheduled actions.
/// Database lives at ~/Library/Application Support/Sky/scheduler.db
final class DatabaseManager {

    /// Shared singleton instance. nonisolated(unsafe) because DatabaseManager serialises its
    /// own access via SQLite's internal locking.
    nonisolated(unsafe) static let shared = DatabaseManager()

    private var db: Connection?

    // MARK: - Table and Column Expressions

    private let scheduledActionsTable = Table(Constants.Database.Table.scheduledActions)

    private let colId             = Expression<String>(Constants.Database.Column.id)
    private let colActionType     = Expression<String>(Constants.Database.Column.actionType)
    private let colParamsJson     = Expression<String>(Constants.Database.Column.paramsJson)
    private let colDisplaySummary = Expression<String>(Constants.Database.Column.displaySummary)
    private let colRunAt          = Expression<String>(Constants.Database.Column.runAt)
    private let colRecurrence     = Expression<String>(Constants.Database.Column.recurrence)
    private let colRecurrenceDetail = Expression<String?>(Constants.Database.Column.recurrenceDetail)
    private let colLastRunAt      = Expression<String?>(Constants.Database.Column.lastRunAt)
    private let colNextRunAt      = Expression<String>(Constants.Database.Column.nextRunAt)
    private let colIsActive       = Expression<Int>(Constants.Database.Column.isActive)
    private let colCreatedAt      = Expression<String>(Constants.Database.Column.createdAt)

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        setupDatabase()
    }

    /// Opens the database connection and creates tables if needed.
    private func setupDatabase() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent(Constants.App.supportDirectoryName)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let dbPath = directory.appendingPathComponent(Constants.Database.fileName).path
            db = try Connection(dbPath)
            try createTables()
            print("[DatabaseManager] Database ready at: \(dbPath)")
        } catch {
            print("[DatabaseManager] Setup failed: \(error)")
        }
    }

    /// Creates the scheduled_actions table if it does not already exist.
    private func createTables() throws {
        guard let db else { return }
        try db.run(scheduledActionsTable.create(ifNotExists: true) { t in
            t.column(colId, primaryKey: true)
            t.column(colActionType)
            t.column(colParamsJson)
            t.column(colDisplaySummary)
            t.column(colRunAt)
            t.column(colRecurrence, defaultValue: Recurrence.none.rawValue)
            t.column(colRecurrenceDetail)
            t.column(colLastRunAt)
            t.column(colNextRunAt)
            t.column(colIsActive, defaultValue: 1)
            t.column(colCreatedAt)
        })
    }

    // MARK: - CRUD

    /// Saves a new scheduled action to the database.
    func save(action: ScheduledAction) throws {
        guard let db else { return }
        try db.run(scheduledActionsTable.insert(
            colId             <- action.id,
            colActionType     <- action.actionType,
            colParamsJson     <- action.paramsJson,
            colDisplaySummary <- action.displaySummary,
            colRunAt          <- Self.iso8601.string(from: action.runAt),
            colRecurrence     <- action.recurrence.rawValue,
            colRecurrenceDetail <- action.recurrenceDetail,
            colLastRunAt      <- action.lastRunAt.map { Self.iso8601.string(from: $0) },
            colNextRunAt      <- Self.iso8601.string(from: action.nextRunAt),
            colIsActive       <- action.isActive ? 1 : 0,
            colCreatedAt      <- Self.iso8601.string(from: action.createdAt)
        ))
    }

    /// Fetches all active scheduled actions whose next_run_at is on or before the given date.
    func fetchDueActions(before date: Date = Date()) throws -> [ScheduledAction] {
        guard let db else { return [] }
        let dateString = Self.iso8601.string(from: date)
        let query = scheduledActionsTable
            .filter(colIsActive == 1)
            .filter(colNextRunAt <= dateString)
        return try db.prepare(query).compactMap { row in
            rowToScheduledAction(row)
        }
    }

    /// Marks a scheduled action as inactive (soft-delete for non-recurring).
    func markInactive(id: String) throws {
        guard let db else { return }
        let action = scheduledActionsTable.filter(colId == id)
        try db.run(action.update(colIsActive <- 0))
    }

    /// Updates next_run_at and last_run_at after a recurring action executes.
    func updateAfterExecution(id: String, lastRunAt: Date, nextRunAt: Date) throws {
        guard let db else { return }
        let action = scheduledActionsTable.filter(colId == id)
        try db.run(action.update(
            colLastRunAt <- Self.iso8601.string(from: lastRunAt),
            colNextRunAt <- Self.iso8601.string(from: nextRunAt)
        ))
    }

    // MARK: - Helpers

    /// Converts a SQLite row into a ScheduledAction model.
    private func rowToScheduledAction(_ row: Row) -> ScheduledAction? {
        guard
            let runAt = Self.iso8601.date(from: row[colRunAt]),
            let nextRunAt = Self.iso8601.date(from: row[colNextRunAt]),
            let createdAt = Self.iso8601.date(from: row[colCreatedAt]),
            let recurrence = Recurrence(rawValue: row[colRecurrence])
        else { return nil }

        let lastRunAt: Date? = row[colLastRunAt].flatMap { Self.iso8601.date(from: $0) }

        return ScheduledAction(
            id: row[colId],
            actionType: row[colActionType],
            paramsJson: row[colParamsJson],
            displaySummary: row[colDisplaySummary],
            runAt: runAt,
            recurrence: recurrence,
            recurrenceDetail: row[colRecurrenceDetail],
            lastRunAt: lastRunAt,
            nextRunAt: nextRunAt,
            isActive: row[colIsActive] == 1,
            createdAt: createdAt
        )
    }
}
