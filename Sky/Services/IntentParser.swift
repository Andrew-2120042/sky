import Foundation

/// Sends user input to the configured AI provider and decodes the structured intent response.
/// Prepends date/time and clipboard context to every request for reliable parsing.
final class IntentParser: Sendable {

    // MARK: - Public API

    /// Parses a natural language string into a structured ParsedIntent.
    /// `history` contains prior (userMessage, assistantResponseJSON) pairs for clarification follow-ups.
    func parse(input: String,
               history: [(userMessage: String, assistantResponse: String)] = []) async throws -> ParsedIntent {
        let config = await MainActor.run { ConfigService.shared.config }
        let fullInput = await buildFullInput(userInput: input)

        if config.aiProvider == "openai" {
            let apiKey = config.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else { throw IntentParserError.missingAPIKey }
            return try await parseWithOpenAI(fullInput: fullInput, history: history, apiKey: apiKey)
        } else {
            let apiKey = config.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty else { throw IntentParserError.missingAPIKey }
            return try await parseWithAnthropic(fullInput: fullInput, history: history, apiKey: apiKey)
        }
    }

    // MARK: - Context Building

    /// Builds the full user message with date/time context and clipboard/app/selection blocks prepended.
    private func buildFullInput(userInput: String) async -> String {
        // Date context — gives the model an exact anchor for relative time resolution
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d, yyyy 'at' h:mm a"
        formatter.timeZone = TimeZone.current
        let nowString = formatter.string(from: Date())
        let tzID = TimeZone.current.identifier
        let contextPrefix = "[Context: Today is \(nowString), timezone \(tzID). Resolve ALL relative times — 'tomorrow', '9am', 'next Monday', 'in 2 hours' — against this exact date and time. Return datetime as ISO8601 with the correct timezone offset. Never default to a past date or wrong year.]"

        // Clipboard / active-app / selected-text / browser context
        let (clip, app, sel, bURL, bTitle) = await MainActor.run {
            (ContextService.shared.clipboardText,
             ContextService.shared.frontmostApp,
             ContextService.shared.selectedText,
             ContextService.shared.browserURL,
             ContextService.shared.browserPageTitle)
        }
        var contextLines: [String] = []
        if let clip, !clip.isEmpty {
            contextLines.append("[Clipboard: \(String(clip.prefix(200)))]")
        }
        if let app {
            contextLines.append("[Active app: \(app)]")
        }
        if let sel, !sel.isEmpty {
            contextLines.append("[Selected text: \(String(sel.prefix(200)))]")
        }
        if let bURL, !bURL.isEmpty {
            let titlePart = bTitle.map { " — \"\($0)\"" } ?? ""
            contextLines.append("[Browser: \(app ?? "Browser")\(titlePart) — \(bURL)]")
        }

        // Memory context — inject aliases, facts, and preferences so the model can use them
        let mem = MemoryService.shared.readMemory()
        if !mem.aliases.isEmpty {
            let list = mem.aliases.map { "\($0.key) → \($0.value)" }.joined(separator: ", ")
            contextLines.append("[Memory — Aliases: \(list)]")
        }
        if !mem.facts.isEmpty {
            contextLines.append("[Memory — Facts: \(mem.facts.joined(separator: "; "))]")
        }
        if !mem.preferences.isEmpty {
            contextLines.append("[Memory — Preferences: \(mem.preferences.joined(separator: "; "))]")
        }

        // Recent actions context — helps Claude resolve "that", "it", "the same person"
        let recentActions = ActionLogService.shared.recentActions.prefix(3)
        if !recentActions.isEmpty {
            let actionsText = recentActions.map { "- \($0.summary)" }.joined(separator: "\n")
            contextLines.append("[Recent actions:\n\(actionsText)]")
        }

        let contextBlock = contextLines.isEmpty ? "" : "\n" + contextLines.joined(separator: "\n")
        return "\(contextPrefix)\(contextBlock)\n\(userInput)"
    }

