import Foundation

/// Stores, matches, and persists custom user-defined workflows.
/// Workflows are triggered by a phrase and execute a sequence of actions without an API call.
final class WorkflowService: @unchecked Sendable {

    static let shared = WorkflowService()

    // MARK: - Types

    struct Workflow: Codable, Sendable {
        let id: UUID
        var trigger: String
        var steps: [WorkflowStep]
        var createdAt: Date
    }

    struct WorkflowStep: Codable, Sendable {
        let id: UUID
        var description: String
        var actionType: String
        var paramsJSON: String
    }

    // MARK: - State

    private(set) var workflows: [Workflow] = []
    private let storageURL: URL
    private let lock = NSLock()

    // MARK: - Init

    private init() {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        let skyDir = support.appendingPathComponent("Sky", isDirectory: true)
        try? FileManager.default.createDirectory(at: skyDir, withIntermediateDirectories: true)
        storageURL = skyDir.appendingPathComponent("workflows.json")
        load()
    }

    // MARK: - CRUD

    func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([Workflow].self, from: data),
              !decoded.isEmpty else {
            seedDefaultWorkflows()
            return
        }
        lock.withLock { workflows = decoded }
    }

    func save(_ workflow: Workflow) throws {
        lock.withLock {
            if let idx = workflows.firstIndex(where: { $0.id == workflow.id }) {
                workflows[idx] = workflow
            } else {
                workflows.append(workflow)
            }
        }
        try persist()
    }

    func delete(id: UUID) {
        lock.withLock { workflows.removeAll { $0.id == id } }
        try? persist()
    }

    // MARK: - Match

    /// Returns the first workflow whose trigger phrase is contained in `input` (case-insensitive).
    func match(input: String) -> Workflow? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lock.withLock {
            workflows.first { lower.contains($0.trigger.lowercased()) }
        }
    }

    // MARK: - Private

    private func persist() throws {
        let data = try JSONEncoder().encode(lock.withLock { workflows })
        try data.write(to: storageURL, options: .atomic)
    }

    /// Seeds two built-in workflows on first launch when no persisted data exists.
    private func seedDefaultWorkflows() {
        let calendarStep = WorkflowStep(
            id: UUID(),
            description: "Show today's calendar events",
            actionType: Constants.ActionType.readCalendarToday,
            paramsJSON: "{}"
        )
        let morning = Workflow(
            id: UUID(),
            trigger: "morning briefing",
            steps: [calendarStep],
            createdAt: Date()
        )
        let startDay = Workflow(
            id: UUID(),
            trigger: "start my day",
            steps: [calendarStep],
            createdAt: Date()
        )
        lock.withLock { workflows = [morning, startDay] }
        try? persist()
    }
}
