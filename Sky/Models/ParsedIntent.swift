import Foundation

/// Parameters extracted by the AI intent parser.
struct IntentParams: Codable {
    let to: String?
    let body: String?
    let subject: String?
    let datetime: String?
    let recurrence: String?
    let recurrenceDetail: String?
    let url: String?
    let query: String?
    let appName: String?
    let durationMinutes: Int?
    let confidence: String?
    /// Step descriptions for create_workflow actions (e.g. ["open Slack", "open Calendar"]).
    let workflowSteps: [String]?
    /// Category for save_memory: "alias" | "fact" | "preference"
    let memoryCategory: String?
    /// Alias key for save_memory category "alias" (e.g. "mum").
    let memoryKey: String?
    /// Value to store: alias target, fact text, or preference text.
    let memoryValue: String?
    /// Step descriptions for computer_use multi-step sequences.
    let steps: [String]?

    enum CodingKeys: String, CodingKey {
        case to, body, subject, datetime, recurrence, url, query, confidence
        case recurrenceDetail = "recurrence_detail"
        case appName          = "app_name"
        case durationMinutes  = "duration_minutes"
        case workflowSteps    = "workflow_steps"
        case memoryCategory   = "memory_category"
        case memoryKey        = "memory_key"
        case memoryValue      = "memory_value"
        case steps
    }

    /// Default init with all-nil params — used as fallback during backward-compat decoding.
    init(to: String? = nil, body: String? = nil, subject: String? = nil,
         datetime: String? = nil, recurrence: String? = nil, recurrenceDetail: String? = nil,
         url: String? = nil, query: String? = nil, appName: String? = nil,
         durationMinutes: Int? = nil, confidence: String? = nil, workflowSteps: [String]? = nil,
         memoryCategory: String? = nil, memoryKey: String? = nil, memoryValue: String? = nil,
         steps: [String]? = nil) {
        self.to = to; self.body = body; self.subject = subject
        self.datetime = datetime; self.recurrence = recurrence; self.recurrenceDetail = recurrenceDetail
        self.url = url; self.query = query; self.appName = appName
        self.durationMinutes = durationMinutes; self.confidence = confidence
        self.workflowSteps = workflowSteps
        self.memoryCategory = memoryCategory; self.memoryKey = memoryKey; self.memoryValue = memoryValue
        self.steps = steps
    }

    /// Returns a copy of these params with `to` replaced by `newTo`.
    func copyWith(to newTo: String) -> IntentParams {
        IntentParams(
            to: newTo, body: body, subject: subject,
            datetime: datetime, recurrence: recurrence, recurrenceDetail: recurrenceDetail,
            url: url, query: query, appName: appName,
            durationMinutes: durationMinutes, confidence: confidence,
            workflowSteps: workflowSteps,
            memoryCategory: memoryCategory, memoryKey: memoryKey, memoryValue: memoryValue,
            steps: steps
        )
    }
}

/// A single discrete action within a (possibly multi-step) intent.
struct SingleAction: Codable {
    let action: String
    let params: IntentParams
    let displaySummary: String

    enum CodingKeys: String, CodingKey {
        case action, params
        case displaySummary = "display_summary"
    }
}

/// The fully parsed intent returned by the AI provider.
/// Supports multi-step commands — `actions` always contains at least one element.
struct ParsedIntent: Codable {
    /// All actions to execute in order.
    let actions: [SingleAction]
    /// Overall summary shown in the confirmation card.
    let displaySummary: String

    /// Convenience accessor for the first (most commonly only) action.
    var firstAction: SingleAction? { actions.first }

    enum CodingKeys: String, CodingKey {
        case actions
        case displaySummary = "display_summary"
        // Legacy single-action keys
        case legacyAction  = "action"
        case legacyParams  = "params"
    }

    /// Custom decoder: accepts both the new `actions` array format and the legacy
    /// single-action format (`action` / `params` at root level).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displaySummary = (try? c.decode(String.self, forKey: .displaySummary)) ?? ""

        if let acts = try? c.decode([SingleAction].self, forKey: .actions), !acts.isEmpty {
            actions = acts
        } else if let legacyAction = try? c.decode(String.self, forKey: .legacyAction) {
            let params = (try? c.decode(IntentParams.self, forKey: .legacyParams)) ?? IntentParams()
            let summary = displaySummary.isEmpty ? legacyAction : displaySummary
            actions = [SingleAction(action: legacyAction, params: params, displaySummary: summary)]
        } else {
            actions = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(actions, forKey: .actions)
        try c.encode(displaySummary, forKey: .displaySummary)
    }

    init(actions: [SingleAction], displaySummary: String) {
        self.actions = actions
        self.displaySummary = displaySummary
    }
}

/// Typed errors thrown by the IntentParser.
enum IntentParserError: LocalizedError {
    case missingAPIKey
    case networkError(Error)
    case apiError(statusCode: Int, message: String)
    case decodingError(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "API key is not configured."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let code, let message):
            return "API error \(code): \(message)"
        case .decodingError(let detail):
            return "Failed to parse AI response: \(detail)"
        }
    }
}
