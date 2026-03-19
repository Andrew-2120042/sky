import AppKit

/// Reads the URL and page title from the frontmost browser tab via AppleScript.
/// Matches by bundle ID for reliability. Returns nil if no supported browser is frontmost.
final class BrowserContextService: @unchecked Sendable {

    static let shared = BrowserContextService()

    struct BrowserContext: Sendable {
        let appName: String
        let url: String
        let pageTitle: String?
    }

    private struct BrowserDef {
        let bundleID: String
        let name: String
        let script: String
    }

    private let browsers: [BrowserDef] = [
        BrowserDef(bundleID: "com.apple.Safari",            name: "Safari",  script: Constants.AppleScript.safariContext),
        BrowserDef(bundleID: "com.google.Chrome",           name: "Chrome",  script: Constants.AppleScript.chromeContext),
        BrowserDef(bundleID: "company.thebrowser.Browser",  name: "Arc",     script: Constants.AppleScript.arcContext),
        BrowserDef(bundleID: "org.mozilla.firefox",         name: "Firefox", script: Constants.AppleScript.safariContext)
    ]

    private init() {}

    /// Fetches the current tab URL and title from the frontmost browser.
    /// Returns nil if the frontmost app is not a supported browser, the script fails,
    /// or the result does not look like a valid URL.
    func fetchContext() async -> BrowserContext? {
        let bundleID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        }

        guard let browser = browsers.first(where: { bundleID.contains($0.bundleID) }) else {
            return nil
        }

        guard let result = try? await AppleScriptService.shared.executeWithResult(browser.script),
              !result.isEmpty else {
            return nil
        }

        let parts = result.components(separatedBy: "\n")
        let url = parts.first ?? ""

        // Guard: result must look like a real URL, not clipboard leak or error text
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else {
            return nil
        }

        let pageTitle = parts.dropFirst().first.flatMap { $0.isEmpty ? nil : $0 }
        return BrowserContext(appName: browser.name, url: url, pageTitle: pageTitle)
    }
}
