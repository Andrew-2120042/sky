import AppKit

/// Captures clipboard content, frontmost app, selected text, and browser context
/// whenever the panel opens. Call `refresh()` and await it — selected text is fully
/// resolved (on main thread, 200 ms timeout) before the method returns.
/// Browser context fires in parallel and may arrive slightly after the panel appears.
final class ContextService: @unchecked Sendable {

    static let shared = ContextService()

    // MARK: - Stored Context

    private(set) var clipboardText: String?
    private(set) var recentClipboardItems: [String] = []
    private(set) var frontmostApp: String?
    private(set) var frontmostAppBundleID: String?
    private(set) var selectedText: String?
    private(set) var browserURL: String?
    private(set) var browserPageTitle: String?
    private(set) var browserPageContent: String?
    private var pageContentFetched = false

    private(set) var currentFilePath: String?
    private(set) var currentFileContent: String?
    private(set) var nativeAppContext: String?

    private var lastChangeCount: Int = -1

    private init() {}

    // MARK: - Refresh

    /// Refreshes all context. Awaiting this guarantees selected text is populated
    /// (or timed out) before returning. Browser context runs concurrently and is
    /// stored whenever it arrives.
    @MainActor
    func refresh() async {
        // Clipboard — track changeCount so we only prepend new items
        let currentCount = NSPasteboard.general.changeCount
        if currentCount != lastChangeCount {
            lastChangeCount = currentCount
            if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                clipboardText = text
                recentClipboardItems.insert(text, at: 0)
                if recentClipboardItems.count > 10 {
                    recentClipboardItems = Array(recentClipboardItems.prefix(10))
                }
            }
        } else {
            clipboardText = recentClipboardItems.first
        }

        // Workspace — synchronous, safe on main actor
        frontmostApp         = NSWorkspace.shared.frontmostApplication?.localizedName
        frontmostAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Reset async fields
        selectedText     = nil
        browserURL       = nil
        browserPageTitle = nil

        // Reset page content cache on each fresh open
        pageContentFetched  = false
        browserPageContent  = nil

        // File context — synchronous AX + mdfind lookup
        let fileCtx = fetchFileContext()
        currentFilePath    = fileCtx.path
        currentFileContent = fileCtx.content

        // Native app context — synchronous AppleScript for Mail/Messages/Notes/Calendar
        nativeAppContext = fetchNativeAppContext()

        // Browser context — runs concurrently (AppleScript is slow, don't block panel appear)
        Task.detached { [weak self] in
            let ctx = await BrowserContextService.shared.fetchContext()
            await MainActor.run { [weak self] in
                self?.browserURL      = ctx?.url
                self?.browserPageTitle = ctx?.pageTitle
            }
        }

