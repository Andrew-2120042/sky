import AppKit

/// A simple window showing the last 20 actions logged by ActionLogService.
final class RecentActionsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    private var entries: [ActionLogService.LogEntry] = []
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Recent Actions"
        window.center()
        self.init(window: window)
        setupTableView()
    }

    private func setupTableView() {
        // Time column
        let timeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("time"))
        timeCol.title = "Time"
        timeCol.width = 80
        tableView.addTableColumn(timeCol)

        // Status column
        let statusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusCol.title = "Status"
        statusCol.width = 60
        tableView.addTableColumn(statusCol)

        // Action column
        let actionCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionCol.title = "Action"
        actionCol.width = 380
        tableView.addTableColumn(actionCol)

        tableView.dataSource = self
        tableView.delegate   = self
        tableView.rowHeight  = 22
        tableView.usesAlternatingRowBackgroundColors = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]

        guard let contentView = window?.contentView else { return }
        scrollView.frame = contentView.bounds
        contentView.addSubview(scrollView)
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        refresh()
    }

    func refresh() {
        entries = ActionLogService.shared.recentActions
        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")

        let cellID = NSUserInterfaceItemIdentifier("cell-\(identifier.rawValue)")
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
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.identifier = cellID
        }

        switch identifier.rawValue {
        case "time":
            let fmt = DateFormatter()
            fmt.dateStyle = .none
            fmt.timeStyle = .short
            cell.textField?.stringValue = fmt.string(from: entry.executedAt)
        case "status":
            cell.textField?.stringValue = entry.succeeded ? "✓" : "✗"
            cell.textField?.textColor   = entry.succeeded ? .systemGreen : .systemRed
        case "action":
            cell.textField?.stringValue = entry.summary
            cell.textField?.textColor   = .labelColor
        default:
            break
        }
        return cell
    }
}
