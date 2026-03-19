import Foundation

/// Persisted user configuration stored in ~/Library/Application Support/Sky/config.json
struct AppConfig: Codable {
    /// Anthropic API key used for intent parsing
    var anthropicAPIKey: String

    /// OpenAI API key used when aiProvider is "openai"
    var openaiApiKey: String

    /// Which AI provider to use: "anthropic" or "openai"
    var aiProvider: String

    /// Keyboard shortcut key code (default: Space = 49)
    var hotkeyKeyCode: UInt16

    /// Keyboard shortcut modifier flags as CGEventFlags raw value (default: Option = 0x00080000)
    var hotkeyModifiers: UInt64

    init(
        anthropicAPIKey: String = "",
        openaiApiKey: String = "",
        aiProvider: String = "anthropic",
        hotkeyKeyCode: UInt16 = 49,
        hotkeyModifiers: UInt64 = 0x00080000
    ) {
        self.anthropicAPIKey = anthropicAPIKey
        self.openaiApiKey = openaiApiKey
        self.aiProvider = aiProvider
        self.hotkeyKeyCode = hotkeyKeyCode
        self.hotkeyModifiers = hotkeyModifiers
    }

    // Custom decoder so that old config files missing new fields don't wipe everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anthropicAPIKey = (try? c.decode(String.self, forKey: .anthropicAPIKey)) ?? ""
        openaiApiKey    = (try? c.decode(String.self, forKey: .openaiApiKey))    ?? ""
        aiProvider      = (try? c.decode(String.self, forKey: .aiProvider))      ?? "anthropic"
        hotkeyKeyCode   = (try? c.decode(UInt16.self, forKey: .hotkeyKeyCode))   ?? 49
        hotkeyModifiers = (try? c.decode(UInt64.self, forKey: .hotkeyModifiers)) ?? 0x00080000
    }
}
