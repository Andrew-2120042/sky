import Foundation

/// Manages reading and writing the app configuration file at ~/Library/Application Support/Sky/config.json
@MainActor
final class ConfigService {

    /// Shared singleton instance.
    static let shared = ConfigService()

    /// The currently loaded configuration held in memory.
    private(set) var config: AppConfig = AppConfig()

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = appSupport.appendingPathComponent(Constants.App.supportDirectoryName)
        fileURL = directory.appendingPathComponent(Constants.Config.fileName)
        load()
    }

    /// Returns true if an API key for the currently selected provider has been configured.
    var hasAPIKey: Bool {
        if config.aiProvider == "openai" {
            return !config.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !config.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Loads config from disk, creating defaults if file does not exist.
    /// On first load, migrates any keys found at the legacy (non-sandboxed) path.
    func load() {
        let fm = FileManager.default
        let directory = fileURL.deletingLastPathComponent()

        // Ensure directory exists
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // Attempt one-time migration from the legacy non-sandboxed path.
        migrateFromLegacyPathIfNeeded()

        guard fm.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            config = AppConfig()
            save()
            return
        }
        config = decoded
    }

    /// Checks for a config at the non-sandboxed Application Support path and merges any
    /// non-empty API keys into the current (sandboxed) config file, then removes the old file.
    private func migrateFromLegacyPathIfNeeded() {
        // Derive the real user home by stripping the sandbox container suffix if present.
        let sandboxHome = NSHomeDirectory()
        let realHome: String
        if let range = sandboxHome.range(of: "/Library/Containers/") {
            realHome = String(sandboxHome[..<range.lowerBound])
        } else {
            realHome = sandboxHome  // already non-sandboxed
        }

        let legacyURL = URL(fileURLWithPath: realHome)
            .appendingPathComponent("Library/Application Support/Sky/config.json")

        // Nothing to migrate if legacy file is already gone or is our own file.
        guard legacyURL.path != fileURL.path,
              FileManager.default.fileExists(atPath: legacyURL.path),
              let data = try? Data(contentsOf: legacyURL),
              let legacy = try? JSONDecoder().decode(AppConfig.self, from: data) else { return }

        // Only migrate if the legacy file actually has keys we don't have yet.
        let hasNewAnthropicKey = !legacy.anthropicAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasNewOpenAIKey    = !legacy.openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasNewAnthropicKey || hasNewOpenAIKey else { return }

        // Read the current config (if any) so we don't overwrite hotkey settings.
        var merged = AppConfig()
        if FileManager.default.fileExists(atPath: fileURL.path),
           let existingData = try? Data(contentsOf: fileURL),
           let existing = try? JSONDecoder().decode(AppConfig.self, from: existingData) {
            merged = existing
        }
        if hasNewAnthropicKey { merged.anthropicAPIKey = legacy.anthropicAPIKey }
        if hasNewOpenAIKey    { merged.openaiApiKey    = legacy.openaiApiKey }
        merged.aiProvider = legacy.aiProvider

        if let migratedData = try? JSONEncoder().encode(merged) {
            try? migratedData.write(to: fileURL, options: .atomic)
        }

        // Remove legacy file so migration only runs once.
        try? FileManager.default.removeItem(at: legacyURL)
        LoggingService.shared.log("Migrated config from legacy path to sandbox container")
    }

    /// Saves the current in-memory config to disk.
    func save() {
        guard let data = try? JSONEncoder().encode(config) else {
            print("[ConfigService] Failed to encode config")
            return
        }
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[ConfigService] Failed to write config: \(error)")
        }
    }

    /// Updates the Anthropic API key in memory and persists it.
    func setAPIKey(_ key: String) {
        config.anthropicAPIKey = key
        save()
    }

    /// Updates the OpenAI API key in memory and persists it.
    func setOpenAIAPIKey(_ key: String) {
        config.openaiApiKey = key
        save()
    }

    /// Updates the active AI provider and persists the config.
    func setProvider(_ provider: String) {
        config.aiProvider = provider
        save()
    }

    /// Saves both API keys and the provider in one atomic write.
    func saveKeys(anthropicKey: String, openaiKey: String, provider: String) {
        config.anthropicAPIKey = anthropicKey
        config.openaiApiKey = openaiKey
        config.aiProvider = provider
        save()
    }
}
