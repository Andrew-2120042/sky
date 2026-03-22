import Foundation
import AppKit

struct FlowStep: Equatable {
    let id: UUID
    let text: String
    let status: FlowStepStatus
}

enum FlowStepStatus: Equatable {
    case running    // ⏳
    case success    // ✅
    case failed     // ❌
}

enum SkillCreationStage: Equatable {
    case waitingForDescription
    case generating
    case testing(goal: String)
    case awaitingFeedback(failedStep: String, question: String)
    case saved(skillName: String)
}

/// A single installed skill shown in the skills list view.
struct SkillCard: Equatable {
    let name: String          // e.g. "flipkart_order"
    let displayName: String   // e.g. "Flipkart Order"
    let overview: String
    let triggers: String      // e.g. "flipkart, order"
    let mode: String
    let filePath: String
}

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
    /// Live progress view for a running headless browser flow
    case flowRunning(goal: String, steps: [FlowStep], canCancel: Bool)
    /// Compact minimized state while flow runs in background
    case flowMinimized(goal: String, stepCount: Int)
    /// Skill creation wizard
    case skillCreation(stage: SkillCreationStage)
    /// Interactive list of installed skills with edit/delete buttons
    case skillsList(skills: [SkillCard])
    /// Inline JSON editor for a single skill
    case skillEdit(card: SkillCard)
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

    // MARK: - Flow progress state
    private(set) var currentFlowGoal: String = ""
    private(set) var flowSteps: [FlowStep] = []
    private var isFlowHandled = false

    // MARK: - Skill creation state
    private(set) var isInSkillCreationMode: Bool = false
    private var skillCreationDescription: String = ""
    private var generatedSkillJSON: String = ""
    private var skillCreationName: String = ""

    // MARK: - Flow/skill notification observers
    private var flowStartedObserver: Any?
    private var flowStepObserver: Any?
    private var flowFinishedObserver: Any?
    private var skillCreationObserver: Any?
    private var editSkillObserver: Any?

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

        flowStartedObserver = NotificationCenter.default.addObserver(
            forName: Constants.NotificationName.flowStarted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let goal = note.userInfo?["goal"] as? String ?? ""
            MainActor.assumeIsolated { self?.startFlow(goal: goal) }
        }

        flowStepObserver = NotificationCenter.default.addObserver(
            forName: Constants.NotificationName.flowStep,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let msg = note.userInfo?["message"] as? String ?? ""
            MainActor.assumeIsolated { self?.addFlowStep(msg) }
        }

        flowFinishedObserver = NotificationCenter.default.addObserver(
            forName: Constants.NotificationName.flowFinished,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let success = note.userInfo?["success"] as? Bool ?? false
            let summary = note.userInfo?["summary"] as? String ?? ""
            MainActor.assumeIsolated { self?.finishFlow(success: success, summary: summary) }
        }

        skillCreationObserver = NotificationCenter.default.addObserver(
            forName: Constants.NotificationName.showSkillCreation,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterSkillCreationMode() }
        }

        editSkillObserver = NotificationCenter.default.addObserver(
            forName: Constants.NotificationName.editSkillInPanel,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let filePath = note.userInfo?["filePath"] as? String else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                // Build a SkillCard from the file
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                let name = json["name"] as? String ?? URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
                let displayName = name.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
                let overview = json["overview"] as? String ?? ""
                let triggers = (json["triggers"] as? [String])?.joined(separator: ", ") ?? ""
                let mode = json["mode"] as? String ?? "background"
                let card = SkillCard(name: name, displayName: displayName,
                                     overview: overview, triggers: triggers,
                                     mode: mode, filePath: filePath)
                self.editSkill(card: card)
            }
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

    // MARK: - Skill Editor Mode

    enum SkillEditorMode { case json, natural }

    var skillEditorMode: SkillEditorMode = .natural
    var skillEditorFilePath: String = ""
    var skillEditorOriginalJSON: String = ""

    /// True while the panel is showing the inline skill editor.
    var isInSkillEditorMode: Bool {
        if case .skillEdit = state { return true }
        return false
    }

    /// Opens the inline editor for a skill card, defaulting to natural-language view.
    func editSkill(card: SkillCard) {
        skillEditorMode = .natural
        skillEditorFilePath = card.filePath
        skillEditorOriginalJSON = (try? String(contentsOfFile: card.filePath)) ?? ""
        state = .skillEdit(card: card)
    }

    /// Converts skill JSON to a human-readable natural-language description (synchronous).
    func jsonToNatural(_ jsonString: String) -> String {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return jsonString
        }
        let overview    = json["overview"]     as? String ?? ""
        let triggers    = (json["triggers"]    as? [String])?.joined(separator: ", ") ?? ""
        let startUrl    = json["start_url"]    as? String ?? ""
        let generalHint = json["general_hint"] as? String ?? ""
        let pages       = json["pages"]        as? [[String: Any]] ?? []

        var sections: [String] = []

        let name = json["name"] as? String ?? ""
        if !name.isEmpty {
            sections.append("SKILL NAME\n\(name)")
        }

        if !overview.isEmpty {
            sections.append("WHAT THIS SKILL DOES\n\(overview)")
        }
        if !triggers.isEmpty {
            sections.append("TRIGGER BY SAYING\n\(triggers)")
        }
        if !startUrl.isEmpty {
            sections.append("STARTS AT\n\(startUrl)")
        }
        if !pages.isEmpty {
            var stepsLines: [String] = ["STEPS"]
            for (i, page) in pages.enumerated() {
                let desc         = page["description"]  as? String ?? ""
                let instructions = page["instructions"] as? String ?? ""
                let urlContains  = page["url_contains"] as? String ?? ""
                if !desc.isEmpty {
                    stepsLines.append("\n\(i + 1). \(desc)")
                    if !urlContains.isEmpty {
                        stepsLines.append("   URL contains: \(urlContains)")
                    }
                }
                if !instructions.isEmpty {
                    let parts = instructions
                        .components(separatedBy: ". ")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    for part in parts {
                        stepsLines.append("   \(part.hasSuffix(".") ? part : part + ".")")
                    }
                }
            }
            sections.append(stepsLines.joined(separator: "\n"))
        }
        if !generalHint.isEmpty {
            let parts = generalHint
                .components(separatedBy: ". ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var hintLines = ["GENERAL FLOW"]
            for part in parts {
                hintLines.append(part.hasSuffix(".") ? part : part + ".")
            }
            sections.append(hintLines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// Converts user-edited natural language back to skill JSON using the OpenAI API (async).
    func naturalToJSON(_ natural: String, existingJSON: String) async throws -> String {
        let config = ConfigService.shared.config
        let prompt = """
        The user has edited a Sky skill in natural language. Convert their edited description back into valid Sky skill JSON.

        Original skill JSON for reference (preserve the structure):
        \(existingJSON)

        User's edited natural language description:
        \(natural)

        Return ONLY valid JSON matching the Sky skill format. No markdown. No explanation.
        The JSON must have: name, triggers, start_url, overview, mode, requires, pages, general_hint.
        Preserve any pages/steps the user kept. Update any they changed. Remove any they deleted.
        """
        let body: [String: Any] = [
            "model": Constants.OpenAI.model,
            "max_tokens": 1500,
            "messages": [["role": "user", "content": prompt]]
        ]
        guard let url = URL(string: Constants.OpenAI.baseURL) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.openaiApiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads the skills directory and transitions to the interactive skills list state.
    func showSkillsList() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            state = .answer(text: "Could not access skills directory.")
            return
        }
        let skillsDir = appSupport.appendingPathComponent("Sky/skills")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: skillsDir, includingPropertiesForKeys: nil
        )) ?? []
        let skillFiles = files.filter {
            $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !skillFiles.isEmpty else {
            state = .answer(text: "No skills installed yet. Say 'add a skill' to create one.")
            return
        }
        var cards: [SkillCard] = []
        for file in skillFiles {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let name = json["name"] as? String ?? file.deletingPathExtension().lastPathComponent
            let overview = json["overview"] as? String ?? ""
            let triggers = (json["triggers"] as? [String])?.joined(separator: ", ") ?? ""
            let mode = json["mode"] as? String ?? "background"
            let display = name.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
            cards.append(SkillCard(name: name, displayName: display,
                                   overview: overview, triggers: triggers,
                                   mode: mode, filePath: file.path))
        }
        inputText = ""
        state = .skillsList(skills: cards)
    }

    /// Applies an array of ActionResults to panel state, building a combined success message.
    private func applyResults(_ results: [ActionResult]) {
        inputText = ""
        contactSuggestions = []
        sessionHistory = []
        guard !isFlowHandled else { return }
        // Don't overwrite skill creation state — enterSkillCreationMode() already set it via notification
        if case .skillCreation = state { return }
        // Handle showSkillsList trigger
        if results.contains(where: { if case .showSkillsList = $0 { return true }; return false }) {
            showSkillsList()
            return
        }

        let answers   = results.compactMap { if case .answer(let t)    = $0 { return t } else { return nil } }
        let successes = results.compactMap { if case .success(let m)   = $0, !m.isEmpty { return m } else { return nil } }
        let scheduled = results.compactMap { if case .scheduled(let m) = $0 { return m } else { return nil } }
        let failures  = results.compactMap { if case .failure(let m)   = $0 { return m } else { return nil } }

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

    // MARK: - Flow Progress

    func startFlow(goal: String) {
        currentFlowGoal = goal
        flowSteps = []
        isFlowHandled = false
        state = .flowRunning(goal: goal, steps: [], canCancel: true)
    }

    func addFlowStep(_ text: String) {
        // Mark previous running step as success
        if !flowSteps.isEmpty {
            let i = flowSteps.count - 1
            if flowSteps[i].status == .running {
                let prev = flowSteps[i]
                flowSteps[i] = FlowStep(id: prev.id, text: prev.text, status: .success)
            }
        }
        flowSteps.append(FlowStep(id: UUID(), text: text, status: .running))
        state = .flowRunning(goal: currentFlowGoal, steps: flowSteps, canCancel: true)
    }

    func updateLastStep(status: FlowStepStatus, text: String? = nil) {
        guard !flowSteps.isEmpty else { return }
        let i = flowSteps.count - 1
        let last = flowSteps[i]
        flowSteps[i] = FlowStep(id: last.id, text: text ?? last.text, status: status)
        state = .flowRunning(goal: currentFlowGoal, steps: flowSteps, canCancel: true)
    }

    func finishFlow(success: Bool, summary: String) {
        isFlowHandled = true
        if success {
            updateLastStep(status: .success)
        } else {
            updateLastStep(status: .failed, text: summary)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.isFlowHandled = false
            self?.state = .answer(text: summary)
        }
    }

    func minimizeFlow() {
        state = .flowMinimized(goal: currentFlowGoal, stepCount: flowSteps.count)
    }

    func expandFlow() {
        state = .flowRunning(goal: currentFlowGoal, steps: flowSteps, canCancel: true)
    }

    func cancelFlow() {
        isFlowHandled = false
        HeadlessBrowserService.shared.stop()
        state = .idle
    }

    // MARK: - Skill Creation

    func enterSkillCreationMode() {
        print("🎯 [SkillCreation] Entering skill creation mode")
        isInSkillCreationMode = true
        state = .skillCreation(stage: .waitingForDescription)
    }

    func exitSkillCreationMode() {
        isInSkillCreationMode = false
        cancelSkillCreation()
    }

    func submitSkillDescription(_ description: String) {
        skillCreationDescription = description
        generatedSkillJSON = ""
        skillCreationName = ""
        state = .skillCreation(stage: .generating)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let json = try await self.generateSkillJSON(from: description)
                self.generatedSkillJSON = json
                if let data = json.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = parsed["name"] as? String {
                    self.skillCreationName = name
                }
                self.state = .skillCreation(stage: .testing(goal: description))
                await self.testGeneratedSkill()
            } catch {
                self.state = .answer(text: "Could not generate skill: \(error.localizedDescription)")
            }
        }
    }

    func submitSkillFeedback(_ feedback: String) {
        state = .skillCreation(stage: .generating)
        let failedText = flowSteps.last(where: { $0.status == .failed })?.text ?? "unknown step"
        let currentJSON = generatedSkillJSON
        let updatePrompt = """
        Update this Sky skill JSON based on user feedback.

        Current skill JSON:
        \(currentJSON)

        The flow failed at: \(failedText)

        User says to fix it by: \(feedback)

        Update the relevant page instructions to incorporate this fix.
        Return ONLY the updated JSON. No markdown. No explanation.
        """
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let updated = try await self.generateSkillJSON(from: updatePrompt)
                self.generatedSkillJSON = updated
                if let data = updated.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let name = parsed["name"] as? String {
                    self.skillCreationName = name
                }
                self.state = .skillCreation(stage: .testing(goal: self.skillCreationDescription))
                await self.testGeneratedSkill()
            } catch {
                self.state = .answer(text: "Could not update skill: \(error.localizedDescription)")
            }
        }
    }

    func cancelSkillCreation() {
        isInSkillCreationMode = false
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let tempURL = appSupport.appendingPathComponent("Sky/skills/_temp_skill.json")
            try? FileManager.default.removeItem(at: tempURL)
        }
        state = .idle
    }

    private func generateSkillJSON(from prompt: String) async throws -> String {
        let config = ConfigService.shared.config
        let body: [String: Any] = [
            "model": Constants.OpenAI.model,
            "max_tokens": 1500,
            "messages": [["role": "user", "content": """
            Generate a Sky skill JSON file from this user description.

            User wants to automate: \(prompt)

            Return ONLY a valid JSON object. No markdown. No explanation. No backticks.

            Required format:
            {
              "name": "site_action",
              "version": "1.0",
              "triggers": ["site", "action"],
              "start_url": "https://www.site.com",
              "overview": "One sentence description",
              "mode": "background",
              "requires": ["browser"],
              "pages": [
                {
                  "url_contains": "url-pattern",
                  "description": "Page name",
                  "instructions": "STEP 1: Click exact button name. STEP 2: Click exact button name."
                }
              ],
              "general_hint": "Full step by step fallback instructions"
            }

            Rules:
            - name: 2-3 words snake_case e.g. flipkart_order, swiggy_food, amazon_cancel
            - triggers: exactly 2 SHORT words the user would say e.g. ["flipkart", "order"] or ["swiggy", "food"]
              NEVER use the full description or full skill name as triggers
              triggers must be individual common words that appear in natural speech
            - start_url: the HOMEPAGE of the site mentioned.
              Examples: flipkart → https://www.flipkart.com, amazon → https://www.amazon.in,
              swiggy → https://www.swiggy.com, zomato → https://www.zomato.com
              Extract the site from the user description and use its homepage
            - pages: one entry per distinct page in the flow, matched by url_contains pattern
            - instructions: use EXACT button labels the user mentioned, formatted as numbered steps
            - general_hint: complete fallback with all steps in order, for when URL matching fails

            Return ONLY the JSON object. Nothing else.
            """]]
        ]
        guard let url = URL(string: Constants.OpenAI.baseURL) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.openaiApiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw URLError(.cannotParseResponse)
        }
        return text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func testGeneratedSkill() async {
        saveSkillToDisk(json: generatedSkillJSON, temporary: true)
        SkillsService.shared.reload()

        // Use triggers as the test goal — mirrors how a real user would invoke the skill
        let testGoal: String
        if let data = generatedSkillJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let triggers = json["triggers"] as? [String], !triggers.isEmpty {
            testGoal = triggers.joined(separator: " ")
        } else {
            testGoal = skillCreationName.replacingOccurrences(of: "_", with: " ")
        }

        let contextURL = ContextService.shared.browserURL
        print("🎯 [SkillCreation] Testing skill with goal: '\(testGoal)' startURL: '\(contextURL ?? "none")'")
        startFlow(goal: testGoal)

        let result = await HeadlessFlowService.shared.execute(
            goal: testGoal,
            contextURL: contextURL,
            progressHandler: { [weak self] message in
                self?.addFlowStep(message)
            }
        )
        let succeeded = !result.hasPrefix("Browser error") &&
                        !result.hasPrefix("Stuck") &&
                        !result.contains("could not complete") &&
                        !result.contains("Reached maximum")
        if succeeded {
            saveSkillToDisk(json: generatedSkillJSON, temporary: false)
            SkillsService.shared.reload()
            ActionLogService.shared.record(summary: "Skill created: \(skillCreationName)", succeeded: true)
            state = .skillCreation(stage: .saved(skillName: skillCreationName))
        } else {
            let failedStep = flowSteps.last(where: { $0.status == .failed })?.text ?? "unknown step"
            let question = "Couldn't complete: \"\(failedStep)\"\n\nWhat should I try differently?"
            state = .skillCreation(stage: .awaitingFeedback(failedStep: failedStep, question: question))
        }
    }

    private func saveSkillToDisk(json: String, temporary: Bool) {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let skillsDir = appSupport.appendingPathComponent("Sky/skills")
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        let filename = temporary ? "_temp_skill.json" : "\(skillCreationName).json"
        let fileURL = skillsDir.appendingPathComponent(filename)
        try? json.write(to: fileURL, atomically: true, encoding: .utf8)
        if !temporary {
            let tempURL = skillsDir.appendingPathComponent("_temp_skill.json")
            try? FileManager.default.removeItem(at: tempURL)
            print("🎯 [Skills] Saved new skill: \(skillCreationName)")
        }
    }
}
