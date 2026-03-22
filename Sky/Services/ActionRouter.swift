import AppKit
@preconcurrency import ApplicationServices
@preconcurrency import EventKit
import Contacts

/// Routes a parsed intent to the appropriate action handlers and returns typed results.
/// Supports multi-step intents — executes all actions in order and collects results.
final class ActionRouter: Sendable {

    // MARK: - Route

    /// Executes all actions in `intent.actions` sequentially and returns one result per action.
    /// @discardableResult allows SchedulerService to call this without using the return value.
    @discardableResult
    func route(intent: ParsedIntent) async -> [ActionResult] {
        var results: [ActionResult] = []
        for singleAction in intent.actions {
            let result = await routeSingle(action: singleAction, intent: intent)
            results.append(result)
        }
        return results
    }

    /// Dispatches a single action to its handler and records the result to the action log.
    private func routeSingle(action: SingleAction, intent: ParsedIntent) async -> ActionResult {
        let params = action.params
        LoggingService.shared.log("Routing action: \(action.action)")

        let result: ActionResult
        switch action.action {
        case Constants.ActionType.sendMail:         result = await handleSendMail(params: params)
        case Constants.ActionType.scheduleMail:     result = await handleScheduleMail(action: action, params: params)
        case Constants.ActionType.createEvent:      result = await handleCreateEvent(params: params)
        case Constants.ActionType.joinMeeting:      result = await handleJoinMeeting(params: params)
        case Constants.ActionType.setReminder:      result = await handleSetReminder(params: params)
        case Constants.ActionType.sendMessage:      result = await handleSendMessage(params: params)
        case Constants.ActionType.makeCall:         result = await handleMakeCall(params: params)
        case Constants.ActionType.findFile:         result = await handleFindFile(params: params)
        case Constants.ActionType.openApp:          result = await handleOpenApp(params: params)
        case Constants.ActionType.webSearch:        result = await handleWebSearch(params: params)
        case Constants.ActionType.clipboardHistory: result = handleClipboardHistory()
        case Constants.ActionType.windowManagement: result = handleWindowManagement(params: params)
        case Constants.ActionType.setFocus:         result = await handleSetFocus(params: params)
        case Constants.ActionType.quickNote:        result = await handleQuickNote(params: params)
        case Constants.ActionType.mediaPlayPause:   result = await handleMediaPlayPause()
        case Constants.ActionType.mediaNextTrack:   result = await handleMediaNextTrack()
        case Constants.ActionType.mediaGetInfo:     result = await handleMediaGetInfo()
        case Constants.ActionType.showLog:          result = .success("")   // handled client-side
        case Constants.ActionType.showMemory:       result = .success("")   // handled client-side
        case Constants.ActionType.computerUse:      result = await handleComputerUse(params: params)
        case Constants.ActionType.executeFlow:       result = await handleExecuteFlow(params: params)
        case Constants.ActionType.mediaPlaySpecific: result = await handleMediaPlaySpecific(params: params)
        case Constants.ActionType.answer:           result = .answer(action.params.body ?? action.displaySummary)
        case Constants.ActionType.readCalendarToday: result = await handleReadCalendarToday()
        case Constants.ActionType.createWorkflow:   result = await handleCreateWorkflow(params: action.params)
        case Constants.ActionType.saveMemory:       result = handleSaveMemory(params: action.params)
        case Constants.ActionType.whatDoYouSee:     result = await handleWhatDoYouSee()
        case Constants.ActionType.resolvePermission: result = await handleResolvePermission(params: params)
        case Constants.ActionType.testBrowser:      result = await handleTestBrowser()
        case Constants.ActionType.browserLogin:     result = await handleBrowserLogin(params: params)
        case Constants.ActionType.browserLoginDone: result = await handleBrowserLoginDone()
        case Constants.ActionType.createSkill:      result = await handleCreateSkill()
        case Constants.ActionType.showSkills:       result = handleShowSkills()
        case Constants.ActionType.deleteSkill:      result = handleDeleteSkill(params: params)
        case Constants.ActionType.showSkillDetail:  result = handleShowSkillDetail(params: params)
        case Constants.ActionType.unknown:          result = .success("")
        default:
            LoggingService.shared.log("Unknown action type: \(action.action)", level: .warning)
            result = .failure("Unknown action: \(action.action)")
        }

        // Record to action log (skip unknown / show_log / empty results)
        if action.action != Constants.ActionType.unknown && action.action != Constants.ActionType.showLog {
            let succeeded: Bool
            if case .failure = result { succeeded = false } else { succeeded = true }
            ActionLogService.shared.record(summary: action.displaySummary, succeeded: succeeded)
        }

        return result
    }

    // MARK: - Reminders

