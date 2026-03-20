import Foundation
import AppKit

/// Manages a persistent headless browser process (Node.js + Playwright).
/// The browser process stays alive between commands for efficiency.
/// Communication is via stdin/stdout JSON lines.
@MainActor
final class HeadlessBrowserService {
    static let shared = HeadlessBrowserService()
    private init() {}

    // MARK: - Types

    struct BrowserMessage: Codable, Sendable {
        let type: String
        let message: String?
        let content: String?
        let url: String?
        let title: String?
        let elementCount: Int?
        let success: Bool?
        let summary: String?
        let steps: Int?
        let status: String?
        let target: String?
    }

    enum BrowserError: Error, LocalizedError {
        case nodeNotFound
        case runnerNotFound
        case processLaunchFailed(String)
        case timeout
        case browserError(String)

        var errorDescription: String? {
            switch self {
            case .nodeNotFound:               return "Node.js not found. Please install Node.js from nodejs.org"
            case .runnerNotFound:             return "Browser runner script not found"
            case .processLaunchFailed(let m): return "Failed to launch browser: \(m)"
            case .timeout:                    return "Browser operation timed out"
            case .browserError(let m):        return m
            }
        }
    }

    // MARK: - State

    private var process: Process?
    private var stdinPipe: Pipe?
    private(set) var isRunning = false
    private var messageBuffer = ""

    /// Each handler returns true when it has matched and should be removed.
    private var messageHandlers: [(BrowserMessage) -> Bool] = []

    // MARK: - Paths

    /// Path to node binary — checks common locations. Internal so AppDelegate can read it.
    var nodePath: String {
        let candidates = [
            Bundle.main.bundlePath + "/Contents/Resources/node/bin/node",
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node"
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
            ?? "/usr/local/bin/node"
    }

    /// Path to runner.js — checks bundle then dev fallback.
    private var runnerPath: String {
        if let bundled = Bundle.main.path(forResource: "runner", ofType: "js") {
            return bundled
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask).first!
        let installed = appSupport.appendingPathComponent("Sky/browser/runner.js").path
        if FileManager.default.fileExists(atPath: installed) { return installed }

        // Development fallback — project directory relative to executable
        let devPath = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()          // Services/
            .deletingLastPathComponent()          // Sky/
            .deletingLastPathComponent()          // project root
            .appendingPathComponent("sky-browser/runner.js").path
        return devPath
    }

    /// Directory containing node_modules (same folder as runner.js).
    private var runnerDirectory: String {
        URL(fileURLWithPath: runnerPath).deletingLastPathComponent().path
    }

    // MARK: - Lifecycle

    /// Start the browser process. Safe to call multiple times — no-ops if already running.
    func start() async throws {
        if isRunning {
            // Verify the process is actually alive — it may have died without clearing isRunning
            if let proc = process, proc.isRunning {
                print("🌐 [Browser] Already running")
                return
            }
            // Process died — reset state and fall through to restart
            print("🌐 [Browser] Process died — restarting")
            isRunning = false
            process = nil
            stdinPipe = nil
            messageHandlers = []
        }

        guard FileManager.default.fileExists(atPath: nodePath) else {
            throw BrowserError.nodeNotFound
        }
        guard FileManager.default.fileExists(atPath: runnerPath) else {
            print("🌐 [Browser] Runner not found at: \(runnerPath)")
            throw BrowserError.runnerNotFound
        }

        print("🌐 [Browser] Starting — node: \(nodePath)")
        print("🌐 [Browser] Runner: \(runnerPath)")

        let proc = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [runnerPath]
        proc.currentDirectoryURL = URL(fileURLWithPath: runnerDirectory)
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        var env = ProcessInfo.processInfo.environment
        env["NODE_PATH"] = runnerDirectory + "/node_modules"
        env["PLAYWRIGHT_BROWSERS_PATH"] = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/ms-playwright").path
        proc.environment = env

        self.process = proc
        self.stdinPipe = stdin

        // Read stdout asynchronously — never blocks the main thread
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in
                self?.processOutput(text)
            }
        }