        // Selected text — AX must be on main thread; await with 200 ms timeout
        selectedText = await fetchSelectedTextWithTimeout()
    }

    // MARK: - Selected Text

    /// Dispatches an AX selected-text read to the main thread with a 200 ms timeout.
    /// Returns nil if the read times out or the frontmost app has no selection.
    private func fetchSelectedTextWithTimeout() async -> String? {
        await withCheckedContinuation { continuation in
            let state = OneShotFlag()

            // Timeout — fires from a background thread after 200 ms
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if state.complete() { continuation.resume(returning: nil) }
            }

            // AX call — must run on the main thread
            DispatchQueue.main.async {
                let result = self.fetchSelectedText()
                if state.complete() { continuation.resume(returning: result) }
            }
        }
    }

    /// Reads the selected text from the frontmost app via the Accessibility API.
    /// Must be called on the main thread.
    private func fetchSelectedText() -> String? {
        assert(Thread.isMainThread, "fetchSelectedText must run on the main thread")
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedElementRef: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedElementRef)
        guard focusedResult == .success, let focusedRef = focusedElementRef else { return nil }

        // Safe cast — we know this is an AXUIElement because we passed an AXUIElement in
        let focusedElement = focusedRef as! AXUIElement // swiftlint:disable:this force_cast

        var selectedTextRef: CFTypeRef?
        let textResult = AXUIElementCopyAttributeValue(
            focusedElement, kAXSelectedTextAttribute as CFString, &selectedTextRef)
        guard textResult == .success else { return nil }

        let text = selectedTextRef as? String
        return text?.isEmpty == true ? nil : text
    }

    // MARK: - Browser Page Content

    /// Reads up to 2 500 chars of visible page text from the frontmost browser via AppleScript.
    /// Returns nil if the frontmost app is not a supported browser or the script fails.
    private func fetchBrowserPageContent() async -> String? {
        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        let script: String
        if bundleID.contains("com.apple.Safari") {
            script = """
            tell application "Safari"
                set pageText to do JavaScript "document.body.innerText.substring(0, 3000)" in current tab of front window
                return pageText
            end tell
            """
        } else if bundleID.contains("com.google.Chrome") {
            script = """
            tell application "Google Chrome"
                set pageText to execute active tab of front window javascript "document.body.innerText.substring(0, 3000)"
                return pageText
            end tell
            """
        } else if bundleID.contains("company.thebrowser.Browser") {
            script = """
            tell application "Arc"
                set pageText to execute active tab of front window javascript "document.body.innerText.substring(0, 3000)"
                return pageText
            end tell
            """
        } else {
            return nil
        }

        let result = try? await AppleScriptService.shared.executeWithResult(script)
        guard let text = result, !text.isEmpty, text.count > 50 else { return nil }
        let cleaned = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .prefix(2500)
        return String(cleaned)
    }

    /// Fetches page content lazily — only runs once per panel session.
    /// Call this when the user's command suggests they want page content.
    func fetchPageContentIfNeeded() async {
        guard !pageContentFetched else { return }
        pageContentFetched = true
        browserPageContent = await fetchBrowserPageContent()
    }

    // MARK: - Native App Context

    /// Reads structured context from the frontmost native app via AppleScript.
    /// Called synchronously from refresh() — returns nil gracefully on any error.
    private func fetchNativeAppContext() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? ""

        if bundleID.contains("com.apple.mail") {
            return fetchMailContext()
        } else if bundleID.contains("com.apple.MobileSMS") {
            return fetchMessagesContext()
        } else if bundleID.contains("com.apple.Notes") {
            return fetchNotesContext()
        } else if bundleID.contains("com.apple.iCal") {
            return fetchCalendarContext()
        }
        return nil
    }

    private func fetchMailContext() -> String? {
        let script = """
        tell application "Mail"
            if selection is not {} then
                set theMessage to item 1 of selection
                set theSender to sender of theMessage
                set theSubject to subject of theMessage
                set theContent to content of theMessage
                return "From: " & theSender & "\\nSubject: " & theSubject & "\\nBody: " & text 1 thru (min(500, count of characters of theContent)) of theContent
            end if
        end tell
        """
        let result = try? runAppleScriptSync(script)
        guard let text = result, !text.isEmpty else { return nil }
        return text
    }

    private func fetchMessagesContext() -> String? {
        let script = """
        tell application "Messages"
            set theChat to active chat
            if theChat is not missing value then
                set chatName to name of theChat
                return "Messages conversation with: " & chatName
            end if
        end tell
        """
        return try? runAppleScriptSync(script)
    }

    private func fetchNotesContext() -> String? {
        let script = """
        tell application "Notes"
            if selection is not {} then
                set theNote to item 1 of selection
                set theTitle to name of theNote
                set theBody to plaintext of theNote
                return "Open note: " & theTitle & "\\n" & text 1 thru (min(300, count of characters of theBody)) of theBody
            end if
        end tell
        """
        return try? runAppleScriptSync(script)
    }

    private func fetchCalendarContext() -> String? {
        let script = """
        tell application "Calendar"
            tell front document
                if selection is not {} then
                    set theEvent to item 1 of selection
                    set theTitle to summary of theEvent
                    set theStart to start date of theEvent
                    return "Selected calendar event: " & theTitle & " on " & (theStart as string)
                end if
            end tell
        end tell
        """
        return try? runAppleScriptSync(script)
    }

    private func runAppleScriptSync(_ script: String) throws -> String? {
        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        let result = appleScript?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue
    }

    // MARK: - File Context

    /// Reads the name and (for text files/PDFs) content of the file open in the frontmost app.
    /// Uses the AX window title to identify the file, then resolves its path via mdfind.
    private func fetchFileContext() -> (path: String?, content: String?) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (nil, nil) }
        let bundleID = app.bundleIdentifier ?? ""

        let fileApps = [
            "com.apple.Preview",
            "com.apple.TextEdit",
            "com.microsoft.Word",
            "com.microsoft.Excel",
            "com.apple.Notes",
            "com.todesktop.230313mzl4w4u92",  // Cursor
            "com.microsoft.VSCode",
            "dev.warp.Warp-Stable",
            "com.apple.dt.Xcode"
        ]
        guard fileApps.contains(where: { bundleID.contains($0) }) else { return (nil, nil) }

        // Get the focused window title via Accessibility API
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard let windowRef else { return (nil, nil) }
        let window = windowRef as! AXUIElement // swiftlint:disable:this force_cast
        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        guard let title = titleRef as? String, !title.isEmpty else { return (nil, nil) }

        // Strip the app name suffix to isolate the filename
        let appName = app.localizedName ?? ""
        let filename = title
            .replacingOccurrences(of: " — \(appName)", with: "")
            .replacingOccurrences(of: " - \(appName)", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !filename.isEmpty && filename != appName else { return (nil, nil) }

        // Resolve to a full path using mdfind
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["-name", filename]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let filePath = output.components(separatedBy: "\n").first(where: { !$0.isEmpty })

        // Read content for supported text formats
        var content: String?
        if let path = filePath {
            let url = URL(fileURLWithPath: path)
            let ext = url.pathExtension.lowercased()
            let textExtensions = ["txt", "md", "swift", "js", "py", "html", "css", "json", "xml", "csv"]
            if textExtensions.contains(ext) {
                content = (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(2500)) }
            } else if ext == "pdf" {
                let pdfTask = Process()
                pdfTask.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
                pdfTask.arguments = ["-name", "kMDItemTextContent", path]
                let pdfPipe = Pipe()
                pdfTask.standardOutput = pdfPipe
                try? pdfTask.run()
                pdfTask.waitUntilExit()
                let raw = String(data: pdfPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let pdfText = raw
                    .replacingOccurrences(of: "kMDItemTextContent = \"", with: "")
                    .replacingOccurrences(of: "\"", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pdfText.isEmpty && pdfText != "(null)" {
                    content = String(pdfText.prefix(2500))
                }
            }
        }

        return (filePath ?? filename, content)
    }

    // MARK: - Generic timeout helper (kept for other callers)

    /// Runs `operation` on a background thread and returns its result, or nil if it takes
    /// longer than `milliseconds`. Safe to call from any async context.
    func withTimeoutOrNil<T: Sendable>(milliseconds: Int, operation: @escaping @Sendable () -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            let state = OneShotFlag()
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                if state.complete() { continuation.resume(returning: nil) }
            }
            DispatchQueue.global().async {
                let result = operation()
                if state.complete() { continuation.resume(returning: result) }
            }
        }
    }
}

// MARK: - Thread-safe one-shot flag

/// Ensures only the first caller wins a continuation resume race.
private final class OneShotFlag: @unchecked Sendable {
    private var _done = false
    private let lock  = NSLock()

    /// Returns true exactly once across all callers; false on every subsequent call.
    func complete() -> Bool {
        lock.withLock {
            guard !_done else { return false }
            _done = true
            return true
        }
    }
}
