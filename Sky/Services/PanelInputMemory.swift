import Foundation

/// Remembers what the user was typing in the panel for up to 15 minutes.
/// Restored automatically when panel reopens within the window.
@MainActor final class PanelInputMemory {
    static let shared = PanelInputMemory()
    private init() {}

    private var savedText: String = ""
    private var savedAt: Date?
    private let expirySeconds: TimeInterval = 15 * 60

    func save(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        savedText = text
        savedAt = Date()
        print("💬 [InputMemory] Saved: \"\(text.prefix(40))\"")
    }

    func restore() -> String? {
        guard let savedAt,
              !savedText.isEmpty,
              Date().timeIntervalSince(savedAt) < expirySeconds else {
            clear()
            return nil
        }
        print("💬 [InputMemory] Restored: \"\(savedText.prefix(40))\"")
        return savedText
    }

    func clear() {
        savedText = ""
        savedAt = nil
    }
}
