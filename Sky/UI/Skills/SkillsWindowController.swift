import AppKit

/// A full macOS window showing all installed skills with edit, delete, and add controls.
@MainActor
final class SkillsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private var skills: [(name: String, displayName: String, triggers: String, mode: String, overview: String, filePath: String)] = []
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let addButton = NSButton(title: "Add Skill", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Skills"
        window.minSize = NSSize(width: 500, height: 300)
        window.center()
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Columns
        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.width = 160
        tableView.addTableColumn(nameCol)

        let triggersCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("triggers"))
        triggersCol.title = "Triggers"
        triggersCol.width = 120
        tableView.addTableColumn(triggersCol)

        let modeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mode"))
        modeCol.title = "Mode"
        modeCol.width = 80
        tableView.addTableColumn(modeCol)

        let overviewCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("overview"))
        overviewCol.title = "Overview"
        overviewCol.width = 260
        tableView.addTableColumn(overviewCol)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(editSelectedSkill)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addSkillTapped)

        editButton.bezelStyle = .rounded
        editButton.target = self
        editButton.action = #selector(editSelectedSkill)

        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedSkill)
        deleteButton.contentTintColor = .systemRed

        let toolbar = NSView()

        [scrollView, toolbar, addButton, editButton, deleteButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            addButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            addButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            deleteButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            deleteButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            editButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            editButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
        ])

        tableView.action = #selector(tableSelectionChanged)
        updateButtonState()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        refresh()
    }

    func refresh() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else { return }
        let skillsDir = appSupport.appendingPathComponent("Sky/skills")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: skillsDir, includingPropertiesForKeys: nil
        )) ?? []
        let skillFiles = files.filter {
            $0.pathExtension == "json" && !$0.lastPathComponent.hasPrefix("_")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }

        skills = skillFiles.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let name = json["name"] as? String ?? file.deletingPathExtension().lastPathComponent
            let displayName = name.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
            let triggers = (json["triggers"] as? [String])?.joined(separator: ", ") ?? ""
            let mode = json["mode"] as? String ?? "background"
            let overview = json["overview"] as? String ?? ""
            return (name: name, displayName: displayName, triggers: triggers,
                    mode: mode, overview: overview, filePath: file.path)
        }
        tableView.reloadData()
        updateButtonState()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { skills.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < skills.count else { return nil }
        let skill = skills[row]
        let id = tableColumn?.identifier.rawValue ?? ""
        let cellID = NSUserInterfaceItemIdentifier("cell-\(id)")

        let cell: NSTableCellView
        if let reuse = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = reuse
        } else {
            cell = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            cell.identifier = cellID
        }

        switch id {
        case "name":     cell.textField?.stringValue = skill.displayName
        case "triggers": cell.textField?.stringValue = skill.triggers
        case "mode":     cell.textField?.stringValue = skill.mode
        case "overview": cell.textField?.stringValue = skill.overview
        default: break
        }
        cell.textField?.textColor = .labelColor
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonState()
    }

    private func updateButtonState() {
        let hasSelection = tableView.selectedRow >= 0
        editButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }

    // MARK: - Actions

    @objc private func tableSelectionChanged() {
        updateButtonState()
    }

    @objc private func addSkillTapped() {
        NotificationCenter.default.post(name: Constants.NotificationName.showSkillCreation, object: nil)
        NotificationCenter.default.post(name: Constants.NotificationName.skyShowPanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func editSelectedSkill() {
        let row = tableView.selectedRow
        guard row >= 0, row < skills.count else { return }
        let skill = skills[row]
        NotificationCenter.default.post(
            name: Constants.NotificationName.editSkillInPanel,
            object: nil,
            userInfo: ["filePath": skill.filePath]
        )
        NotificationCenter.default.post(name: Constants.NotificationName.skyShowPanel, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func deleteSelectedSkill() {
        let row = tableView.selectedRow
        guard row >= 0, row < skills.count else { return }
        let skill = skills[row]

        let alert = NSAlert()
        alert.messageText = "Delete '\(skill.displayName)'?"
        alert.informativeText = "This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        try? FileManager.default.removeItem(atPath: skill.filePath)
        SkillsService.shared.reload()
        NotificationCenter.default.post(name: Constants.NotificationName.rebuildSkillsMenu, object: nil)
        print("🎯 [Skills] Deleted from window: \(skill.name)")
        refresh()
    }
}
