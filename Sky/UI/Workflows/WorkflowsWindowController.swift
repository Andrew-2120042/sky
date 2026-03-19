import AppKit

/// Shows all saved workflows with trigger phrase, step count, created date, and delete button.
@MainActor
final class WorkflowsWindowController: NSWindowController {

    private var workflows: [WorkflowService.Workflow] = []
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Workflows"
        window.minSize = NSSize(width: 400, height: 250)
        window.center()
        self.init(window: window)
        setupUI()
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Info label
        let info = NSTextField(labelWithString:
            "To create a workflow, type \"when I say [trigger] do [steps]\" in Sky.")
        info.font = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        info.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(info)

        // Table columns
        let cols: [(String, String, CGFloat)] = [
            ("Trigger",  "trigger", 200),
            ("Steps",    "steps",    60),
            ("Created",  "created", 160),
            ("",         "delete",   60)
        ]
        for (title, id, width) in cols {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            tableView.addTableColumn(col)
        }
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.rowHeight  = 22
        tableView.usesAlternatingRowBackgroundColors = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            info.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            info.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            info.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: info.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        refresh()
    }

    func refresh() {
        workflows = WorkflowService.shared.workflows
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDataSource

extension WorkflowsWindowController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { workflows.count }
}

// MARK: - NSTableViewDelegate

extension WorkflowsWindowController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < workflows.count else { return nil }
        let wf = workflows[row]
        let id = tableColumn?.identifier.rawValue ?? ""

        switch id {
        case "trigger":
            return label(wf.trigger, id: "trigger", tableView: tableView)
        case "steps":
            return label("\(wf.steps.count)", id: "steps", tableView: tableView)
        case "created":
            let fmt = DateFormatter(); fmt.dateStyle = .medium; fmt.timeStyle = .none
            return label(fmt.string(from: wf.createdAt), id: "created", tableView: tableView)
        case "delete":
            let btnID = NSUserInterfaceItemIdentifier("deleteBtn")
            let btn: NSButton
            if let reuse = tableView.makeView(withIdentifier: btnID, owner: nil) as? NSButton {
                btn = reuse
            } else {
                btn = NSButton(title: "✕", target: nil, action: nil)
                btn.bezelStyle = .rounded
                btn.isBordered = false
                btn.font = .systemFont(ofSize: 14)
                btn.identifier = btnID
            }
            btn.tag = row
            btn.target = self
            btn.action = #selector(deleteTapped(_:))
            return btn
        default:
            return nil
        }
    }

    @objc private func deleteTapped(_ sender: NSButton) {
        guard sender.tag < workflows.count else { return }
        WorkflowService.shared.delete(id: workflows[sender.tag].id)
        refresh()
    }

    private func label(_ string: String, id: String, tableView: NSTableView) -> NSTextField {
        let cellID = NSUserInterfaceItemIdentifier(id + "Cell")
        if let reuse = tableView.makeView(withIdentifier: cellID, owner: nil) as? NSTextField {
            reuse.stringValue = string; return reuse
        }
        let tf = NSTextField(labelWithString: string)
        tf.identifier = cellID
        tf.font = .systemFont(ofSize: 13)
        tf.lineBreakMode = .byTruncatingTail
        return tf
    }
}
