import Foundation
import AppKit

/// Represents the current UI state of the floating panel.
enum PanelState {
    /// Waiting for user input
    case idle
    /// API request in flight
    case loading
    /// Parsed intent ready — show confirmation card
    case confirmation(ParsedIntent)
    /// Something went wrong — show error inline
    case error(String)
    /// Prompting for API key before first use
    case awaitingAPIKey
    /// Action executed successfully — auto-dismisses after 1.5 s
    case success(String)
    /// AI returned unknown/low-confidence — show clarifying question, keep input active
    case clarifying(question: String)
    /// Destructive action (send_mail / send_message) counting down before auto-executing
    case countdown(intent: ParsedIntent, secondsLeft: Int)
    /// AI or action returned an informational answer — show inline, no buttons
    case answer(text: String)
    /// A workflow trigger matched — show confirmation before running
    case workflowConfirmation(WorkflowService.Workflow)
    /// Multiple contacts matched params.to — needs disambiguation via dropdown
    case asking(question: String, candidates: [ResolvedContact], pendingIntent: ParsedIntent)
    /// Headless browser is about to take an irreversible action — needs user confirmation
    case browserConfirmation(message: String, target: String)
}

/// MVVM ViewModel — owns all panel state and orchestrates parsing + routing.
@MainActor
final class PanelViewModel: ObservableObject {

    /// Current UI state that drives the panel's appearance.
    @Published private(set) var state: PanelState = .idle

    /// Text currently typed in the input field.
    @Published var inputText: String = ""

    /// Contact suggestions shown in the @mention dropdown.
    @Published private(set) var contactSuggestions: [ResolvedContact] = []

    private let parser = IntentParser()
    private let router = ActionRouter()
    private var browserConfirmationObserver: Any?

    /// In-memory session history for clarification follow-ups (max 3 exchanges, never persisted).
    private var sessionHistory: [(userMessage: String, assistantResponse: String)] = []

    /// Running countdown task for destructive actions; cancelled on reset/cancel.
    private var countdownTask: Task<Void, Never>?

    // MARK: - Init / Deinit

    init() {
        browserConfirmationObserver = NotificationCenter.default.addObserver(
            forName: Constants.NotificationName.skyBrowserConfirmation,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let msg = note.userInfo?["message"] as? String ?? "About to take an action. Confirm?"
            let target = note.userInfo?["target"] as? String ?? ""
            MainActor.assumeIsolated { self?.state = .browserConfirmation(message: msg, target: target) }
        }
    }

    // MARK: - Public API

    /// Called when the user presses Enter in the input field.
    func submit() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard ConfigService.shared.hasAPIKey else {
            state = .awaitingAPIKey
            return
        }

        // 1. Quick answers — instant, no API call
        if let answer = tryQuickAnswer(input: text) {
            inputText = ""
            state = .answer(text: answer)
            return
        }

        // 2. Client-side show_log / show_memory detection
        let lower = text.lowercased()
        let logTriggers = ["what did i", "recent actions", "what did you", "show log", "what did sky"]
        if logTriggers.contains(where: { lower.contains($0) }) {
            showActionLog()
            return
        }
        let memoryTriggers = ["what do you know", "show memory", "what do you remember",
                              "what do u know", "what do u remember", "my memory",
                              "what have you remembered", "what have u remembered",
                              "do you remember", "do u remember"]
        if memoryTriggers.contains(where: { lower.contains($0) }) {
            inputText = ""
            showMemory()
            return
        }

        // 3. Workflow match — no API call
        if let workflow = WorkflowService.shared.match(input: text) {
            inputText = ""
            state = .workflowConfirmation(workflow)
            return
        }

        // 4. API call
        let historySnapshot = sessionHistory
        state = .loading

