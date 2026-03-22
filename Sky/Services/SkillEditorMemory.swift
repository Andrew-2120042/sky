import Foundation

/// Remembers skill editor content until saved or explicitly cancelled.
/// Works the same as PanelInputMemory but for the skill editor.
/// Has no expiry — persists until save or ESC.
@MainActor
final class SkillEditorMemory {
    static let shared = SkillEditorMemory()
    private init() {}

    private var savedText: String = ""
    private var savedFilePath: String = ""
    private var savedMode: String = "natural"   // "natural" or "json"
    private var savedOriginalJSON: String = ""

    func save(text: String, filePath: String, mode: String, originalJSON: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        savedText = text
        savedFilePath = filePath
        savedMode = mode
        savedOriginalJSON = originalJSON
        print("📝 [SkillEditorMemory] Saved editor state for \(filePath)")
    }

    func restore() -> (text: String, filePath: String, mode: String, originalJSON: String)? {
        guard !savedText.isEmpty && !savedFilePath.isEmpty else { return nil }
        print("📝 [SkillEditorMemory] Restored editor state for \(savedFilePath)")
        return (savedText, savedFilePath, savedMode, savedOriginalJSON)
    }

    func clear() {
        guard hasContent else { return }
        savedText = ""
        savedFilePath = ""
        savedMode = "natural"
        savedOriginalJSON = ""
        print("📝 [SkillEditorMemory] Cleared")
    }

    var hasContent: Bool { !savedText.isEmpty && !savedFilePath.isEmpty }
}
