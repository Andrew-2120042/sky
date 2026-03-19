import AppKit

/// Shows the user's saved memory (aliases, facts, preferences) with add / remove controls.
@MainActor
final class MemoryWindowController: NSWindowController {

    private let tabView = NSTabView()

    // Aliases tab
    private let aliasesTable = NSTableView()
    private let aliasesScrollView = NSScrollView()
    private var aliases: [(key: String, value: String)] = []
    private let aliasKeyField   = NSTextField()
    private let aliasValueField = NSTextField()

    // Facts tab
    private let factsTable = NSTableView()
    private let factsScrollView = NSScrollView()
    private var facts: [String] = []
    private let factField = NSTextField()

    // Preferences tab
    private let prefsTable = NSTableView()
    private let prefsScrollView = NSScrollView()
    private var prefs: [String] = []
    private let prefField = NSTextField()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sky Memory"
        window.minSize = NSSize(width: 420, height: 300)
        window.center()
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            tabView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            tabView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        tabView.addTabViewItem(makeAliasesTab())
        tabView.addTabViewItem(makeFactsTab())
        tabView.addTabViewItem(makePrefsTab())
    }

    // MARK: - Aliases Tab

    private func makeAliasesTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "Aliases"
        let view = NSView()

        configureTable(aliasesTable,
                       columns: [("Alias", "alias", 140), ("Real Name / Email", "value", 270), ("", "delete", 50)],
                       scrollView: aliasesScrollView, tag: 0)

        configureField(aliasKeyField, placeholder: "alias (e.g. mum)")
        configureField(aliasValueField, placeholder: "real name or email")
        let addBtn = makeAddButton(action: #selector(addAlias))

        aliasesScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(aliasesScrollView)
        view.addSubview(aliasKeyField)
        view.addSubview(aliasValueField)
        view.addSubview(addBtn)
        NSLayoutConstraint.activate([
            aliasesScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            aliasesScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            aliasesScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            aliasesScrollView.bottomAnchor.constraint(equalTo: aliasKeyField.topAnchor, constant: -8),

            aliasKeyField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            aliasKeyField.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.35),
            aliasKeyField.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            aliasKeyField.heightAnchor.constraint(equalToConstant: 24),

            aliasValueField.leadingAnchor.constraint(equalTo: aliasKeyField.trailingAnchor, constant: 8),
            aliasValueField.trailingAnchor.constraint(equalTo: addBtn.leadingAnchor, constant: -8),
            aliasValueField.centerYAnchor.constraint(equalTo: aliasKeyField.centerYAnchor),
            aliasValueField.heightAnchor.constraint(equalToConstant: 24),

            addBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addBtn.centerYAnchor.constraint(equalTo: aliasKeyField.centerYAnchor),
        ])
        item.view = view
        return item
    }

    // MARK: - Facts Tab

    private func makeFactsTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "Facts"
        let view = NSView()

        configureTable(factsTable,
                       columns: [("Fact", "fact", 390), ("", "delete", 50)],
                       scrollView: factsScrollView, tag: 1)

        configureField(factField, placeholder: "e.g. I live in London")
        let addBtn = makeAddButton(action: #selector(addFact))

        factsScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(factsScrollView)
        view.addSubview(factField)
        view.addSubview(addBtn)
        NSLayoutConstraint.activate([
            factsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            factsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            factsScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            factsScrollView.bottomAnchor.constraint(equalTo: factField.topAnchor, constant: -8),

            factField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            factField.trailingAnchor.constraint(equalTo: addBtn.leadingAnchor, constant: -8),
            factField.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            factField.heightAnchor.constraint(equalToConstant: 24),

            addBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addBtn.centerYAnchor.constraint(equalTo: factField.centerYAnchor),
        ])
        item.view = view
        return item
    }

    // MARK: - Preferences Tab

    private func makePrefsTab() -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = "Preferences"
        let view = NSView()

        configureTable(prefsTable,
                       columns: [("Preference", "pref", 390), ("", "delete", 50)],
                       scrollView: prefsScrollView, tag: 2)

        configureField(prefField, placeholder: "e.g. Prefer short replies")
        let addBtn = makeAddButton(action: #selector(addPref))

        prefsScrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(prefsScrollView)
        view.addSubview(prefField)
        view.addSubview(addBtn)
        NSLayoutConstraint.activate([
            prefsScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            prefsScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            prefsScrollView.topAnchor.constraint(equalTo: view.topAnchor),
            prefsScrollView.bottomAnchor.constraint(equalTo: prefField.topAnchor, constant: -8),

            prefField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            prefField.trailingAnchor.constraint(equalTo: addBtn.leadingAnchor, constant: -8),
            prefField.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            prefField.heightAnchor.constraint(equalToConstant: 24),

            addBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            addBtn.centerYAnchor.constraint(equalTo: prefField.centerYAnchor),
        ])
        item.view = view
        return item
    }

    // MARK: - Helpers

    private func configureTable(_ table: NSTableView,
                                 columns: [(String, String, CGFloat)],
                                 scrollView: NSScrollView,
                                 tag: Int) {
        for (title, id, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            table.addTableColumn(col)
        }
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.tag = tag
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
    }

    private func configureField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 13)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeAddButton(action: Selector) -> NSButton {
        let btn = NSButton(title: "Add", target: self, action: action)
        btn.bezelStyle = .rounded
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    func refresh() {
        let mem = MemoryService.shared.readMemory()
        aliases = mem.aliases.map { (key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
        facts = mem.facts
        prefs = mem.preferences
        aliasesTable.reloadData()
        factsTable.reloadData()
        prefsTable.reloadData()
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        refresh()
    }

    // MARK: - Add Actions

    @objc private func addAlias() {
        let key = aliasKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let val = aliasValueField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !val.isEmpty else { return }
        MemoryService.shared.setAlias(key, to: val)
        aliasKeyField.stringValue = ""
        aliasValueField.stringValue = ""
        refresh()
    }

    @objc private func addFact() {
        let fact = factField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty else { return }
        MemoryService.shared.addFact(fact)
        factField.stringValue = ""
        refresh()
    }

    @objc private func addPref() {
        let pref = prefField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pref.isEmpty else { return }
        MemoryService.shared.addPreference(pref)
        prefField.stringValue = ""
        refresh()
    }

    // MARK: - Delete Actions

    @objc private func deleteAlias(_ sender: NSButton) {
        guard sender.tag < aliases.count else { return }
        MemoryService.shared.removeAlias(aliases[sender.tag].key)
        refresh()
    }

    @objc private func deleteFact(_ sender: NSButton) {
        guard sender.tag < facts.count else { return }
        MemoryService.shared.removeFact(at: sender.tag)
        refresh()
    }

    @objc private func deletePref(_ sender: NSButton) {
        guard sender.tag < prefs.count else { return }
        MemoryService.shared.removePreference(at: sender.tag)
        refresh()
    }
}

// MARK: - NSTableViewDataSource

extension MemoryWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        switch tableView.tag {
        case 0: return aliases.count
        case 1: return facts.count
        case 2: return prefs.count
        default: return 0
        }
    }
}

