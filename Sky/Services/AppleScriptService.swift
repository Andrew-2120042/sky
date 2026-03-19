import Foundation

/// Executes NSAppleScript strings on a dedicated serial queue and returns success or throws.
final class AppleScriptService: Sendable {

    /// Shared singleton; safe to call from any context.
    static let shared = AppleScriptService()

    private let appleScriptQueue = DispatchQueue(label: "com.andrewwilson.Sky.applescript")

    private init() {}

    // MARK: - Execution

    /// Runs `script` synchronously on a dedicated serial queue, throwing on failure.
    func execute(_ script: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            appleScriptQueue.async {
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(throwing: AppleScriptError.executionFailed("Could not initialise NSAppleScript"))
                    return
                }
                var errDict: NSDictionary?
                appleScript.executeAndReturnError(&errDict)
                if let err = errDict {
                    let message = err[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
                    continuation.resume(throwing: AppleScriptError.executionFailed(message))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    /// Runs `script` and returns the script's return value as a String, throwing on failure.
    func executeWithResult(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                guard let appleScript = NSAppleScript(source: script) else {
                    continuation.resume(throwing: AppleScriptError.executionFailed("Could not initialise NSAppleScript"))
                    return
                }
                let result = appleScript.executeAndReturnError(&error)
                if let error {
                    continuation.resume(throwing: AppleScriptError.executionFailed(error.description))
                    return
                }
                // NSAppleEventDescriptor.stringValue is the correct way to read a return value
                continuation.resume(returning: result.stringValue ?? "")
            }
        }
    }
}

// MARK: - Error type

/// Errors thrown by `AppleScriptService.execute(_:)`.
enum AppleScriptError: LocalizedError {
    /// The script failed; the associated string contains the AppleScript error message.
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return "AppleScript execution failed: \(message)"
        }
    }
}
