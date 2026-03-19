import AppKit
import ApplicationServices

/// Executes multi-step UI flows using an act-observe loop.
/// Uses the AX tree as primary observation method — instant and free.
/// Falls back to vision only if the AX tree returns no elements.
@MainActor
final class FlowExecutionService {
    static let shared = FlowExecutionService()
    private init() {}

    /// The goal of the most recently started flow — used by handleResolvePermission to resume.
    private(set) var lastGoal: String = ""
    /// The permission key that was pending when the flow last paused for a permission dialog.
    private(set) var lastPermKey: String = ""

    // MARK: - Types

    struct FlowStep {
        let instruction: String
        let completed: Bool
        let result: String?
    }

    struct FlowContext {
        let goal: String
        let appName: String
        var completedSteps: [FlowStep]
        var currentStepIndex: Int
        var maxSteps: Int = 10
    }

    struct AgentDecision {
        enum Action {
            case click(target: String)
            case type(target: String, text: String)
            case wait(seconds: Double)
            case scroll(direction: String)
            case done(summary: String)
            case failed(reason: String)
            case askUser(question: String)
            case retry(target: String)
        }
        let action: Action
        let reasoning: String
    }

    // MARK: - Main Entry Point

    /// Executes a complete flow to achieve the given goal.
    /// Reports progress via the progressHandler callback (called on MainActor).
    func executeFlow(
        goal: String,
        progressHandler: @escaping @MainActor (String) -> Void
    ) async -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return "No active app found"
        }

        var context = FlowContext(
            goal: goal,
            appName: app.localizedName ?? "unknown app",
            completedSteps: [],
            currentStepIndex: 0
        )

        lastGoal = goal
        var retryCounts: [String: Int] = [:]
        var clickHistory: [String: Int] = [:]  // element label → click count

        progressHandler("Starting: \(goal)")
        print("🔄 [Flow] Starting flow: '\(goal)' in \(context.appName)")

        for step in 0..<context.maxSteps {
            print("🔄 [Flow] Step \(step + 1)/\(context.maxSteps)")

            // Observe current state via AX tree
            let axElements = getAXElements()
            print("🔄 [Flow] AX elements found: \(axElements.count)")

            // Ask Claude what to do next
            let decision = await getNextAction(context: context, axElements: axElements)
            print("🔄 [Flow] Decision: \(decision.action) — \(decision.reasoning)")

            switch decision.action {
            case .click(let target):
                // Loop detection — stop if we've already clicked this element twice with no progress
                let clickCount = clickHistory[target, default: 0]
                print("🔄 [Flow] Click history for '\(target)': \(clickCount) previous clicks")
                if clickCount >= 2 {
                    return "Stuck in a loop — clicked '\(target)' \(clickCount) times already with no progress. Stopping."
                }
                clickHistory[target] = clickCount + 1

                progressHandler("Clicking '\(target)'…")
                let clickSuccess = await clickElement(matching: target, in: axElements)
                let stepResult = clickSuccess ? "Clicked '\(target)'" : "Could not find '\(target)'"
                context.completedSteps.append(FlowStep(
                    instruction: "Click \(target)",
                    completed: clickSuccess,
                    result: stepResult
                ))
                if !clickSuccess {
                    print("🔄 [Flow] AX click failed, trying vision for '\(target)'")
                    let visionSuccess = await clickViaVision(instruction: "click \(target)")
                    if !visionSuccess {
                        LoggingService.shared.log("[Flow] vision fallback also failed for '\(target)'")
                        return "Couldn't find '\(target)' on screen — flow stopped at step \(step + 1)"
                    }
                }
                // Poll until element count is stable for 2 consecutive checks, or 20 seconds elapse
                var prevCount = -1
                var stableStreak = 0
                for _ in 0..<10 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
                    let axApp = AXUIElementCreateApplication(pid)
                    let current = ComputerUseService.shared.collectElements(from: axApp).count
                    print("🔄 [Flow] Page settling: \(current) elements")
                    if current == prevCount && current > 20 {
                        stableStreak += 1
                        if stableStreak >= 2 { break }
                    } else {
                        stableStreak = 0
                    }
                    prevCount = current
                }

            case .type(let target, let text):
                progressHandler("Typing into '\(target)'…")
                await typeIntoElement(matching: target, text: text, in: axElements)
                context.completedSteps.append(FlowStep(
                    instruction: "Type '\(text)' into \(target)",
                    completed: true,
                    result: "Typed"
                ))
                try? await Task.sleep(nanoseconds: 500_000_000)

            case .wait(let seconds):
                progressHandler("Waiting for page to load…")
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

            case .scroll(let direction):
                progressHandler("Scrolling \(direction)…")
                scrollPage(direction: direction)
                try? await Task.sleep(nanoseconds: 800_000_000)
                context.completedSteps.append(FlowStep(
                    instruction: "Scroll \(direction)",
                    completed: true,
                    result: "Scrolled \(direction)"
                ))

            case .done(let summary):
                progressHandler("Done!")
                LoggingService.shared.log("[Flow] Completed: \(goal) — \(summary)")
                ActionLogService.shared.record(summary: "Flow completed: \(goal)", succeeded: true)
                return summary

            case .failed(let reason):
                LoggingService.shared.log("[Flow] Failed: \(goal) — \(reason)")
                ActionLogService.shared.record(summary: "Flow failed: \(goal) — \(reason)", succeeded: false)
                return "Stopped: \(reason)"

            case .askUser(let question):
                if question.hasPrefix("PERMISSION:") {
                    let parts = question.replacingOccurrences(of: "PERMISSION: ", with: "")
                    let permKey = extractPermissionKey(from: question)
                    if let saved = MemoryService.shared.keyedPreference(permKey) {
                        progressHandler("Using saved preference: \(saved)")
                        let freshElements = getAXElements()
                        _ = await clickElement(matching: saved, in: freshElements)
                        try? await Task.sleep(nanoseconds: 1_000_000_000)
                        context.completedSteps.append(FlowStep(
                            instruction: "Permission: \(saved)",
                            completed: true,
                            result: "Auto-clicked saved preference"
                        ))
                        context.currentStepIndex += 1
                        continue
                    }
                    lastPermKey = permKey
                    return "PERMISSION_NEEDED:\(parts)"
                }
                return question

            case .retry(let target):
                let count = retryCounts[target, default: 0]
                guard count < 2 else {
                    return "Stopped: clicked '\(target)' \(count) times with no change"
                }
                retryCounts[target] = count + 1
                progressHandler("Retrying '\(target)'…")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let retrySuccess = await clickElement(matching: target, in: axElements)
                context.completedSteps.append(FlowStep(
                    instruction: "Retry \(target)",
                    completed: retrySuccess,
                    result: retrySuccess ? "Clicked '\(target)' on retry" : "Still could not find '\(target)'"
                ))
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            context.currentStepIndex += 1
        }

        return "Reached maximum steps (\(context.maxSteps)) — flow may be incomplete"
    }

    // MARK: - AX Observation

    private func getAXElements() -> [ComputerUseService.AXElement] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let all = ComputerUseService.shared.collectElements(from: axApp)
        var seen = Set<String>()
        let deduped = all.filter { seen.insert("\($0.role):\($0.label)").inserted }
        let buttonCount = deduped.filter { $0.role == kAXButtonRole as String }.count
        let linkCount   = deduped.filter { $0.role == "AXLink" }.count
        let groupCount  = deduped.filter { $0.role == "AXGroup" }.count
        print("🔄 [Flow] AX: \(all.count) raw → \(deduped.count) deduped — \(buttonCount) buttons, \(linkCount) links, \(groupCount) groups")
        return deduped
    }

    // MARK: - Claude Decision Making

    /// Returns the URL of the current tab in Safari, Chrome, or Arc, or nil if not a browser.
    private func getCurrentBrowserURL() async -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let appName = app.localizedName else { return nil }
        let script: String
        switch appName {
        case "Safari":
            script = """
            tell application "Safari"
                return URL of current tab of front window
            end tell
            """
        case "Google Chrome", "Chrome":
            script = """
            tell application "Google Chrome"
                return URL of active tab of front window
            end tell
            """
        case "Arc":
            script = """
            tell application "Arc"
                return URL of active tab of front window
            end tell
            """
        case "Brave Browser":
            script = """
            tell application "Brave Browser"
                return URL of active tab of front window
            end tell
            """
        default:
            return nil
        }
        return try? await AppleScriptService.shared.executeWithResult(script)
    }

    private func buildElementsSummary(_ elements: [ComputerUseService.AXElement]) -> String {
        elements.prefix(200).map { "[\($0.role)] \"\($0.label)\"" }.joined(separator: "\n")
    }

    private func getNextAction(
        context: FlowContext,
        axElements: [ComputerUseService.AXElement]
    ) async -> AgentDecision {
        let elementsSummary = buildElementsSummary(axElements)

        let completedSummary = context.completedSteps.map {
            "- \($0.instruction): \($0.result ?? "done")"
        }.joined(separator: "\n")

        let currentURL = await getCurrentBrowserURL()
        let skillHint = SkillsService.shared.findHint(for: context.goal, currentURL: currentURL)

        var skillSection = ""
        if let hint = skillHint {
            skillSection = "\nSKILL HINT FOR THIS PAGE:\n\(hint)\n"
        }
        if let url = currentURL {
            skillSection = "CURRENT URL: \(url)\n" + skillSection
        }

        let prompt = """
        You are controlling a Mac to complete a goal. You see the current screen's interactive elements below.

        GOAL: \(context.goal)
        APP: \(context.appName)
        STEP: \(context.currentStepIndex + 1)
        \(skillSection)
        COMPLETED SO FAR:
        \(completedSummary.isEmpty ? "Nothing yet" : completedSummary)

        CURRENT SCREEN ELEMENTS (\(axElements.isEmpty ? "WARNING: none found — page may still be loading" : "\(axElements.count) total")):
        \(elementsSummary.isEmpty ? "No interactive elements found — page may still be loading" : elementsSummary)

        USER PREFERENCES FROM MEMORY:
        \(buildMemoryContext())

        Based on the goal and what you see on screen, what is the single next action to take?

        Return ONLY a raw JSON object, no markdown:

        To click something:
        {"action": "click", "target": "exact label of element to click", "reasoning": "why"}

        To type text:
        {"action": "type", "target": "exact label of field", "text": "text to type", "reasoning": "why"}

        To wait for page load:
        {"action": "wait", "seconds": 2, "reasoning": "why"}

        When goal is fully achieved:
        {"action": "done", "summary": "what was accomplished", "reasoning": "why done"}

        When goal cannot be achieved:
        {"action": "failed", "reason": "specific reason why", "reasoning": "explanation"}

        When you need to ask the user something before proceeding:
        {"action": "askUser", "question": "what to ask", "reasoning": "why you need to know"}

        \(Constants.Flow.decisionRules)
        """

        do {
            let response = try await callClaudeForDecision(prompt: prompt)
            return parseDecision(from: response)
        } catch {
            print("🔄 [Flow] Claude decision failed: \(error)")
            return AgentDecision(
                action: .failed(reason: "Could not get next action: \(error.localizedDescription)"),
                reasoning: "API error"
            )
        }
    }

    private func extractPermissionKey(from question: String) -> String {
        let lower = question.lowercased()
        // Key by resource only — question text often says "this website" not a real domain
        if lower.contains("camera") && lower.contains("microphone") { return "permission_camera_microphone" }
        if lower.contains("camera")        { return "permission_camera" }
        if lower.contains("microphone")    { return "permission_microphone" }
        if lower.contains("location")      { return "permission_location" }
        if lower.contains("contacts")      { return "permission_contacts" }
        if lower.contains("notification")  { return "permission_notifications" }
        return "permission_default"
    }

    private func buildMemoryContext() -> String {
        let mem = MemoryService.shared.readMemory()
        var lines: [String] = []
        if let camera = mem.keyedPreferences["meeting_camera"] {
            lines.append("meeting_camera: \(camera)")
        }
        if let mic = mem.keyedPreferences["meeting_mic"] {
            lines.append("meeting_mic: \(mic)")
        }
        return lines.isEmpty ? "No relevant preferences" : lines.joined(separator: ", ")
    }

    private func callClaudeForDecision(prompt: String) async throws -> String {
        let config = ConfigService.shared.config
        if config.aiProvider == "openai" && !config.openaiApiKey.isEmpty {
            return try await callOpenAI(prompt: prompt)
        }
        return try await callAnthropic(prompt: prompt)
    }

    private func callAnthropic(prompt: String) async throws -> String {
        let body: [String: Any] = [
            "model": Constants.API.model,
            "max_tokens": 256,
            "messages": [["role": "user", "content": prompt]]
        ]
        var request = URLRequest(url: URL(string: Constants.API.anthropicBaseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ConfigService.shared.config.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Constants.API.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (json?["content"] as? [[String: Any]])?.first
        return content?["text"] as? String ?? ""
    }

    private func callOpenAI(prompt: String) async throws -> String {
        let body: [String: Any] = [
            "model": Constants.OpenAI.model,
            "max_tokens": 256,
            "messages": [["role": "user", "content": prompt]]
        ]
        var request = URLRequest(url: URL(string: Constants.OpenAI.baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(ConfigService.shared.config.openaiApiKey)",
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let choices = json?["choices"] as? [[String: Any]]
        let message = choices?.first?["message"] as? [String: Any]
        return message?["content"] as? String ?? ""
    }

    private func parseDecision(from response: String) -> AgentDecision {
        let clean = response
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data      = clean.data(using: .utf8),
              let json       = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let actionStr  = json["action"] as? String else {
            print("🔄 [Flow] Failed to parse decision: \(response)")
            return AgentDecision(action: .failed(reason: "Could not parse agent response"),
                                 reasoning: "parse error")
        }

        let reasoning = json["reasoning"] as? String ?? ""

        switch actionStr {
        case "click":
            let target = json["target"] as? String ?? ""
            return AgentDecision(action: .click(target: target), reasoning: reasoning)
        case "type":
            let target = json["target"] as? String ?? ""
            let text   = json["text"]   as? String ?? ""
            return AgentDecision(action: .type(target: target, text: text), reasoning: reasoning)
        case "wait":
            let seconds = json["seconds"] as? Double ?? 2.0
            return AgentDecision(action: .wait(seconds: seconds), reasoning: reasoning)
        case "done":
            let summary = json["summary"] as? String ?? "Done"
            return AgentDecision(action: .done(summary: summary), reasoning: reasoning)
        case "failed":
            let reason = json["reason"] as? String ?? "Unknown failure"
            return AgentDecision(action: .failed(reason: reason), reasoning: reasoning)
        case "scroll":
            let direction = json["direction"] as? String ?? "down"
            return AgentDecision(action: .scroll(direction: direction), reasoning: reasoning)
        case "askUser":
            let question = json["question"] as? String ?? "What should I do next?"
            return AgentDecision(action: .askUser(question: question), reasoning: reasoning)
        case "retry":
            let target = json["target"] as? String ?? ""
            return AgentDecision(action: .retry(target: target), reasoning: reasoning)
        default:
            return AgentDecision(action: .failed(reason: "Unknown action: \(actionStr)"),
                                 reasoning: reasoning)
        }
    }

    // MARK: - Scroll Execution

    private func scrollPage(direction: String) {
        let delta: Int32 = direction == "down" ? -8 : 8
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line,
                            wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Click Execution

    private func clickElement(matching target: String,
                               in elements: [ComputerUseService.AXElement]) async -> Bool {
        guard let element = ComputerUseService.shared.findBestElement(
            matching: target, in: elements) else { return false }

        let pressResult = AXUIElementPerformAction(element.element, kAXPressAction as CFString)
        if pressResult == .success {
            print("🔄 [Flow] AX press '\(element.label)' succeeded")
            return true
        }
        do {
            try ComputerUseService.shared.clickAt(element.position)
            return true
        } catch {
            print("🔄 [Flow] CGEvent click failed: \(error)")
            return false
        }
    }

    private func clickViaVision(instruction: String) async -> Bool {
        do {
            _ = try await ComputerUseService.shared.findAndClickViaVision(instruction: instruction)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Type Execution

    private func typeIntoElement(matching target: String, text: String,
                                  in elements: [ComputerUseService.AXElement]) async {
        guard let element = ComputerUseService.shared.findBestElement(
            matching: target, in: elements) else {
            print("🔄 [Flow] Could not find field '\(target)' for typing")
            return
        }
        // Focus the field
        AXUIElementPerformAction(element.element, kAXPressAction as CFString)
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Set value via AX (fastest path)
        AXUIElementSetAttributeValue(element.element,
                                     kAXValueAttribute as CFString,
                                     text as CFTypeRef)

        // Keystroke simulation as fallback for web fields that don't honour AX value
        let source = CGEventSource(stateID: .hidSystemState)
        for scalar in text.unicodeScalars {
            guard scalar.value <= 0xFFFF else { continue }
            var charVal = UniChar(scalar.value)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &charVal)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &charVal)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        print("🔄 [Flow] Typed '\(text)' into '\(element.label)'")
    }
}
