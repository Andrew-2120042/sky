import Foundation

/// Writes timestamped log lines to ~/Library/Logs/Sky/sky.log.
final class LoggingService: @unchecked Sendable {

    /// Severity levels for log entries.
    enum LogLevel: String {
        case info    = "INFO"
        case warning = "WARNING"
        case error   = "ERROR"
    }

    /// Shared singleton; safe to call from any thread.
    static let shared = LoggingService()

    private let queue = DispatchQueue(label: "com.andrewwilson.Sky.logger")
    private var fileHandle: FileHandle?

    private init() {
        queue.sync {
            self.setupLogFile()
        }
    }

    // MARK: - Public API

    /// Appends a timestamped, levelled message to the log file.
    func log(_ message: String, level: LogLevel = .info) {
        queue.async { [weak self] in
            guard let self else { return }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            self.fileHandle?.seekToEndOfFile()
            self.fileHandle?.write(data)
        }
    }

    /// Convenience overload that logs an `Error` at the `.error` level with context.
    func log(error: Error, context: String) {
        log("\(context): \(error.localizedDescription)", level: .error)
    }

    // MARK: - Private helpers

    private func setupLogFile() {
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
                .appendingPathComponent("Logs/Sky") else { return }

        if !fm.fileExists(atPath: logsDir.path) {
            do {
                try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            } catch {
                // Cannot log yet — just return silently.
                return
            }
        }

        let logURL = logsDir.appendingPathComponent("sky.log")
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }

        fileHandle = try? FileHandle(forWritingTo: logURL)
    }
}
