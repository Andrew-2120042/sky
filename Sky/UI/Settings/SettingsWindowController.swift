import AppKit

/// A non-modal settings window for configuring the AI provider and API keys.
@MainActor
final class SettingsWindowController: NSWindowController {

    // MARK: - Views

    private let providerLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "AI Provider")
        tf.font = .systemFont(ofSize: 13, weight: .medium)
        tf.textColor = .secondaryLabelColor
        return tf
    }()

    private let providerControl: NSSegmentedControl = {
        let s = NSSegmentedControl(labels: ["Anthropic", "OpenAI"],
                                   trackingMode: .selectOne,
                                   target: nil,
                                   action: nil)
        s.selectedSegment = 0
        return s
    }()

    private let anthropicLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "Anthropic API Key")
        tf.font = .systemFont(ofSize: 13, weight: .medium)
        tf.textColor = .secondaryLabelColor
        return tf
    }()

    private let anthropicKeyField: NSSecureTextField = {
        let f = NSSecureTextField()
        f.placeholderString = "sk-ant-..."
        f.font = .systemFont(ofSize: 13)
        return f
    }()

    private let openaiLabel: NSTextField = {
        let tf = NSTextField(labelWithString: "OpenAI API Key")
        tf.font = .systemFont(ofSize: 13, weight: .medium)
        tf.textColor = .secondaryLabelColor
        return tf
    }()

    private let openaiKeyField: NSSecureTextField = {
        let f = NSSecureTextField()
        f.placeholderString = "sk-..."
        f.font = .systemFont(ofSize: 13)
        return f
    }()

    private let saveButton: NSButton = {
        let b = NSButton(title: "Save", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.keyEquivalent = "\r"
        return b
    }()

    private let cancelButton: NSButton = {
        let b = NSButton(title: "Cancel", target: nil, action: nil)
        b.bezelStyle = .rounded
        b.keyEquivalent = "\u{1B}"
        return b
    }()

    // MARK: - Init

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Sky Settings"
        panel.center()
        super.init(window: panel)
        buildUI()
        loadCurrentConfig()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    // MARK: - UI

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        [providerLabel, providerControl,
         anthropicLabel, anthropicKeyField,
         openaiLabel, openaiKeyField,
         saveButton, cancelButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            providerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            providerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),

            providerControl.leadingAnchor.constraint(equalTo: providerLabel.leadingAnchor),
            providerControl.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 6),
            providerControl.widthAnchor.constraint(equalToConstant: 200),

            anthropicLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            anthropicLabel.topAnchor.constraint(equalTo: providerControl.bottomAnchor, constant: 20),

            anthropicKeyField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            anthropicKeyField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            anthropicKeyField.topAnchor.constraint(equalTo: anthropicLabel.bottomAnchor, constant: 6),
            anthropicKeyField.heightAnchor.constraint(equalToConstant: 26),

            openaiLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            openaiLabel.topAnchor.constraint(equalTo: anthropicKeyField.bottomAnchor, constant: 16),

            openaiKeyField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            openaiKeyField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            openaiKeyField.topAnchor.constraint(equalTo: openaiLabel.bottomAnchor, constant: 6),
            openaiKeyField.heightAnchor.constraint(equalToConstant: 26),

            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            saveButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            saveButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
        ])

        saveButton.target = self
        saveButton.action = #selector(saveTapped)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        providerControl.target = self
        providerControl.action = #selector(providerChanged)
    }

    private func loadCurrentConfig() {
        let cfg = ConfigService.shared.config
        anthropicKeyField.stringValue = cfg.anthropicAPIKey
        openaiKeyField.stringValue = cfg.openaiApiKey
        providerControl.selectedSegment = cfg.aiProvider == "openai" ? 1 : 0
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        let provider = providerControl.selectedSegment == 1 ? "openai" : "anthropic"
        ConfigService.shared.saveKeys(
            anthropicKey: anthropicKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            openaiKey: openaiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            provider: provider
        )
        LoggingService.shared.log("Settings saved — provider: \(provider)")
        close()
    }

    @objc private func cancelTapped() {
        close()
    }

    @objc private func providerChanged() {
        // No UI changes needed — both fields are always editable in Settings
    }
}