// MARK: - NSTableViewDelegate

extension MemoryWindowController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        switch tableView.tag {
        case 0: return aliasCell(id: id, row: row, tableView: tableView)
        case 1: return listCell(id: id, textID: "factCell",  row: row, items: facts, tableView: tableView, deleteAction: #selector(deleteFact(_:)))
        case 2: return listCell(id: id, textID: "prefCell",  row: row, items: prefs, tableView: tableView, deleteAction: #selector(deletePref(_:)))
        default: return nil
        }
    }

    private func aliasCell(id: String, row: Int, tableView: NSTableView) -> NSView? {
        guard row < aliases.count else { return nil }
        switch id {
        case "alias":  return textCell(aliases[row].key,   cellID: "aliasCellKey",  tableView: tableView)
        case "value":  return textCell(aliases[row].value, cellID: "aliasCellVal",  tableView: tableView)
        case "delete": return deleteButton(tag: row, tableView: tableView, action: #selector(deleteAlias(_:)))
        default: return nil
        }
    }

    private func listCell(id: String, textID: String, row: Int, items: [String],
                          tableView: NSTableView, deleteAction: Selector) -> NSView? {
        guard row < items.count else { return nil }
        if id == "delete" { return deleteButton(tag: row, tableView: tableView, action: deleteAction) }
        return textCell(items[row], cellID: textID, tableView: tableView)
    }

    private func textCell(_ string: String, cellID: String, tableView: NSTableView) -> NSTextField {
        let ident = NSUserInterfaceItemIdentifier(cellID)
        if let reuse = tableView.makeView(withIdentifier: ident, owner: nil) as? NSTextField {
            reuse.stringValue = string; return reuse
        }
        let tf = NSTextField(labelWithString: string)
        tf.identifier = ident
        tf.font = .systemFont(ofSize: 13)
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }

    private func deleteButton(tag: Int, tableView: NSTableView, action: Selector) -> NSButton {
        let ident = NSUserInterfaceItemIdentifier("deleteBtn\(tableView.tag)")
        let btn: NSButton
        if let reuse = tableView.makeView(withIdentifier: ident, owner: nil) as? NSButton {
            btn = reuse
        } else {
            btn = NSButton(title: "✕", target: nil, action: nil)
            btn.bezelStyle = .rounded
            btn.isBordered = false
            btn.font = .systemFont(ofSize: 14)
            btn.identifier = ident
        }
        btn.tag = tag
        btn.target = self
        btn.action = action
        return btn
    }
}
