import Foundation

/// Background service that polls for due scheduled actions and executes them via ActionRouter.
/// Runs a timer every 60 seconds for the lifetime of the app.
final class SchedulerService: @unchecked Sendable {

    /// Shared singleton instance.
    static let shared = SchedulerService()

    private let router = ActionRouter()
    private var timer: Timer?

    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {}

    /// Starts the background polling timer. Call once at app launch.
    func start() {
        timer = Timer.scheduledTimer(
            withTimeInterval: Constants.Scheduler.tickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { await self?.tick() }
        }
        print("[SchedulerService] Started — polling every \(Int(Constants.Scheduler.tickInterval))s")
    }

    /// Stops the polling timer.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Scheduling

    /// Saves a new scheduled action derived from a confirmed ParsedIntent.
    /// Uses the first action in the intent's actions array for scheduling metadata.
    func schedule(intent: ParsedIntent, runAt: Date) throws {
        guard let firstAction = intent.firstAction else { return }

        let paramsData = (try? JSONEncoder().encode(firstAction.params)) ?? Data()
        let paramsJson = String(data: paramsData, encoding: .utf8) ?? "{}"

        let recurrence = Recurrence(rawValue: firstAction.params.recurrence ?? "none") ?? .none
        let now = Date()

        let action = ScheduledAction(
            id: UUID().uuidString,
            actionType: firstAction.action,
            paramsJson: paramsJson,
            displaySummary: intent.displaySummary,
            runAt: runAt,
            recurrence: recurrence,
            recurrenceDetail: firstAction.params.recurrenceDetail,
            lastRunAt: nil,
            nextRunAt: runAt,
            isActive: true,
            createdAt: now
        )

        try DatabaseManager.shared.save(action: action)
        print("[SchedulerService] Scheduled: \(intent.displaySummary) at \(runAt)")
    }

    // MARK: - Tick

    /// Checks for due actions and executes them, updating recurrence state.
    private func tick() async {
        let now = Date()
        let dueActions: [ScheduledAction]

        do {
            dueActions = try DatabaseManager.shared.fetchDueActions(before: now)
        } catch {
            print("[SchedulerService] Failed to fetch due actions: \(error)")
            return
        }

        guard !dueActions.isEmpty else { return }
        print("[SchedulerService] Executing \(dueActions.count) due action(s)")

        for action in dueActions {
            await execute(action: action, executedAt: now)
        }
    }

    /// Executes a single due action and updates its state in the database.
    private func execute(action: ScheduledAction, executedAt: Date) async {
        // Reconstruct ParsedIntent for routing
        guard let intent = buildIntent(from: action) else {
            print("[SchedulerService] Could not rebuild intent for action \(action.id)")
            return
        }

        await router.route(intent: intent)

        do {
            if action.recurrence == .none {
                try DatabaseManager.shared.markInactive(id: action.id)
            } else if let nextRun = action.calculatedNextRunAt(from: executedAt) {
                try DatabaseManager.shared.updateAfterExecution(
                    id: action.id,
                    lastRunAt: executedAt,
                    nextRunAt: nextRun
                )
            }
        } catch {
            print("[SchedulerService] Failed to update action \(action.id) after execution: \(error)")
        }
    }

    /// Rebuilds a ParsedIntent from a stored ScheduledAction for routing.
    private func buildIntent(from action: ScheduledAction) -> ParsedIntent? {
        guard let params = try? action.parsedParams() else { return nil }
        let singleAction = SingleAction(
            action: action.actionType,
            params: params,
            displaySummary: action.displaySummary
        )
        return ParsedIntent(actions: [singleAction], displaySummary: action.displaySummary)
    }
}