        Task {
            do {
                let intent = try await parser.parse(input: text, history: historySnapshot)

                // All-answer intent — skip confirmation card, show inline
                if intent.actions.allSatisfy({ $0.action == Constants.ActionType.answer }) {
                    inputText = ""
                    sessionHistory = []
                    state = .answer(text: intent.firstAction?.params.body ?? intent.displaySummary)
                    return
                }

                // show_memory returned by API — handle client-side (same as show_log)
                if intent.actions.allSatisfy({ $0.action == Constants.ActionType.showMemory }) {
                    inputText = ""
                    sessionHistory = []
                    showMemory()
                    return
                }

                // show_log returned by API — handle client-side
                if intent.actions.allSatisfy({ $0.action == Constants.ActionType.showLog }) {
                    inputText = ""
                    sessionHistory = []
                    showActionLog()
                    return
                }

                // Unknown or low-confidence single action → enter clarifying mode
                if intent.actions.count == 1,
                   let first = intent.firstAction,
                   first.action == Constants.ActionType.unknown || first.params.confidence == "low" {

                    let responseJSON = (try? String(data: JSONEncoder().encode(intent), encoding: .utf8)) ?? ""
                    sessionHistory.append((userMessage: text, assistantResponse: responseJSON))
                    if sessionHistory.count > 3 { sessionHistory.removeFirst() }

                    inputText = ""
                    state = .clarifying(question: intent.displaySummary)
                } else {
                    // Ambiguity check — if params.to resolves to multiple contacts, ask the user
                    if let toName = intent.firstAction?.params.to,
                       !toName.contains("@") {
                        let candidates = ContactsService.shared.findAll(name: toName)
                        if candidates.count > 1 {
                            inputText = ""
                            contactSuggestions = candidates
                            state = .asking(
                                question: "Which \(toName) did you mean?",
                                candidates: candidates,
                                pendingIntent: intent
                            )
                            return
                        }
                    }
                    state = .confirmation(intent)
                }
            } catch {
                state = .error(error.localizedDescription)
            }
        }
    }

    /// Called when the user saves an API key for the first time (single-field legacy path).
    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        ConfigService.shared.setAPIKey(trimmed)
        inputText = ""
        state = .idle
    }

    /// Saves both API keys and the selected provider, then transitions to idle.
    func saveKeys(anthropicKey: String, openaiKey: String, provider: String) {
        ConfigService.shared.saveKeys(
            anthropicKey: anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines),
            openaiKey: openaiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider
        )
        inputText = ""
        state = .idle
    }

    /// Called when the user taps "Do it" on the confirmation card.
    /// Destructive actions (send_mail, send_message) start a 2-second countdown.
    func confirm(intent: ParsedIntent) {
        let firstAction = intent.firstAction?.action
        let isDestructive = firstAction == Constants.ActionType.sendMail
                         || firstAction == Constants.ActionType.sendMessage

        if isDestructive {
            startCountdown(for: intent)
        } else {
            state = .loading
            Task {
                let results = await router.route(intent: intent)
                applyResults(results)
            }
        }
    }

    /// Executes all steps in a workflow sequentially.
    func runWorkflow(_ workflow: WorkflowService.Workflow) {
        state = .loading
        Task { [weak self] in
            guard let self else { return }
            var actions: [SingleAction] = []
            for step in workflow.steps {
                let paramsData = step.paramsJSON.data(using: .utf8) ?? Data()
                let params = (try? JSONDecoder().decode(IntentParams.self, from: paramsData)) ?? IntentParams()
                actions.append(SingleAction(action: step.actionType, params: params, displaySummary: step.description))
            }
            guard !actions.isEmpty else {
                self.state = .error("Workflow '\(workflow.trigger)' has no valid steps")
                return
            }
            let intent = ParsedIntent(actions: actions, displaySummary: "Workflow: \(workflow.trigger)")
            let results = await self.router.route(intent: intent)
            self.applyResults(results)
        }
    }

    /// Cancels any in-flight countdown and resets the panel.
    func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        reset()
    }

    /// Dismisses the inline answer view without clearing the input.
    func dismissAnswer() {
        if case .answer = state { state = .idle }
    }

    /// Resolves an ambiguous contact: rebuilds the intent with the selected contact's identifier
    /// and transitions to the confirmation state.
    func resolveAmbiguity(contact: ResolvedContact) {
        guard case .asking(_, _, let pendingIntent) = state else { return }
        contactSuggestions = []
        let resolvedTo = contact.email ?? contact.displayName
        let updatedActions = pendingIntent.actions.map { action in
            let newParams = action.params.copyWith(to: resolvedTo)
            return SingleAction(action: action.action, params: newParams, displaySummary: action.displaySummary)
        }
        let updatedIntent = ParsedIntent(actions: updatedActions, displaySummary: pendingIntent.displaySummary)
        state = .confirmation(updatedIntent)
    }

    /// Cancels the asking/disambiguation state and returns to idle (preserving any typed text).
    func cancelAsking() {
        contactSuggestions = []
        state = .idle
    }

    /// Called when the user taps Allow Once, Allow Always, or Cancel on the browser confirmation card.
    func confirmBrowserAction(confirm: Bool, always: Bool = false) {
        if confirm, always, case .browserConfirmation(_, let target) = state {
            BrowserConfirmationStore.setAlwaysAllowed(target: target)
        }
        HeadlessBrowserService.shared.confirmAction(confirm: confirm)
        if !confirm {
            state = .answer(text: "Action cancelled.")
        } else {
            state = .loading
        }
    }

    /// Called when the user presses Escape.
    func reset() {
        countdownTask?.cancel()
        countdownTask = nil
        inputText = ""
        contactSuggestions = []
        sessionHistory = []
        state = .idle
    }

    // MARK: - Contact @mention

    /// Updates contact suggestions based on the query that follows an @ sign.
    func updateContactSuggestions(query: String) {
        if query.isEmpty {
            contactSuggestions = []
        } else {
            contactSuggestions = ContactsService.shared.search(query: query)
        }
    }

    /// Replaces the current @mention text with the selected contact's display name.
    func selectContact(_ contact: ResolvedContact, replacingMention mentionRange: Range<String.Index>) {
        inputText = inputText.replacingCharacters(in: mentionRange, with: contact.displayName)
        contactSuggestions = []
    }

    // MARK: - Private

    /// Starts the 2-second countdown then auto-executes the action.
    private func startCountdown(for intent: ParsedIntent) {
        state = .countdown(intent: intent, secondsLeft: 2)
        countdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.state = .countdown(intent: intent, secondsLeft: 1)

            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.state = .loading
            let results = await self.router.route(intent: intent)
            self.applyResults(results)
        }
    }

    /// Attempts a fast client-side answer. Returns nil if the input needs an API call.
    private func tryQuickAnswer(input: String) -> String? {
        let lower = input.lowercased().trimmingCharacters(in: .whitespaces)

        // Current time
        if lower == "time" || lower == "what time is it" || lower == "what's the time" {
            let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
            return f.string(from: Date())
        }

        // Current date
        if lower == "date" || lower == "what's today" || lower == "what day is it" {
            let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .none
            return f.string(from: Date())
        }

        // Math
        return CalculatorService.shared.evaluate(input)
    }

    /// Shows the user's saved memory in the answer view (no API call).
    private func showMemory() {
        let mem = MemoryService.shared.readMemory()
        var parts: [String] = []
        if !mem.aliases.isEmpty {
            let list = mem.aliases.map { "\($0.key) → \($0.value)" }.sorted().joined(separator: "\n  ")
            parts.append("Aliases:\n  \(list)")
        }
        if !mem.facts.isEmpty {
            parts.append("Facts:\n  " + mem.facts.joined(separator: "\n  "))
        }
        if !mem.preferences.isEmpty {
            parts.append("Preferences:\n  " + mem.preferences.joined(separator: "\n  "))
        }
        if !mem.frequentContacts.isEmpty {
            let top = MemoryService.shared.topContacts.map { "\($0.name) (\($0.count)×)" }.joined(separator: ", ")
            parts.append("Frequent contacts: \(top)")
        }
        if parts.isEmpty {
            state = .clarifying(question: "No memory stored yet — ask me to remember something!")
        } else {
            state = .answer(text: parts.joined(separator: "\n\n"))
        }
    }

    /// Shows the last 5 action log entries in the answer view (no API call).
    private func showActionLog() {
        let entries = ActionLogService.shared.recentActions.prefix(5)
        guard !entries.isEmpty else {
            state = .clarifying(question: "No actions logged yet — try a command first!")
            return
        }
        let fmt = DateFormatter(); fmt.timeStyle = .short; fmt.dateStyle = .none
        let lines = entries.map { "\($0.succeeded ? "✓" : "✗") \(fmt.string(from: $0.executedAt)) \($0.summary)" }
        state = .answer(text: lines.joined(separator: "\n"))
    }

    /// Applies an array of ActionResults to panel state, building a combined success message.
    private func applyResults(_ results: [ActionResult]) {
        let answers   = results.compactMap { if case .answer(let t)    = $0 { return t } else { return nil } }
        let successes = results.compactMap { if case .success(let m)   = $0, !m.isEmpty { return m } else { return nil } }
        let scheduled = results.compactMap { if case .scheduled(let m) = $0 { return m } else { return nil } }
        let failures  = results.compactMap { if case .failure(let m)   = $0 { return m } else { return nil } }

        inputText = ""
        contactSuggestions = []
        sessionHistory = []

        // Pure answer results — show inline
        if !answers.isEmpty && successes.isEmpty && scheduled.isEmpty && failures.isEmpty {
            state = .answer(text: answers.joined(separator: "\n\n"))
            return
        }

        // If everything failed, show the first error
        if answers.isEmpty && successes.isEmpty && scheduled.isEmpty {
            state = .error(failures.first ?? "Action failed")
            return
        }

        // Build combined success message; include answer text + partial failures as warnings
        var parts: [String] = answers + successes + scheduled
        if !failures.isEmpty {
            parts.append("⚠️ \(failures.joined(separator: ", "))")
        }
        state = .success(parts.joined(separator: " · "))
        scheduleDismiss()
    }

    /// Hides the panel 1.5 s after a success state, unless the state has changed.
    private func scheduleDismiss() {
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if case .success = state {
                reset()
                NotificationCenter.default.post(name: Constants.NotificationName.hidePanel, object: nil)
            }
        }
    }
}
