import AppKit

/// Left side panel — Sky's command center.
/// Slides in from the left when the Sky logo button is clicked.
final class SkyLeftPanelViewController: NSViewController {

    var onCommandSelected: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private var scrollView: NSScrollView!
    private var stackView: NSStackView!
    private var buttonCommands: [Int: String] = [:]
    private var nextButtonTag = 0

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 500))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        populateContent()
    }

    // MARK: - Setup

    private func setupUI() {
        let vibrancy = NSVisualEffectView()
        vibrancy.material = .hudWindow
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.wantsLayer = true
        vibrancy.layer?.cornerRadius = 14
        vibrancy.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vibrancy)

        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        view.addSubview(scrollView)

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView

        NSLayoutConstraint.activate([
            vibrancy.topAnchor.constraint(equalTo: view.topAnchor),
            vibrancy.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vibrancy.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vibrancy.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),

            // Only constrain width — the scroll view manages the document view's origin.
            // No top/leading/trailing to clipView: those anchors move during scrolling
            // and would physically reposition the stackView, causing the content to appear
            // only after a scroll interaction.
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    // MARK: - Content

    func refresh() {
        populateContent()
        layoutAndResize()
    }

    func layoutAndResize() {
        view.layoutSubtreeIfNeeded()
        stackView.layoutSubtreeIfNeeded()

        let contentHeight = stackView.fittingSize.height
        let maxHeight: CGFloat = 520
        let minHeight: CGFloat = 200
        let targetHeight = max(minHeight, min(maxHeight, contentHeight + 16))

        guard let window = view.window else { return }
        var frame = window.frame
        let oldHeight = frame.height
        frame.size.height = targetHeight
        frame.origin.y -= (targetHeight - oldHeight)
        window.setFrame(frame, display: false, animate: false)

        // NSScrollView is non-flipped: y=0 is at the bottom of the document.
        // Scroll to the top of the content (highest y value = first row).
        view.layoutSubtreeIfNeeded()
        let docH = scrollView.documentView?.frame.height ?? 0
        let clipH = scrollView.contentView.bounds.height
        let topY = max(0, docH - clipH)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: topY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func populateContent() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
        buttonCommands.removeAll()
        nextButtonTag = 0

        addHeader()
        addSeparator()

        addSectionTitle("Quick Actions")
        addCommandPill(icon: "sun.max",                       label: "Morning briefing",   command: "morning briefing")
        addCommandPill(icon: "video",                          label: "Join meeting",        command: "join my next meeting")
        addCommandPill(icon: "camera.viewfinder",              label: "Search screenshots", command: "__screenshots__")
        addCommandPill(icon: "bubble.left.and.bubble.right",   label: "Open chat",          command: "__chat__")
        addSeparator()

        addSectionTitle("Skills")
        addSkillRows()
        addSeparator()

        addSectionTitle("Recent")
        addRecentRows()
        addSeparator()

        addSectionTitle("Scheduled")
        addScheduledRows()
        addSeparator()

        addSectionTitle("Memory")
        addMemoryRows()
        addSeparator()

        addSectionTitle("Settings")
        addCommandPill(icon: "key",      label: "API Key",              command: "__settings__")
        addCommandPill(icon: "keyboard", label: "Hotkey: Option+Space", command: "")

        addFooter()
    }

    // MARK: - Header

    private func addHeader() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let logoImage = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Sky")
        let logoView = NSImageView(image: logoImage ?? NSImage())
        logoView.imageScaling = .scaleProportionallyDown
        logoView.contentTintColor = .systemBlue
        logoView.translatesAutoresizingMaskIntoConstraints = false

        let nameLabel = NSTextField(labelWithString: "Sky")
        nameLabel.font = .systemFont(ofSize: 16, weight: .bold)
        nameLabel.textColor = .labelColor
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let versionLabel = NSTextField(labelWithString: "v\(version)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(logoView)
        container.addSubview(nameLabel)
        container.addSubview(versionLabel)

        stackView.addArrangedSubview(container)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 64),
            container.widthAnchor.constraint(equalTo: stackView.widthAnchor),

            logoView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            logoView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            logoView.widthAnchor.constraint(equalToConstant: 28),
            logoView.heightAnchor.constraint(equalToConstant: 28),

            nameLabel.leadingAnchor.constraint(equalTo: logoView.trailingAnchor, constant: 10),
            nameLabel.topAnchor.constraint(equalTo: logoView.topAnchor),

            versionLabel.leadingAnchor.constraint(equalTo: logoView.trailingAnchor, constant: 10),
            versionLabel.bottomAnchor.constraint(equalTo: logoView.bottomAnchor),
        ])
    }

    // MARK: - Skills

    private func addSkillRows() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { addEmptyRow("No skills installed"); return }

        let dir = appSupport.appendingPathComponent("Sky/skills")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        )) ?? []

        let skills = files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_") }
            .compactMap { file -> (name: String, trigger: String)? in
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                let name = json["name"] as? String
                    ?? file.deletingPathExtension().lastPathComponent
                let trigger = (json["triggers"] as? [String])?.first ?? ""
                return (name, trigger)
            }
            .prefix(6)

        if skills.isEmpty {
            addEmptyRow("No skills installed")
        } else {
            for skill in skills {
                addCommandPill(
                    icon: "sparkles",
                    label: skill.name
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized,
                    command: skill.trigger.isEmpty ? "" : "use \(skill.trigger)"
                )
            }
        }
    }

    // MARK: - Recent Activity

    private func addRecentRows() {
        let recent = DatabaseManager.shared.fetchRecentActionMemory(limit: 4)
        if recent.isEmpty {
            addEmptyRow("Nothing yet")
            return
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .abbreviated

        for item in recent {
            let dateStr: String
            if let date = iso.date(from: item.createdAt) {
                dateStr = relative.localizedString(for: date, relativeTo: Date())
            } else {
                dateStr = ""
            }
            addInfoRow(
                icon: iconForActionType(item.actionType),
                primary: item.summary,
                secondary: dateStr,
                command: "tell me about: \(item.summary)"
            )
        }
    }

    // MARK: - Scheduled

    private func addScheduledRows() {
        let all = (try? DatabaseManager.shared.fetchDueActions(before: .distantFuture)) ?? []
        let upcoming = all.filter { $0.isActive && $0.nextRunAt > Date() }.prefix(3)

        if upcoming.isEmpty {
            addEmptyRow("Nothing scheduled")
            return
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        for action in upcoming {
            addInfoRow(
                icon: "clock",
                primary: action.displaySummary,
                secondary: fmt.string(from: action.nextRunAt),
                command: ""
            )
        }
    }

    // MARK: - Memory

    private func addMemoryRows() {
        let mem = MemoryService.shared.readMemory()
        var items: [(String, String)] = []
        items.append(contentsOf: mem.aliases.prefix(2).map { ("→", "\($0.key) = \($0.value)") })
        items.append(contentsOf: mem.facts.prefix(2).map { ("·", $0) })

        if items.isEmpty {
            addEmptyRow("Nothing remembered yet")
            addCommandPill(icon: "brain", label: "Remember something", command: "remember that ")
        } else {
            for item in items {
                addInfoRow(icon: "brain", primary: item.1, secondary: "", command: "")
            }
            addCommandPill(icon: "plus", label: "Add memory", command: "remember that ")
        }
    }

    // MARK: - Footer

    private func addFooter() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let feedbackButton = NSButton(title: "Send Feedback", target: self, action: #selector(sendFeedback))
        feedbackButton.bezelStyle = .inline
        feedbackButton.isBordered = false
        feedbackButton.contentTintColor = .tertiaryLabelColor
        feedbackButton.font = .systemFont(ofSize: 11)
        feedbackButton.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(feedbackButton)
        stackView.addArrangedSubview(container)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 44),
            container.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            feedbackButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            feedbackButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
    }

    @objc private func sendFeedback() {
        if let url = URL(string: "mailto:feedback@skyapp.in") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Row builders

    private func addSectionTitle(_ title: String) {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        stackView.addArrangedSubview(wrapper)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            wrapper.heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
    }

    private func addSeparator() {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        stackView.addArrangedSubview(line)
        NSLayoutConstraint.activate([
            line.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
    }

    private func addEmptyRow(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .quaternaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(label)
        stackView.addArrangedSubview(wrapper)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            wrapper.heightAnchor.constraint(equalToConstant: 32),
            label.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
    }

    private func addCommandPill(icon: String, label labelText: String, command: String) {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 8

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: labelText)
        labelField.font = .systemFont(ofSize: 13)
        labelField.textColor = .labelColor
        labelField.lineBreakMode = .byTruncatingTail
        labelField.translatesAutoresizingMaskIntoConstraints = false

        wrapper.addSubview(iconView)
        wrapper.addSubview(labelField)

        if !command.isEmpty {
            let btn = NSButton()
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.isBordered = false
            btn.title = ""
            btn.tag = nextButtonTag
            buttonCommands[nextButtonTag] = command
            nextButtonTag += 1
            btn.target = self
            btn.action = #selector(commandPillTapped(_:))
            wrapper.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: wrapper.topAnchor),
                btn.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                btn.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                btn.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            ])
        }

        stackView.addArrangedSubview(wrapper)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            wrapper.heightAnchor.constraint(equalToConstant: 36),
            iconView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            labelField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            labelField.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            labelField.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
        ])
    }

    private func addInfoRow(icon: String, primary: String, secondary: String, command: String) {
        let wrapper = NSView()
        wrapper.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let primaryLabel = NSTextField(labelWithString: primary)
        primaryLabel.font = .systemFont(ofSize: 12)
        primaryLabel.textColor = .labelColor
        primaryLabel.lineBreakMode = .byTruncatingTail
        primaryLabel.translatesAutoresizingMaskIntoConstraints = false

        let secondaryLabel = NSTextField(labelWithString: secondary)
        secondaryLabel.font = .systemFont(ofSize: 10)
        secondaryLabel.textColor = .tertiaryLabelColor
        secondaryLabel.translatesAutoresizingMaskIntoConstraints = false

        wrapper.addSubview(iconView)
        wrapper.addSubview(primaryLabel)
        wrapper.addSubview(secondaryLabel)

        if !command.isEmpty {
            let btn = NSButton()
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.isBordered = false
            btn.title = ""
            btn.tag = nextButtonTag
            buttonCommands[nextButtonTag] = command
            nextButtonTag += 1
            btn.target = self
            btn.action = #selector(commandPillTapped(_:))
            wrapper.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.topAnchor.constraint(equalTo: wrapper.topAnchor),
                btn.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                btn.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                btn.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            ])
        }

        let rowHeight: CGFloat = secondary.isEmpty ? 32 : 44
        stackView.addArrangedSubview(wrapper)
        NSLayoutConstraint.activate([
            wrapper.widthAnchor.constraint(equalTo: stackView.widthAnchor),
            wrapper.heightAnchor.constraint(equalToConstant: rowHeight),
            iconView.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            iconView.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            primaryLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            primaryLabel.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 6),
            primaryLabel.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -12),
            secondaryLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            secondaryLabel.topAnchor.constraint(equalTo: primaryLabel.bottomAnchor, constant: 2),
        ])
    }

    // MARK: - Actions

    @objc private func commandPillTapped(_ sender: NSButton) {
        let command = buttonCommands[sender.tag] ?? ""
        guard !command.isEmpty else { return }
        onCommandSelected?(command)
    }

    // MARK: - Helpers

    private func iconForActionType(_ type: String) -> String {
        switch type {
        case "send_mail":                               return "envelope"
        case "send_message":                            return "message"
        case "set_reminder":                            return "bell"
        case "create_event":                            return "calendar"
        case "join_meeting":                            return "video"
        case "execute_flow":                            return "arrow.triangle.2.circlepath"
        case "open_app":                                return "app"
        case "media_play_pause", "media_next_track":   return "music.note"
        case "save_memory":                             return "brain"
        default:                                        return "bolt"
        }
    }
}

