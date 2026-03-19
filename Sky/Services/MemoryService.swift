import Foundation

/// Persists user-specific memory: aliases, facts, preferences, and frequent-contact tracking.
/// JSON-backed at ~/Library/Application Support/Sky/memory.json.
final class MemoryService: @unchecked Sendable {

    static let shared = MemoryService()

    // MARK: - Model

    struct Memory: Codable {
        /// Maps casual names (lowercased) to real names / emails. e.g. "mum" → "Jane Wilson".
        var aliases: [String: String] = [:]
        /// Arbitrary facts the user has told Sky. e.g. ["I live in London"].
        var facts: [String] = []
        /// Behavioural preferences. e.g. ["Prefer short replies"].
        var preferences: [String] = []
        /// Contact name → send count; used to build a frequent-contacts suggestion list.
        var frequentContacts: [String: Int] = [:]
        /// Structured key-value preferences, e.g. "meeting_camera" → "off".
        var keyedPreferences: [String: String] = [:]
    }

    private var memory: Memory = Memory()
    private let queue = DispatchQueue(label: "com.andrewwilson.Sky.memory")
    private let fileURL: URL

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sky")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("memory.json")
        load()
    }

    // MARK: - Persist

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(Memory.self, from: data) else { return }
        memory = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Returns a thread-safe snapshot of the current memory state.
    func readMemory() -> Memory {
        queue.sync { memory }
    }

    // MARK: - Aliases

    func setAlias(_ alias: String, to realName: String) {
        queue.sync { memory.aliases[alias.lowercased()] = realName; persist() }
    }

    func removeAlias(_ alias: String) {
        queue.sync { memory.aliases.removeValue(forKey: alias.lowercased()); persist() }
    }

    /// Returns the real name/email stored for `input` if an alias exists, otherwise nil.
    func resolveAlias(_ input: String) -> String? {
        queue.sync { memory.aliases[input.lowercased()] }
    }

    // MARK: - Facts

    func addFact(_ fact: String) {
        queue.sync {
            if !memory.facts.contains(fact) { memory.facts.append(fact) }
            persist()
        }
    }

    func removeFact(at index: Int) {
        queue.sync {
            guard memory.facts.indices.contains(index) else { return }
            memory.facts.remove(at: index)
            persist()
        }
    }

    // MARK: - Preferences

    func addPreference(_ preference: String) {
        queue.sync {
            if !memory.preferences.contains(preference) { memory.preferences.append(preference) }
            persist()
        }
    }

    func removePreference(at index: Int) {
        queue.sync {
            guard memory.preferences.indices.contains(index) else { return }
            memory.preferences.remove(at: index)
            persist()
        }
    }

    // MARK: - Keyed Preferences

    /// Stores a structured key-value preference (e.g. meeting_camera = off).
    func setKeyedPreference(_ key: String, value: String) {
        queue.sync { memory.keyedPreferences[key] = value; persist() }
    }

    /// Returns the value stored for a structured preference key, or nil if not set.
    func keyedPreference(_ key: String) -> String? {
        queue.sync { memory.keyedPreferences[key] }
    }

    // MARK: - Frequent Contacts

    func incrementContact(_ name: String) {
        queue.sync { memory.frequentContacts[name, default: 0] += 1; persist() }
    }

    var topContacts: [(name: String, count: Int)] {
        queue.sync {
            memory.frequentContacts
                .map { (name: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count }
                .prefix(5)
                .map { $0 }
        }
    }
}
