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
        selectedText    = nil
        browserURL      = nil
        browserPageTitle = nil

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