    /// Creates an EKReminder in the default reminders list via EventKit.
    private func handleSetReminder(params: IntentParams) async -> ActionResult {
        let pm = await PermissionsManager.shared
        guard await pm.requestReminders() else {
            return .failure("Sky needs Reminders access — open System Settings > Privacy > Reminders")
        }
        // Pre-compute Sendable values before entering the main actor
        let title = params.body ?? params.subject ?? "Reminder"
        let dueDate = params.datetime.flatMap { parseDate($0) }

        do {
            let createdTitle: String = try await MainActor.run {
                let store = pm.eventStore
                let reminder = EKReminder(eventStore: store)
                reminder.title = title
                reminder.calendar = store.defaultCalendarForNewReminders()
                if let date = dueDate {
                    let comps = Calendar.current.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second], from: date)
                    reminder.dueDateComponents = comps
                    reminder.addAlarm(EKAlarm(absoluteDate: date))
                }
                try store.save(reminder, commit: true)
                return reminder.title ?? ""
            }
            LoggingService.shared.log("Reminder created: \(createdTitle)")
            return .success(Constants.Success.reminderSet)
        } catch {
            LoggingService.shared.log(error: error, context: "handleSetReminder")
            return .failure("Could not save reminder: \(error.localizedDescription)")
        }
    }

    // MARK: - Calendar Events

    /// Creates an EKEvent on the default calendar via EventKit.
    private func handleCreateEvent(params: IntentParams) async -> ActionResult {
        let pm = await PermissionsManager.shared
        guard await pm.requestCalendars() else {
            return .failure("Sky needs Calendar access — open System Settings > Privacy > Calendars")
        }
        // Pre-compute Sendable values before entering the main actor
        let title     = params.subject ?? params.body ?? "New Event"
        let startDate = params.datetime.flatMap { parseDate($0) } ?? Date()
        let attendee  = params.to

        do {
            let createdTitle: String = try await MainActor.run {
                let store = pm.eventStore
                let event = EKEvent(eventStore: store)
                event.title     = title
                event.calendar  = store.defaultCalendarForNewEvents
                event.startDate = startDate
                event.endDate   = startDate.addingTimeInterval(3600)
                if let a = attendee {
                    event.notes = (event.notes.map { $0 + "\n" } ?? "") + "Attendee: \(a)"
                }
                try store.save(event, span: .thisEvent)
                return event.title ?? ""
            }
            LoggingService.shared.log("Event created: \(createdTitle)")
            return .success(Constants.Success.eventCreated)
        } catch {
            LoggingService.shared.log(error: error, context: "handleCreateEvent")
            return .failure("Could not create event: \(error.localizedDescription)")
        }
    }

    // MARK: - Join Meeting

    /// Opens a meeting URL, runs the flow loop for web meetings, or defers to scheduler.
    private func handleJoinMeeting(params: IntentParams) async -> ActionResult {
        // Future meeting (> 2 min away) → schedule for auto-join 60s before start
        if let dateString = params.datetime,
           let meetingDate = parseDate(dateString),
           meetingDate.timeIntervalSinceNow > 120 {
            let fireDate = meetingDate.addingTimeInterval(-60)
            let singleAction = SingleAction(
                action: Constants.ActionType.joinMeeting,
                params: params,
                displaySummary: "Join meeting"
            )
            let schedulableIntent = ParsedIntent(actions: [singleAction], displaySummary: "Join meeting")
            do {
                try SchedulerService.shared.schedule(intent: schedulableIntent, runAt: fireDate)
                if let urlString = params.url {
                    let reminderDate = meetingDate.addingTimeInterval(-120)
                    let title = params.query ?? params.subject ?? "Meeting"
                    await NotificationService.shared.scheduleMeetingReminder(
                        urlString: urlString, title: title, at: reminderDate)
                }
                let formatted = relativeDateString(meetingDate)
                return .scheduled("Meeting join scheduled for \(formatted) ✓")
            } catch {
                LoggingService.shared.log(error: error, context: "handleJoinMeeting:schedule")
                return .failure("Could not schedule meeting: \(error.localizedDescription)")
            }
        }

        // Build goal with stored camera/mic preferences
        let mem = MemoryService.shared.readMemory()
        var goal = "join the meeting"
        if let cam = mem.keyedPreferences["meeting_camera"] {
            goal += " with camera \(cam)"
        }
        if let mic = mem.keyedPreferences["meeting_mic"] {
            goal += " and mic \(mic)"
        }

        // Direct URL path
        if let urlString = params.url, let url = URL(string: urlString) {
            // Zoom: use deep link so Zoom app handles camera/mic natively
            if urlString.contains("zoom.us/j/") {
                let deepLink = convertZoomToDeepLink(urlString)
                if let zoomURL = URL(string: deepLink) {
                    await openURL(zoomURL)
                    return .success(Constants.Success.opening)
                }
            }
            // Web meeting (Google Meet, Teams, Webex…) — open URL then run flow
            return await openAndJoinViaFlow(url: url, goal: goal)
        }

        // Calendar lookup path — search by query
        if let query = params.query {
            let pm = await PermissionsManager.shared
            let isGranted = await MainActor.run { pm.calendarsGranted }
            if isGranted {
                let searchDate = params.datetime.flatMap { parseDate($0) } ?? Date()
                let window: TimeInterval = 15 * 60

                let result: (urlString: String?, matchTitle: String?) = await MainActor.run {
                    let store = pm.eventStore
                    let predicate = store.predicateForEvents(
                        withStart: searchDate.addingTimeInterval(-window),
                        end: searchDate.addingTimeInterval(window),
                        calendars: nil
                    )
                    let events = store.events(matching: predicate)
                    let match = events.first {
                        $0.title?.localizedCaseInsensitiveContains(query) == true
                        || $0.location?.localizedCaseInsensitiveContains(query) == true
                        || $0.notes?.localizedCaseInsensitiveContains(query) == true
                    }
                    let urlStr = match?.url?.absoluteString
                        ?? match?.notes.flatMap { self.extractURL(from: $0) }
                    return (urlStr, match?.title)
                }

                if let urlStr = result.urlString, let url = URL(string: urlStr) {
                    if urlStr.contains("zoom.us/j/") {
                        let deepLink = convertZoomToDeepLink(urlStr)
                        if let zoomURL = URL(string: deepLink) {
                            await openURL(zoomURL)
                            return .success(Constants.Success.opening)
                        }
                    }
                    return await openAndJoinViaFlow(url: url, goal: goal)
                }
                if let title = result.matchTitle {
                    LoggingService.shared.log("Found event '\(title)' but no URL")
                    return .failure("Found '\(title)' but it has no meeting URL")
                }
            }
        }

        return .failure("No meeting URL found — try including the link in your command")
    }

    /// Opens a URL, waits for load, hides Sky, then runs the flow loop to click join.
    private func openAndJoinViaFlow(url: URL, goal: String) async -> ActionResult {
        await openURL(url)
        try? await Task.sleep(nanoseconds: 3_000_000_000)

        await MainActor.run {
            NotificationCenter.default.post(name: Constants.NotificationName.hidePanel, object: nil)
        }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let frontmost = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
            if frontmost != Bundle.main.bundleIdentifier { break }
        }

        let result = await MainActor.run { FlowExecutionService.shared }.executeFlow(
            goal: goal,
            progressHandler: { print("🔄 [Meeting] \($0)") }
        )
        await MainActor.run {
            NotificationCenter.default.post(
                name: Constants.NotificationName.skyShowPanel, object: nil)
        }

        if result.hasPrefix("PERMISSION_NEEDED:") {
            let parts = result.replacingOccurrences(of: "PERMISSION_NEEDED:", with: "")
            return .answer("\(parts)\n\nSay 'allow', 'never', or 'don't allow'.")
        }
        return .answer(result)
    }

    private func convertZoomToDeepLink(_ urlString: String) -> String {
        guard urlString.contains("zoom.us/j/") else { return urlString }
        let meetingID = urlString.components(separatedBy: "/j/").last?
            .components(separatedBy: "?").first ?? ""
        let pwd = urlString.contains("pwd=")
            ? "&pwd=" + (urlString.components(separatedBy: "pwd=").last ?? "")
            : ""
        return "zoommtg://zoom.us/join?confno=\(meetingID)\(pwd)"
    }

    // MARK: - Mail

    /// Sends an email immediately via Mail.app using AppleScript.
    private func handleSendMail(params: IntentParams) async -> ActionResult {
        let recipient = resolveEmail(from: params.to) ?? params.to ?? ""
        guard !recipient.isEmpty else {
            return .failure("No recipient — who should I send the mail to?")
        }
        let subject = appleScriptEscape(params.subject ?? "(no subject)")
        let body = appleScriptEscape(params.body ?? "")
        let script = String(format: Constants.AppleScript.sendMail, subject, body, recipient)

        do {
            try await AppleScriptService.shared.execute(script)
            LoggingService.shared.log("Mail sent to \(recipient)")
            if let name = params.to { MemoryService.shared.incrementContact(name) }
            return .success(Constants.Success.mailSent)
        } catch {
            LoggingService.shared.log(error: error, context: "handleSendMail")
            return .failure("Mail failed: \(error.localizedDescription)")
        }
    }

    /// Saves a scheduled mail to the scheduler database instead of sending immediately.
    private func handleScheduleMail(action: SingleAction, params: IntentParams) async -> ActionResult {
        guard let datetimeStr = params.datetime, let runAt = parseDate(datetimeStr) else {
            return .failure("No send time — when should I schedule this mail?")
        }
        // Wrap this single action as a standalone intent so the scheduler can replay it.
        let schedulableIntent = ParsedIntent(actions: [action], displaySummary: action.displaySummary)
        do {
            try SchedulerService.shared.schedule(intent: schedulableIntent, runAt: runAt)
            let formatted = relativeDateString(runAt)
            LoggingService.shared.log("Mail scheduled for \(runAt)")
            return .scheduled("Mail scheduled for \(formatted) ✓")
        } catch {
            LoggingService.shared.log(error: error, context: "handleScheduleMail")
            return .failure("Could not schedule mail: \(error.localizedDescription)")
        }
    }

    // MARK: - Messages

    /// Sends an iMessage via Messages.app using AppleScript.
    private func handleSendMessage(params: IntentParams) async -> ActionResult {
        let body = params.body ?? ""
        guard !body.isEmpty else {
            return .failure("No message body — what should I say?")
        }
        let recipient = resolvePhone(from: params.to) ?? params.to ?? ""
        guard !recipient.isEmpty else {
            return .failure("No recipient — who should I message?")
        }
        let script = String(format: Constants.AppleScript.sendMessage,
                            appleScriptEscape(recipient), appleScriptEscape(body))

        do {
            try await AppleScriptService.shared.execute(script)
            LoggingService.shared.log("Message sent to \(recipient)")
            if let name = params.to { MemoryService.shared.incrementContact(name) }
            return .success(Constants.Success.messageSent)
        } catch {
            LoggingService.shared.log(error: error, context: "handleSendMessage")
            return .failure("Message failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Calls

    /// Opens the tel:// URL scheme to initiate a call via Continuity.
    private func handleMakeCall(params: IntentParams) async -> ActionResult {
        let number = resolvePhone(from: params.to)
        guard let number, !number.isEmpty else {
            let name = params.to ?? "that contact"
            return .failure("No phone number found for \(name)")
        }
        let digits = number.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)") else {
            return .failure("Could not form a call URL from '\(number)'")
        }
        await openURL(url)
        return .success(Constants.Success.opening)
    }

    // MARK: - Find File

    /// Searches Spotlight for a file matching the query and reveals it in Finder.
    private func handleFindFile(params: IntentParams) async -> ActionResult {
        guard let query = params.query, !query.isEmpty else {
            return .failure("No filename or search term provided")
        }
        let result = await runProcess("/usr/bin/mdfind", args: ["-name", query])
        let paths = result
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        guard let first = paths.first else {
            return .failure("No file found for '\(query)'")
        }
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first)]) }
        LoggingService.shared.log("File found: \(first)")
        return .success("Found '\(URL(fileURLWithPath: first).lastPathComponent)' ✓")
    }

    // MARK: - Open App

    /// Launches a named macOS application via NSWorkspace.
    /// Checks the alias map first so casual names like "settings" or "chrome" work reliably.
    private func handleOpenApp(params: IntentParams) async -> ActionResult {
        guard let rawName = params.appName, !rawName.isEmpty else {
            return .failure("No app name provided")
        }
        let normalized = rawName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Alias map — resolve casual name to bundle ID, then to URL
        if let bundleID = Constants.appAliases[normalized] {
            if let url = await MainActor.run(resultType: URL?.self, body: {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            }) {
                return await openAppURL(url, name: rawName)
            }
        }

        // 2. Directory search in /Applications and ~/Applications
        let searchPaths = ["/Applications", "\(NSHomeDirectory())/Applications"]
        for dir in searchPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent("\(rawName).app")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return await openAppURL(candidate, name: rawName)
            }
        }

        // 3. Bundle-ID fallback (in case the model returned a bundle ID directly)
        if let url = await MainActor.run(resultType: URL?.self, body: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawName)
        }) {
            return await openAppURL(url, name: rawName)
        }

        return .failure("Could not find '\(rawName)'")
    }

    private func openAppURL(_ url: URL, name: String) async -> ActionResult {
        do {
            _ = try await NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
            LoggingService.shared.log("Launched app: \(name)")
            return .success(Constants.Success.opening)
        } catch {
            LoggingService.shared.log(error: error, context: "handleOpenApp")
            return .failure("Could not open '\(name)': \(error.localizedDescription)")
        }
    }

    // MARK: - Web Search

    /// Opens a DuckDuckGo search in the default browser.
    private func handleWebSearch(params: IntentParams) async -> ActionResult {
        let query = params.query ?? params.body ?? ""
        guard !query.isEmpty else { return .failure("No search query provided") }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://duckduckgo.com/?q=\(encoded)") else {
            return .failure("Could not form a search URL")
        }
        await openURL(url)
        return .success(Constants.Success.searching)
    }

    // MARK: - Clipboard History

    /// Clipboard history management requires a third-party tool — shows a helpful message.
    private func handleClipboardHistory() -> ActionResult {
        .failure("Clipboard history requires a clipboard manager app (e.g. Pasta or Maccy)")
    }

    // MARK: - Window Management

    /// Window tiling is not yet implemented natively; directs user to Stage Manager.
    private func handleWindowManagement(params: IntentParams) -> ActionResult {
        .failure("Window management coming in a future update — use Stage Manager for now")
    }

    // MARK: - Set Focus

    /// Attempts to enable Focus via the Focus URL scheme.
    private func handleSetFocus(params: IntentParams) async -> ActionResult {
        guard let url = URL(string: "shortcuts://run-shortcut?name=Focus") else {
            return .failure("Could not form Focus URL")
        }
        await openURL(url)
        return .success("Focus mode activated ✓")
    }

    // MARK: - Quick Note

    /// Creates a note in Notes.app via AppleScript.
    private func handleQuickNote(params: IntentParams) async -> ActionResult {
        let title = appleScriptEscape(params.subject ?? "Sky Note")
        let body = appleScriptEscape(params.body ?? "")
        let script = String(format: Constants.AppleScript.createNote, title, body)

        do {
            try await AppleScriptService.shared.execute(script)
            LoggingService.shared.log("Note created: \(title)")
            return .success(Constants.Success.noteSaved)
        } catch {
            LoggingService.shared.log(error: error, context: "handleQuickNote")
            return .failure("Could not save note: \(error.localizedDescription)")
        }
    }

    // MARK: - Media Control

    /// Toggles play/pause in Spotify or Apple Music.
    private func handleMediaPlayPause() async -> ActionResult {
        do {
            try await AppleScriptService.shared.execute(Constants.AppleScript.mediaPlayPause)
            return .success("Done ✓")
        } catch {
            return .failure("Media control failed: \(error.localizedDescription)")
        }
    }

    /// Skips to the next track in Spotify or Apple Music.
    private func handleMediaNextTrack() async -> ActionResult {
        do {
            try await AppleScriptService.shared.execute(Constants.AppleScript.mediaNextTrack)
            return .success("Skipped ✓")
        } catch {
            return .failure("Skip failed: \(error.localizedDescription)")
        }
    }

    /// Returns the currently playing track and artist as an inline answer.
    private func handleMediaGetInfo() async -> ActionResult {
        let info = (try? await AppleScriptService.shared.executeWithResult(Constants.AppleScript.mediaGetInfo))
            ?? "Nothing playing"
        return .answer(info.isEmpty ? "Nothing playing" : info)
    }

    // MARK: - Calendar Today

    /// Reads today's calendar events and returns them as an inline answer.
    private func handleReadCalendarToday() async -> ActionResult {
        let pm = await PermissionsManager.shared
        guard await pm.requestCalendars() else {
            return .failure("Sky needs Calendar access — open System Settings > Privacy > Calendars")
        }

        let lines: [String] = await MainActor.run {
            let store = pm.eventStore
            let startOfDay = Calendar.current.startOfDay(for: Date())
            let endOfDay   = Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? startOfDay
            let predicate  = store.predicateForEvents(withStart: startOfDay, end: endOfDay, calendars: nil)
            let events     = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
            guard !events.isEmpty else { return [] }
            let fmt = DateFormatter()
            fmt.timeStyle = .short
            fmt.dateStyle = .none
            return events.map { "• \(fmt.string(from: $0.startDate)) — \($0.title ?? "Untitled")" }
        }

        if lines.isEmpty { return .answer("Nothing on your calendar today.") }
        return .answer("Today:\n" + lines.joined(separator: "\n"))
    }

    // MARK: - Create Workflow

    /// Resolves each workflow step via IntentParser and saves the workflow.
    private func handleCreateWorkflow(params: IntentParams) async -> ActionResult {
        guard let trigger = params.body, !trigger.isEmpty else {
            return .failure("No trigger phrase — what phrase should activate this workflow?")
        }
        guard let stepDescriptions = params.workflowSteps, !stepDescriptions.isEmpty else {
            return .failure("No steps — what should this workflow do?")
        }

        let parser = IntentParser()
        var resolvedSteps: [WorkflowService.WorkflowStep] = []
        for description in stepDescriptions {
            guard let intent = try? await parser.parse(input: description),
                  let firstAction = intent.firstAction else { continue }
            let paramsData = (try? JSONEncoder().encode(firstAction.params)) ?? Data()
            let paramsJSON = String(data: paramsData, encoding: .utf8) ?? "{}"
            resolvedSteps.append(WorkflowService.WorkflowStep(
                id: UUID(),
                description: description,
                actionType: firstAction.action,
                paramsJSON: paramsJSON
            ))
        }

        guard !resolvedSteps.isEmpty else {
            return .failure("Could not resolve any workflow steps")
        }

        let workflow = WorkflowService.Workflow(
            id: UUID(),
            trigger: trigger,
            steps: resolvedSteps,
            createdAt: Date()
        )

        do {
            try WorkflowService.shared.save(workflow)
            let n = resolvedSteps.count
            return .success("Workflow '\(trigger)' saved with \(n) step\(n == 1 ? "" : "s") ✓")
        } catch {
            return .failure("Could not save workflow: \(error.localizedDescription)")
        }
    }

    // MARK: - Computer Use

    /// Hides the panel, waits for it to lose focus, then finds and clicks the described element.
    /// Uses the Accessibility Tree as primary method; falls back to vision if AX finds nothing.
    private func handleComputerUse(params: IntentParams) async -> ActionResult {
        let instruction = params.body ?? params.query ?? ""
        guard !instruction.isEmpty else {
            return .failure("What should I click or interact with?")
        }
        print("🟢 [ActionRouter] computer_use: '\(instruction)'")

        // Hide Sky before acting so it doesn't obstruct the target app
        await MainActor.run {
            NotificationCenter.default.post(name: Constants.NotificationName.hidePanel, object: nil)
        }

        // Wait until Sky is no longer frontmost (max 2 s)
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let frontmost = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
            if frontmost != Bundle.main.bundleIdentifier { break }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        do {
            let result = try await ComputerUseService.shared.findAndClick(instruction: instruction)
            let methodLabel: String = result.method == .visionCGEvent ? "vision" : "accessibility"
            ActionLogService.shared.record(
                summary: "Clicked '\(result.label)' via \(methodLabel)", succeeded: true)

            await MainActor.run {
                NotificationCenter.default.post(name: Constants.NotificationName.skyShowPanel, object: nil)
            }
            return .answer("Clicked '\(result.label)' ✓")

        } catch ComputerUseService.ComputerUseError.elementNotFound(let q) {
            await MainActor.run {
                NotificationCenter.default.post(name: Constants.NotificationName.skyShowPanel, object: nil)
            }
            return .failure("Couldn't find '\(q)' on screen — make sure the window is visible")

        } catch {
            await MainActor.run {
                NotificationCenter.default.post(name: Constants.NotificationName.skyShowPanel, object: nil)
            }
            LoggingService.shared.log(error: error, context: "handleComputerUse")
            return .failure("Computer use failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Execute Flow

    private func handleExecuteFlow(params: IntentParams) async -> ActionResult {
        let goal = params.body ?? params.query ?? ""
        guard !goal.isEmpty else { return .failure("What should I do?") }

        let contextURL = params.url ?? ContextService.shared.browserURL

        print("🌐 [ActionRouter] execute_flow via headless browser: '\(goal)' startUrl=\(contextURL ?? "none")")

        // Show flow panel — keeps panel visible with live progress
        await MainActor.run {
            NotificationCenter.default.post(
                name: Constants.NotificationName.flowStarted,
                object: nil,
                userInfo: ["goal": goal]
            )
            NotificationCenter.default.post(name: Constants.NotificationName.skyShowPanel, object: nil)
        }

        let result = await HeadlessFlowService.shared.execute(
            goal: goal,
            contextURL: contextURL,
            progressHandler: { msg in
                NotificationCenter.default.post(
                    name: Constants.NotificationName.flowStep,
                    object: nil,
                    userInfo: ["message": msg]
                )
            }
        )

        let succeeded = !result.hasPrefix("Browser error") && !result.contains("could not complete")
            && !result.contains("Stuck") && !result.contains("Reached maximum")

        // Post finish — PanelViewModel.finishFlow sets isFlowHandled=true before applyResults is called
        await MainActor.run {
            NotificationCenter.default.post(
                name: Constants.NotificationName.flowFinished,
                object: nil,
                userInfo: ["success": succeeded, "summary": result]
            )
        }

        return succeeded ? .answer(result) : .failure(result)
    }

    // MARK: - Create Skill

    private func handleCreateSkill() async -> ActionResult {
        await MainActor.run {
            NotificationCenter.default.post(name: Constants.NotificationName.showSkillCreation, object: nil)
            NotificationCenter.default.post(name: Constants.NotificationName.skyShowPanel, object: nil)
        }
        return .answer("")
    }

    // MARK: - Media Play Specific

    private func handleMediaPlaySpecific(params: IntentParams) async -> ActionResult {
        let query = params.query ?? ""
        guard !query.isEmpty else { return .failure("What should I play?") }
        let useMusic = params.body?.lowercased().contains("music") == true

        let escaped = appleScriptEscape(query)
        if useMusic {
            let script = """
            tell application "Music"
                activate
                search playlist "Library" for "\(escaped)"
            end tell
            """
            do {
                try await AppleScriptService.shared.execute(script)
                return .answer("Searching for \(query) in Apple Music ✓")
            } catch {
                return .failure("Could not play '\(query)': \(error.localizedDescription)")
            }
        } else {
            // play track "spotify:search:..." plays the top search result immediately
            let script = """
            tell application "Spotify"
                activate
                play track "spotify:search:\(escaped)"
            end tell
            """
            do {
                try await AppleScriptService.shared.execute(script)
                return .answer("Playing \(query) on Spotify ✓")
            } catch {
                return .failure("Could not play '\(query)': \(error.localizedDescription)")
            }
        }
    }

    // MARK: - What Do You See

    private func handleWhatDoYouSee() async -> ActionResult {
        guard let app = await MainActor.run(resultType: NSRunningApplication?.self, body: {
            NSWorkspace.shared.frontmostApplication
        }) else {
            return .answer("No active app")
        }
        let pid = app.processIdentifier
        let appName = app.localizedName ?? "this app"
        let elements = await MainActor.run(resultType: [ComputerUseService.AXElement].self) {
            ComputerUseService.shared.collectElements(from: AXUIElementCreateApplication(pid))
        }
        let buttons = elements.filter { $0.role == kAXButtonRole as String }.map { $0.label }
        let links   = elements.filter { $0.role == "AXLink" }.prefix(8).map { $0.label }
        let fields  = elements.filter {
            $0.role == kAXTextFieldRole as String || $0.role == "AXSearchField"
        }.map { $0.label }
        var lines = ["In \(appName) I can see:"]
        if !buttons.isEmpty { lines.append("Buttons: \(buttons.joined(separator: ", "))") }
        if !links.isEmpty   { lines.append("Links: \(Array(links).joined(separator: ", "))") }
        if !fields.isEmpty  { lines.append("Input fields: \(fields.joined(separator: ", "))") }
        if buttons.isEmpty && links.isEmpty && fields.isEmpty {
            lines.append("No interactive elements found — the page may still be loading")
        }
        return .answer(lines.joined(separator: "\n"))
    }

    // MARK: - Resolve Permission

    private func handleResolvePermission(params: IntentParams) async -> ActionResult {
        let choice = params.body ?? "Allow"

        let (permKey, resumeGoal) = await MainActor.run {
            (FlowExecutionService.shared.lastPermKey,
             FlowExecutionService.shared.lastGoal)
        }
        if !permKey.isEmpty {
            MemoryService.shared.setKeyedPreference(permKey, value: choice)
        }

        await MainActor.run {
            NotificationCenter.default.post(name: Constants.NotificationName.hidePanel, object: nil)
        }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let frontmost = await MainActor.run {
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            }
            if frontmost != Bundle.main.bundleIdentifier { break }
        }

        let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0 }
        let elements = await MainActor.run(resultType: [ComputerUseService.AXElement].self) {
            ComputerUseService.shared.collectElements(from: AXUIElementCreateApplication(pid))
        }
        if let match = await MainActor.run(resultType: ComputerUseService.AXElement?.self, body: {
            ComputerUseService.shared.findBestElement(matching: choice, in: elements)
        }) {
            AXUIElementPerformAction(match.element, kAXPressAction as CFString)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }

        guard !resumeGoal.isEmpty else {
            await MainActor.run {
                NotificationCenter.default.post(name: Constants.NotificationName.skyShowPanel, object: nil)
            }
            return .answer("Clicked '\(choice)' ✓")
        }

        let flowResult = await MainActor.run { FlowExecutionService.shared }.executeFlow(
            goal: resumeGoal,
            progressHandler: { print("🔄 [Permission resume] \($0)") }
        )
        await MainActor.run {
            NotificationCenter.default.post(name: Constants.NotificationName.skyShowPanel, object: nil)
        }
        if flowResult.hasPrefix("PERMISSION_NEEDED:") {
            let parts = flowResult.replacingOccurrences(of: "PERMISSION_NEEDED:", with: "")
            return .answer("\(parts)\n\nSay 'allow', 'never', or 'don't allow'.")
        }
        return .answer(flowResult)
    }

    // MARK: - Show Skills

    private func handleShowSkills() -> ActionResult {
        return .showSkillsList
    }

    // MARK: - Delete / Detail Skill

    private func skillsDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("Sky/skills")
    }

    /// Fuzzy-matches a skill file by query: matches full name, partial name, or any underscore-split word.
    private func findSkillFile(query: String) -> URL? {
        guard let dir = skillsDirectory(),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        let q = query.lowercased()
        return files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .first { file in
                let name = file.deletingPathExtension().lastPathComponent.lowercased()
                return name.contains(q) || q.contains(name)
                    || name.split(separator: "_").contains(where: { q.contains($0) })
            }
    }

    private func handleDeleteSkill(params: IntentParams) -> ActionResult {
        let query = (params.body ?? params.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .failure("Which skill do you want to delete?") }

        guard let file = findSkillFile(query: query) else {
            return .failure("Couldn't find a skill matching '\(query)'. Say 'show skills' to see all installed skills.")
        }
        let name = file.deletingPathExtension().lastPathComponent
        do {
            try FileManager.default.removeItem(at: file)
            DispatchQueue.main.async {
                SkillsService.shared.reload()
                NotificationCenter.default.post(name: Constants.NotificationName.rebuildSkillsMenu, object: nil)
            }
            print("🎯 [Skills] Deleted via panel: \(name)")
            return .answer("Skill '\(name)' deleted.")
        } catch {
            return .failure("Could not delete skill: \(error.localizedDescription)")
        }
    }

    private func handleShowSkillDetail(params: IntentParams) -> ActionResult {
        let query = (params.body ?? params.query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return handleShowSkills() }

        guard let file = findSkillFile(query: query) else {
            return .failure("Couldn't find a skill matching '\(query)'. Say 'show skills' to see all installed skills.")
        }
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("Could not read skill file.")
        }
        let name      = json["name"]        as? String ?? ""
        let overview  = json["overview"]    as? String ?? ""
        let triggers  = (json["triggers"]   as? [String])?.joined(separator: ", ") ?? ""
        let mode      = json["mode"]        as? String ?? "background"
        let startUrl  = json["start_url"]   as? String ?? ""
        let hint      = json["general_hint"] as? String ?? ""
        let pages     = json["pages"]       as? [[String: Any]] ?? []

        var lines: [String] = ["Skill: \(name) [\(mode)]"]
        if !overview.isEmpty  { lines.append("What it does: \(overview)") }
        if !triggers.isEmpty  { lines.append("Trigger by saying: \(triggers)") }
        if !startUrl.isEmpty  { lines.append("Starts at: \(startUrl)") }
        if !pages.isEmpty {
            lines.append("")
            lines.append("Pages covered:")
            for page in pages {
                let desc = page["description"] as? String ?? ""
                let url  = page["url_contains"] as? String ?? ""
                if !desc.isEmpty { lines.append("  • \(desc) (\(url))") }
            }
        }
        if !hint.isEmpty {
            lines.append("")
            lines.append("Instructions: \(hint)")
        }
        lines.append("")
        lines.append("Say 'delete \(name) skill' to remove it.")
        return .answer(lines.joined(separator: "\n"))
    }

    // MARK: - Save Memory

    /// Saves an alias, fact, or preference to MemoryService.
    private func handleSaveMemory(params: IntentParams) -> ActionResult {
        let category = params.memoryCategory ?? ""
        switch category {
        case "alias":
            guard let key = params.memoryKey, !key.isEmpty,
                  let value = params.memoryValue, !value.isEmpty else {
                return .failure("No alias provided — say 'remember mum is Jane Wilson'")
            }
            MemoryService.shared.setAlias(key, to: value)
            return .success("Remembered: \(key) → \(value) ✓")

        case "fact":
            guard let fact = params.memoryValue, !fact.isEmpty else {
                return .failure("No fact provided — say 'remember I live in London'")
            }
            MemoryService.shared.addFact(fact)
            return .success("Fact saved ✓")

        case "preference":
            guard let pref = params.memoryValue, !pref.isEmpty else {
                return .failure("No preference provided")
            }
            if let key = params.memoryKey, !key.isEmpty {
                MemoryService.shared.setKeyedPreference(key, value: pref)
                return .success("Remembered: \(key) = \(pref) ✓")
            }
            MemoryService.shared.addPreference(pref)
            return .success("Preference saved ✓")

        default:
            // Try to infer from available fields
            if let key = params.memoryKey, let value = params.memoryValue, !key.isEmpty, !value.isEmpty {
                MemoryService.shared.setAlias(key, to: value)
                return .success("Remembered: \(key) → \(value) ✓")
            }
            if let value = params.memoryValue ?? params.body, !value.isEmpty {
                MemoryService.shared.addFact(value)
                return .success("Remembered ✓")
            }
            return .failure("Nothing to remember — try 'remember mum is Jane Wilson'")
        }
    }

    // MARK: - Helpers

    /// Resolves a contact name or email string to an email address via ContactsService.
    private func resolveEmail(from nameOrEmail: String?) -> String? {
        guard let input = nameOrEmail, !input.isEmpty else { return nil }
        if input.contains("@") && input.contains(".") { return input }
        return ContactsService.shared.resolve(nameOrEmail: input)?.email
    }

    /// Resolves a contact name or phone string to a phone number via ContactsService.
    private func resolvePhone(from nameOrPhone: String?) -> String? {
        guard let input = nameOrPhone, !input.isEmpty else { return nil }
        if input.first == "+" || input.allSatisfy({ $0.isNumber || $0 == "-" || $0 == " " }) {
            return input
        }
        return ContactsService.shared.resolve(nameOrEmail: input)?.phone
    }

    /// Parses an ISO 8601 date string, trying multiple formatters for robustness.
    /// All option sets include .withTimeZone so timezone offsets in AI-returned datetimes are respected.
    private func parseDate(_ string: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime, .withTimeZone]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: string) { return d }
        iso.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withTimeZone]
        return iso.date(from: string)
    }

    /// Formats a Date as a short relative string for display in success messages.
    private func relativeDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }

    /// Extracts the first http/https URL from a string (used for meeting links in notes).
    private func extractURL(from text: String) -> String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?
            .firstMatch(in: text, options: [], range: range)
            .flatMap { URL(string: String(text[Range($0.range, in: text)!]))?.absoluteString }
    }

    /// Escapes a string so it is safe to embed inside an AppleScript double-quoted string literal.
    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Opens a URL on the main actor via NSWorkspace.
    private func openURL(_ url: URL) async {
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }

    // MARK: - Browser Login

    private func handleBrowserLogin(params: IntentParams) async -> ActionResult {
        let site = (params.body ?? "amazon").lowercased()
        let loginURLs: [String: String] = [
            "amazon":   "https://www.amazon.in/ap/signin",
            "flipkart": "https://www.flipkart.com/account/login",
            "swiggy":   "https://www.swiggy.com/",
            "zomato":   "https://www.zomato.com/"
        ]
        let url = loginURLs.first(where: { site.contains($0.key) })?.value ?? "https://www.amazon.in"
        let siteName = loginURLs.keys.first(where: { site.contains($0) }) ?? site
        do {
            let browser = await MainActor.run { HeadlessBrowserService.shared }
            try await browser.start()
            try await browser.startLoginFlow(url: url)
            return .answer("A browser window just opened at \(siteName). Log in manually, then say \"done\".")
        } catch {
            return .failure("Could not open login browser: \(error.localizedDescription)")
        }
    }

    private func handleBrowserLoginDone() async -> ActionResult {
        let browser = await MainActor.run { HeadlessBrowserService.shared }
        await MainActor.run { browser.signalLoginDone() }
        do {
            try await browser.waitForLoginComplete()
            return .answer("Login saved ✓ Sky will use this session for all future flows.")
        } catch {
            return .failure("Login session could not be saved: \(error.localizedDescription)")
        }
    }

    // MARK: - Test Browser

    private func handleTestBrowser() async -> ActionResult {
        do {
            let browser = await MainActor.run { HeadlessBrowserService.shared }
            try await browser.start()
            try await browser.navigate(to: "https://www.amazon.in")
            let snapshot = try await browser.takeSnapshot()
            await MainActor.run { browser.stop() }
            return .answer("Headless browser working ✓\n\nAmazon snapshot:\n\(String(snapshot.prefix(400)))")
        } catch {
            return .failure("Browser test failed: \(error.localizedDescription)")
        }
    }

    /// Runs a subprocess and returns stdout as a String.
    private func runProcess(_ launchPath: String, args: [String]) async -> String {
        await withCheckedContinuation { cont in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: data, encoding: .utf8) ?? "")
            } catch {
                cont.resume(returning: "")
            }
        }
    }
}
