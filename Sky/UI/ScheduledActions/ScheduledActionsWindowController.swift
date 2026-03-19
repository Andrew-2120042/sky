import AppKit

// MARK: - DatabaseManager extension

extension DatabaseManager {
    /// Returns all active scheduled actions regardless of their next run date.
    /// TODO: Replace with a direct SQLite query filtering `isActive == 1` once
    /// this file can safely import SQLite.swift expressions. For now we reuse
    /// `fetchDueActions(before:)` with the furthest possible date so that every
    /// active row is included.
    func fetchAllActive() throws -> [ScheduledAction] {
        try fetchDueActions(before: .distantFuture)
    }
}

// MARK: - Column identifiers

private extension NSUserInterfaceItemIdentifier {
    static let summary    = NSUserInterfaceItemIdentifier("summary")
    static let nextRun    = NSUserInterfaceItemIdentifier("nextRun")
    static let recurrence = NSUserInterfaceItemIdentifier("recurrence")
    static let delete     = NSUserInterfaceItemIdentifier("delete")
}

// MARK: - ScheduledActionsWindowController

/// Shows a list of all active scheduled actions with options to delete them.
@MainActor
final class ScheduledActionsWindowController: NSWindowController {

    // MARK: - Private state

    private var actions: [ScheduledAction] = []

    // MARK: - Views

    private let tableView: NSTableView = {
        let tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true
        tv.rowHeight = 22
        tv.allowsMultipleSelection = false
        tv.allowsEmptySelection = true
        tv.headerView = NSTableHeaderView()
        return tv
    }()

    private let scrollView: NSScrollView = {
        let sv = NSScrollView()
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        return sv
    }()

    // MARK: - Date formatter

    private static let nextRunFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE, MMM d 'at' h:mm a"
        return f
    }()

    // MARK: - Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scheduled Actions"
        window.minSize = NSSize(width: 560, height: 300)
        window.center()

        super.init(window: window)

        setupColumns()
        tableView.dataSource = self
        tableView.delegate   = self

        scrollView.documentView = tableView
        window.contentView = scrollView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported — use init()")
    }

    // MARK: - Window lifecycle

    override func windowDidLoad() {
        super.windowDidLoad()
        refresh()
    }

    // MARK: - Column setup

    private func setupColumns() {
        let specs: [(title: String, identifier: NSUserInterfaceItemIdentifier, width: CGFloat)] = [
            ("Summary",    .summary,    260),
            ("Next Run",   .nextRun,    140),
            ("Recurrence", .recurrence,  90),
            ("Delete",     .delete,      60),
        ]
        for spec in specs {
            let col = NSTableColumn(identifier: spec.identifier)
            col.title = spec.title
            col.width = spec.width
            col.minWidth = spec.width * 0.5
            col.maxWidth = spec.width * 3
            tableView.addTableColumn(col)
        }
    }

    // MARK: - Data

    /// Reloads the data source from the database and refreshes the table.
    func refresh() {
        actions = (try? DatabaseManager.shared.fetchAllActive()) ?? []
        tableView.reloadData()
    }

    // MARK: - Actions

    /// Soft-deletes the action with the given id, then reloads the table.
    private func deleteAction(id: String) {
        try? DatabaseManager.shared.markInactive(id: id)
        refresh()
    }
}

// MARK: - NSTableViewDataSource

extension ScheduledActionsWindowController: NSTableViewDataSource {

    func numberOfRows(in tableView: NSTableView) -> Int {
        actions.count
    }
}

// MARK: - NSTableViewDelegate

extension ScheduledActionsWindowController: NSTableViewDelegate {

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {

        guard row < actions.count, let tableColumn else { return nil }
        let action = actions[row]

        switch tableColumn.identifier {

        case .summary:
            return textCell(
                identifier: .summary,
                tableView: tableView,
                string: action.displaySummary
            )

        case .nextRun:
            return textCell(
                identifier: .nextRun,
                tableView: tableView,
                string: Self.nextRunFormatter.string(from: action.nextRunAt)
            )

        case .recurrence:
            let raw = action.recurrence.rawValue
            let capitalised = raw.prefix(1).uppercased() + raw.dropFirst()
            return textCell(
                identifier: .recurrence,
                tableView: tableView,
                string: capitalised
            )

        case .delete:
            let identifier = NSUserInterfaceItemIdentifier("deleteButton")
            let button: NSButton
            if let recycled = tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton {
                button = recycled
            } else {
                button = NSButton(title: "✕", target: nil, action: nil)
                button.bezelStyle = .rounded
                button.isBordered = false
                button.font = .systemFont(ofSize: 14)
                button.identifier = identifier
            }
            // Store the action id in the accessibility identifier for retrieval in the handler.
            // We use a tag-based approach: store the row index as the button tag and resolve
            // on tap, which is safe because we reload after every delete.
            button.tag = row
            button.target = self
            button.action = #selector(deleteButtonClicked(_:))
            return button

        default:
            return nil
        }
    }

    // MARK: - Private helpers

    private func textCell(
        identifier: NSUserInterfaceItemIdentifier,
        tableView: NSTableView,
        string: String
    ) -> NSTextField {
        let cellID = NSUserInterfaceItemIdentifier(identifier.rawValue + "Cell")
        if let recycled = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField {
            recycled.stringValue = string
            return recycled
        }
        let label = NSTextField(labelWithString: string)
        label.identifier = cellID
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13)
        return label
    }

    // MARK: - Button handler

    @objc private func deleteButtonClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row < actions.count else { return }
        deleteAction(id: actions[row].id)
    }
}