    // MARK: - Anthropic

    private func parseWithAnthropic(fullInput: String,
                                    history: [(userMessage: String, assistantResponse: String)],
                                    apiKey: String) async throws -> ParsedIntent {
        // Build messages array including prior session turns for clarification context
        var messages: [AnthropicMessage] = []
        for exchange in history {
            messages.append(AnthropicMessage(role: "user",      content: exchange.userMessage))
            messages.append(AnthropicMessage(role: "assistant", content: exchange.assistantResponse))
        }
        messages.append(AnthropicMessage(role: "user", content: fullInput))

        let requestBody = AnthropicRequest(
            model: Constants.API.model,
            maxTokens: Constants.API.maxTokens,
            system: Constants.systemPrompt,
            messages: messages
        )

        let bodyData: Data
        do {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            bodyData = try encoder.encode(requestBody)
        } catch {
            throw IntentParserError.decodingError("Failed to encode request: \(error)")
        }

        var request = URLRequest(url: URL(string: Constants.API.anthropicBaseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.API.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = bodyData

        let (data, response) = try await fetchData(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw IntentParserError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        let anthropicResponse: AnthropicResponse
        do {
            anthropicResponse = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        } catch {
            throw IntentParserError.decodingError("Failed to decode Anthropic response: \(error)")
        }

        guard let textContent = anthropicResponse.content.first(where: { $0.type == "text" })?.text,
              !textContent.isEmpty else {
            throw IntentParserError.decodingError("Empty response from Anthropic API")
        }

        return try decodeIntent(from: textContent)
    }

    // MARK: - OpenAI

    private func parseWithOpenAI(fullInput: String,
                                 history: [(userMessage: String, assistantResponse: String)],
                                 apiKey: String) async throws -> ParsedIntent {
        // Build messages array including prior session turns
        var messages: [[String: String]] = [
            ["role": "system", "content": Constants.systemPrompt]
        ]
        for exchange in history {
            messages.append(["role": "user",      "content": exchange.userMessage])
            messages.append(["role": "assistant", "content": exchange.assistantResponse])
        }
        messages.append(["role": "user", "content": fullInput])

        let bodyDict: [String: Any] = [
            "model": Constants.OpenAI.model,
            "messages": messages,
            "response_format": ["type": "json_object"],
            "max_tokens": Constants.API.maxTokens
        ]

        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: bodyDict)
        } catch {
            throw IntentParserError.decodingError("Failed to encode OpenAI request: \(error)")
        }

        var request = URLRequest(url: URL(string: Constants.OpenAI.baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        let (data, response) = try await fetchData(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw IntentParserError.apiError(statusCode: httpResponse.statusCode, message: message)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String,
              !content.isEmpty else {
            throw IntentParserError.decodingError("Unexpected OpenAI response format")
        }

        return try decodeIntent(from: content)
    }

    // MARK: - Shared helpers

    private func fetchData(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw IntentParserError.networkError(error)
        }
    }

    private func decodeIntent(from text: String) throws -> ParsedIntent {
        guard let intentData = text.data(using: .utf8) else {
            throw IntentParserError.decodingError("Could not encode response text as UTF-8")
        }
        do {
            return try JSONDecoder().decode(ParsedIntent.self, from: intentData)
        } catch {
            throw IntentParserError.decodingError("Failed to decode intent JSON: \(error)\nRaw: \(text)")
        }
    }
}

// MARK: - Anthropic API Request/Response Types

/// Request body sent to the Anthropic messages API.
private struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String
    let messages: [AnthropicMessage]
}

/// A single message in the Anthropic conversation.
private struct AnthropicMessage: Encodable {
    let role: String
    let content: String
}

/// The top-level response from the Anthropic messages API.
private struct AnthropicResponse: Decodable {
    let content: [AnthropicContent]
}

/// A single content block in the Anthropic response.
private struct AnthropicContent: Decodable {
    let type: String
    let text: String?
}
