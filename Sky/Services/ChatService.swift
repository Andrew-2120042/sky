import Foundation

/// Manages persistent chat conversations with full Sky context.
/// Searches both conversation history and action memory to answer questions.
@MainActor
final class ChatService {
    static let shared = ChatService()
    private init() {}

    struct Message: Identifiable {
        let id: String
        let role: String        // "user" or "assistant"
        let content: String
        let createdAt: Date

        var isUser: Bool { role == "user" }
    }

    /// In-memory messages for the current session.
    private(set) var messages: [Message] = []

    /// Tracks the last primed command for system prompt context injection.
    private(set) var lastPrimedCommand: String = ""
    private var lastPrimedSkyResponse: String = ""

    // MARK: - Public API

    /// Loads persistent history from the database into memory.
    func loadHistory() {
        let rows = DatabaseManager.shared.fetchChatHistory(limit: 100)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        messages = rows.compactMap { row in
            guard let date = formatter.date(from: row.createdAt) else { return nil }
            return Message(id: row.id, role: row.role, content: row.content, createdAt: date)
        }
    }

    /// Sends a user message, persists both sides, and returns the assistant response.
    func send(userMessage: String) async -> String {
        let userID = UUID().uuidString
        let userMsg = Message(id: userID, role: "user", content: userMessage, createdAt: Date())
        messages.append(userMsg)
        DatabaseManager.shared.saveChatMessage(
            id: userID,
            role: "user",
            content: userMessage,
            contextSnapshot: buildContextSnapshot()
        )

        let response = await callAI(userMessage: userMessage)

        let assistantID = UUID().uuidString
        let assistantMsg = Message(id: assistantID, role: "assistant", content: response, createdAt: Date())
        messages.append(assistantMsg)
        DatabaseManager.shared.saveChatMessage(
            id: assistantID,
            role: "assistant",
            content: response,
            contextSnapshot: nil
        )

        return response
    }

    /// Clears in-memory messages and wipes the database.
    func clearHistory() {
        messages = []
        DatabaseManager.shared.clearChatHistory()
    }

    /// Clears only the in-memory messages for a fresh session (DB history is preserved).
    func resetSession() {
        messages = []
    }

    /// Seeds the chat with the last Sky command and response as context so the user
    /// can ask follow-up questions. Context messages are shown in UI but not saved to DB.
    func primeWithContext(userCommand: String, skyResponse: String) {
        lastPrimedCommand = userCommand
        lastPrimedSkyResponse = skyResponse
        let contextUserMsg = Message(
            id: "ctx-user-\(UUID().uuidString)",
            role: "user",
            content: userCommand,
            createdAt: Date().addingTimeInterval(-2)
        )
        let contextAssistantMsg = Message(
            id: "ctx-asst-\(UUID().uuidString)",
            role: "assistant",
            content: skyResponse,
            createdAt: Date().addingTimeInterval(-1)
        )
        messages.insert(contextAssistantMsg, at: 0)
        messages.insert(contextUserMsg, at: 0)
    }

    /// Clears primed context — call when a new command is submitted or Escape is pressed.
    func clearPrimedContext() {
        lastPrimedCommand = ""
        lastPrimedSkyResponse = ""
    }

    // MARK: - Private

    private func buildContextSnapshot() -> String {
        let ctx = ContextService.shared
        var parts: [String] = []
        if let url = ctx.browserURL    { parts.append("browser:\(url)") }
        if let app = ctx.frontmostApp  { parts.append("app:\(app)") }
        return parts.joined(separator: "|")
    }

    private func buildSystemPrompt() -> String {
        let lastExchange: String
        if !lastPrimedCommand.isEmpty {
            lastExchange = """
            CURRENT CONTEXT (what the user just did):
            User said: \(lastPrimedCommand)
            Sky responded: \(String(lastPrimedSkyResponse.prefix(500)))

            The user has opened chat to ask follow-up questions about this.
            Treat this as the active topic unless they clearly change subject.

            """
        } else {
            lastExchange = ""
        }

        let recentActions = DatabaseManager.shared.fetchRecentActionMemory(limit: 10)
        let actionContext = recentActions.isEmpty
            ? "No actions yet."
            : recentActions
                .map { "[\($0.actionType)] \($0.summary) at \($0.createdAt)" }
                .joined(separator: "\n")

        let mem = MemoryService.shared.readMemory()
        var memParts: [String] = []
        if !mem.aliases.isEmpty {
            memParts.append("Aliases: " + mem.aliases.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        if !mem.facts.isEmpty {
            memParts.append("Facts: " + mem.facts.joined(separator: "; "))
        }
        if !mem.preferences.isEmpty {
            memParts.append("Preferences: " + mem.preferences.joined(separator: "; "))
        }
        let memContext = memParts.isEmpty ? "Nothing saved yet." : memParts.joined(separator: "\n")

        let ctx = ContextService.shared
        var currentContext = ""
        if let app    = ctx.frontmostApp      { currentContext += "Active app: \(app)\n" }
        if let url    = ctx.browserURL        { currentContext += "Browser: \(url)\n" }
        if let native = ctx.nativeAppContext  { currentContext += "App content: \(native)\n" }

        return """
        You are Sky — a native macOS AI agent. You have full context of what the user has done on their Mac.

        \(lastExchange)WHAT SKY HAS DONE (action history):
        \(actionContext)

        USER MEMORY:
        \(memContext)

        CURRENT CONTEXT:
        \(currentContext.isEmpty ? "No active context." : currentContext)

        RULES:
        - Answer questions about what Sky did — mails sent, orders placed, reminders set, meetings joined
        - When asked about specific actions (e.g. "what did I send to John"), search your action history and give exact details
        - You can help draft content, answer questions, and explain things
        - Keep responses concise — this is a chat panel, not a document editor
        - If asked to DO something (send mail, set reminder), tell the user to press Escape and use Sky's command mode instead
        - Never make up actions that aren't in the history
        - Format dates in a human-friendly way (e.g. "this morning at 9:30am", "yesterday at 3pm")
        """
    }

    private func buildMessagesArray() -> [[String: Any]] {
        messages.suffix(20).map { ["role": $0.role, "content": $0.content] }
    }

    private func callAI(userMessage: String) async -> String {
        let config = ConfigService.shared.config
        let useOpenAI = config.aiProvider == "openai"
        let apiKey = useOpenAI
            ? config.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            : config.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            return "No API key configured — open Settings to add one."
        }
        do {
            return try await useOpenAI
                ? callOpenAI(apiKey: apiKey)
                : callAnthropic(apiKey: apiKey)
        } catch {
            return "Sorry, I couldn't connect right now. Try again in a moment."
        }
    }

    private func callAnthropic(apiKey: String) async throws -> String {
        let body: [String: Any] = [
            "model": Constants.API.model,
            "max_tokens": 1024,
            "system": buildSystemPrompt(),
            "messages": buildMessagesArray()
        ]
        var request = URLRequest(url: URL(string: Constants.API.anthropicBaseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.API.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (json?["content"] as? [[String: Any]])?.first
        return content?["text"] as? String ?? "No response"
    }

    private func callOpenAI(apiKey: String) async throws -> String {
        var msgs: [[String: Any]] = [["role": "system", "content": buildSystemPrompt()]]
        msgs.append(contentsOf: buildMessagesArray())
        let body: [String: Any] = [
            "model": Constants.OpenAI.model,
            "max_tokens": 1024,
            "messages": msgs
        ]
        var request = URLRequest(url: URL(string: Constants.OpenAI.baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? "No response"
    }
}