        // Log stderr for debugging
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
            print("🌐 [Browser stderr] \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.process = nil
                print("🌐 [Browser] Process terminated")
            }
        }

        do {
            try proc.run()
            isRunning = true
            print("🌐 [Browser] Process started, PID: \(proc.processIdentifier)")
        } catch {
            throw BrowserError.processLaunchFailed(error.localizedDescription)
        }

        // Wait for "Browser initialized" result message
        _ = try await waitForMessage(type: "result", timeout: 20)
    }

    /// Stop the browser process gracefully.
    func stop() {
        guard isRunning else { return }
        sendCommand(["action": "close"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.process?.terminate()
            self?.isRunning = false
            self?.process = nil
        }
        print("🌐 [Browser] Stopped")
    }

    // MARK: - Commands

    /// Navigate to a URL and wait for page to load.
    func navigate(to url: String) async throws {
        try await ensureRunning()
        sendCommand(["action": "navigate", "url": url])
        let msg = try await waitForMessage(type: "result", timeout: 35)
        guard msg.success == true else {
            throw BrowserError.browserError(msg.message ?? "Navigation failed")
        }
        print("🌐 [Browser] Navigated to \(url)")
    }

    /// Take an accessibility snapshot. Returns structured text of all interactive elements.
    func takeSnapshot() async throws -> String {
        try await ensureRunning()
        sendCommand(["action": "snapshot"])
        let msg = try await waitForMessage(type: "snapshot", timeout: 15)
        guard let content = msg.content else {
            throw BrowserError.browserError("Empty snapshot")
        }
        print("🌐 [Browser] Snapshot: \(msg.elementCount ?? 0) elements")
        return content
    }

    /// Click an element by its visible text label.
    func click(target: String) async throws {
        try await ensureRunning()
        sendCommand(["action": "click", "target": target])
        let msg = try await waitForMessage(type: "result", timeout: 10)
        guard msg.success == true else {
            throw BrowserError.browserError(msg.message ?? "Click failed")
        }
        print("🌐 [Browser] Clicked: \(target)")
    }

    /// Type text into a field identified by placeholder or label.
    func type(target: String, text: String) async throws {
        try await ensureRunning()
        sendCommand(["action": "type", "target": target, "text": text])
        let msg = try await waitForMessage(type: "result", timeout: 10)
        guard msg.success == true else {
            throw BrowserError.browserError(msg.message ?? "Type failed")
        }
    }

    /// Get the current page URL.
    func getCurrentURL() async throws -> String {
        try await ensureRunning()
        sendCommand(["action": "geturl"])
        let msg = try await waitForMessage(type: "result", timeout: 5)
        return msg.url ?? msg.message ?? ""
    }

    // MARK: - Internal

    private func ensureRunning() async throws {
        if !isRunning { try await start() }
    }

    /// Run a complete autonomous flow in the headless browser.
    /// The browser navigates, perceives, reasons, and acts until goal is complete.
    func runFlow(
        goal: String,
        startUrl: String?,
        skillHint: String?,
        progressHandler: @escaping @MainActor (String) -> Void
    ) async throws -> (success: Bool, summary: String) {
        try await ensureRunning()

        let config = ConfigService.shared.config
        let apiKey = config.aiProvider == "openai" ? config.openaiApiKey : config.anthropicAPIKey
        let apiProvider = config.aiProvider

        var command: [String: Any] = [
            "action": "runflow",
            "goal": goal,
            "apiKey": apiKey,
            "apiProvider": apiProvider,
            "maxSteps": 12
        ]
        if let url = startUrl { command["startUrl"] = url }
        if let hint = skillHint { command["skillHint"] = hint }

        sendCommandAny(command)

        let (stream, cont) = AsyncStream<BrowserMessage>.makeStream()

        messageHandlers.append { message in
            if message.type == "progress" {
                let msg = message.message ?? ""
                Task { @MainActor in progressHandler(msg) }
                return false
            }
            if message.type == "confirmationneeded" {
                let confirmMsg = message.message ?? "About to take an action. Confirm?"
                let confirmTarget = message.target ?? ""
                // If the user previously chose "Allow Always", auto-confirm without showing UI
                if BrowserConfirmationStore.isAlwaysAllowed(target: confirmTarget) {
                    MainActor.assumeIsolated {
                        HeadlessBrowserService.shared.confirmAction(confirm: true)
                    }
                    return false
                }
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: Constants.NotificationName.skyBrowserConfirmation,
                        object: nil,
                        userInfo: ["message": confirmMsg, "target": confirmTarget]
                    )
                    NotificationCenter.default.post(
                        name: Constants.NotificationName.skyShowPanel, object: nil)
                }
                return false // keep handler — waiting for flowcomplete
            }
            if message.type == "flowcomplete" || message.type == "error" {
                cont.yield(message)
                cont.finish()
                return true
            }
            return false
        }

        return try await withThrowingTaskGroup(of: (Bool, String).self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: 300_000_000_000) // 5-minute timeout
                cont.finish()
                throw HeadlessBrowserService.BrowserError.timeout
            }
            group.addTask {
                for await message in stream {
                    if message.type == "error" {
                        throw HeadlessBrowserService.BrowserError.browserError(
                            message.message ?? "Unknown browser error")
                    }
                    let success = message.success ?? false
                    let summary = message.summary ?? (success ? "Done ✓" : "Flow could not complete")
                    return (success, summary)
                }
                throw HeadlessBrowserService.BrowserError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Opens a visible browser window for manual login, saves session when signalled done.
    func startLoginFlow(url: String, sessionName: String = "default") async throws {
        try await ensureRunning()
        let command: [String: String] = ["action": "loginflow", "url": url, "sessionName": sessionName]
        sendCommand(command)
        print("🌐 [Browser] Started login flow for: \(url)")
        _ = try await waitForMessage(type: "loginsession", timeout: 15)
    }

    /// Signals to runner.js that the user has finished logging in.
    func signalLoginDone() {
        guard let pipe = stdinPipe,
              let data = "{\"action\":\"logindone\"}\n".data(using: .utf8) else { return }
        pipe.fileHandleForWriting.write(data)
        print("🌐 [Browser] Signalled login done")
    }

    /// Waits for the login session to be fully saved.
    func waitForLoginComplete() async throws {
        _ = try await waitForMessage(type: "result", timeout: 60)
        print("🌐 [Browser] Login session saved")
    }

    /// Sends a confirm or cancel signal during an order confirmation pause.
    func confirmAction(confirm: Bool) {
        let json = confirm ? "{\"action\":\"confirmed\"}\n" : "{\"action\":\"cancelled\"}\n"
        guard let pipe = stdinPipe, let data = json.data(using: .utf8) else { return }
        pipe.fileHandleForWriting.write(data)
        print("🌐 [Browser] Confirmation: \(confirm ? "confirmed" : "cancelled")")
    }

    private func sendCommandAny(_ command: [String: Any]) {
        guard let pipe = stdinPipe,
              let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8) else { return }
        let line = json + "\n"
        guard let lineData = line.data(using: .utf8) else { return }
        pipe.fileHandleForWriting.write(lineData)
        print("🌐 [Browser] → \(json.prefix(120))")
    }

    private func sendCommand(_ command: [String: String]) {
        guard let pipe = stdinPipe,
              let data = try? JSONSerialization.data(withJSONObject: command),
              let json = String(data: data, encoding: .utf8) else { return }
        let line = json + "\n"
        guard let lineData = line.data(using: .utf8) else { return }
        pipe.fileHandleForWriting.write(lineData)
        print("🌐 [Browser] → \(json)")
    }

    private func processOutput(_ text: String) {
        messageBuffer += text
        let lines = messageBuffer.components(separatedBy: "\n")
        messageBuffer = lines.last ?? ""

        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let message = try? JSONDecoder().decode(BrowserMessage.self, from: data) else {
                print("🌐 [Browser] ← (non-JSON): \(trimmed)")
                continue
            }
            let preview = message.content.map { String($0.prefix(80)) } ?? message.message ?? ""
            print("🌐 [Browser] ← \(message.type): \(preview)")

            // Call handlers; keep only those that haven't matched yet
            messageHandlers = messageHandlers.filter { !$0(message) }
        }
    }

    /// Wait for the next message of the given type (or an error message).
    /// Uses AsyncStream so there are no abandoned continuations.
    private func waitForMessage(type targetType: String, timeout: TimeInterval) async throws -> BrowserMessage {
        let (stream, streamCont) = AsyncStream<BrowserMessage>.makeStream()

        // Register a one-shot handler that yields into the stream then closes it
        messageHandlers.append { message in
            guard message.type == targetType || message.type == "error" else { return false }
            streamCont.yield(message)
            streamCont.finish()
            return true // matched — remove this handler
        }

        return try await withThrowingTaskGroup(of: BrowserMessage.self) { group in
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                streamCont.finish() // unblock the for-await below
                throw HeadlessBrowserService.BrowserError.timeout
            }

            group.addTask {
                for await message in stream {
                    if message.type == "error" {
                        throw HeadlessBrowserService.BrowserError.browserError(
                            message.message ?? "Unknown browser error")
                    }
                    return message
                }
                throw HeadlessBrowserService.BrowserError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

// MARK: - Browser Confirmation Store

/// Persists the user's "Allow Always" choices for browser confirmation actions.
enum BrowserConfirmationStore {
    private static let key = "sky.browser.alwaysAllow"

    static func isAlwaysAllowed(target: String) -> Bool {
        let allowed = UserDefaults.standard.stringArray(forKey: key) ?? []
        return allowed.contains(target.lowercased())
    }

    static func setAlwaysAllowed(target: String) {
        var allowed = UserDefaults.standard.stringArray(forKey: key) ?? []
        let lower = target.lowercased()
        guard !allowed.contains(lower) else { return }
        allowed.append(lower)
        UserDefaults.standard.set(allowed, forKey: key)
    }
}
