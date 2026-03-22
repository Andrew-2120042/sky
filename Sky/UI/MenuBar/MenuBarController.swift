import AppKit

/// Manages the NSStatusItem menu bar icon and its menu.
/// Tapping the icon directly toggles the panel; the menu provides secondary actions.
@MainActor
final class MenuBarController {

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?

    /// Called when the user wants to toggle the panel (via icon click or "Open" menu item).
    var onTogglePanel: (() -> Void)?

    /// Sets up the status item and its menu.
    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        // Rebuild the menu whenever a skill is added or deleted (e.g. from ActionRouter)
        NotificationCenter.default.addObserver(
            forName: Constants.NotificationName.rebuildSkillsMenu,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.buildMenu() }
        }

        if let button = item.button {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            button.image = NSImage(systemSymbolName: Constants.MenuBar.symbolName,
                                   accessibilityDescription: "Sky")?
                .withSymbolConfiguration(config)
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        buildMenu()
    }

    // MARK: - Menu Construction

    /// Constructs the dropdown menu attached to the status item.
    /// Internal so ActionRouter can call it after deleting a skill.
    func buildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: Constants.MenuBar.openTitle,
                  action: #selector(openTapped),
                  keyEquivalent: "").target = self
        m.addItem(withTitle: Constants.MenuBar.scheduledActionsTitle,
                  action: #selector(scheduledActionsTapped),
                  keyEquivalent: "").target = self
        m.addItem(withTitle: Constants.MenuBar.recentActionsTitle,
                  action: #selector(recentActionsTapped),
                  keyEquivalent: "").target = self
        m.addItem(withTitle: Constants.MenuBar.workflowsTitle,
                  action: #selector(workflowsTapped),
                  keyEquivalent: "").target = self
        m.addItem(withTitle: Constants.MenuBar.memoryTitle,
                  action: #selector(memoryTapped),
                  keyEquivalent: "").target = self
        m.addItem(withTitle: "Skills…",
                  action: #selector(skillsTapped),
                  keyEquivalent: "").target = self
        m.addItem(withTitle: Constants.MenuBar.settingsTitle,
                  action: #selector(settingsTapped),
                  keyEquivalent: ",").target = self

        m.addItem(.separator())
        m.addItem(withTitle: Constants.MenuBar.quitTitle,
                  action: #selector(NSApplication.terminate(_:)),
                  keyEquivalent: "q")
        menu = m
    }

    // MARK: - Skill Actions

    @objc private func skillsTapped() {
        if skillsController == nil {
            skillsController = SkillsWindowController()
        }
        skillsController?.refresh()
        skillsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Status Item

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            onTogglePanel?()
        }
    }

    @objc private func openTapped() { onTogglePanel?() }

    @objc private func scheduledActionsTapped() {
        if scheduledActionsController == nil {
            scheduledActionsController = ScheduledActionsWindowController()
        }
        scheduledActionsController?.refresh()
        scheduledActionsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func recentActionsTapped() {
        if recentActionsController == nil {
            recentActionsController = RecentActionsWindowController()
        }
        recentActionsController?.refresh()
        recentActionsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func workflowsTapped() {
        if workflowsController == nil {
            workflowsController = WorkflowsWindowController()
        }
        workflowsController?.refresh()
        workflowsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func memoryTapped() {
        if memoryController == nil {
            memoryController = MemoryWindowController()
        }
        memoryController?.refresh()
        memoryController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func settingsTapped() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
        }
        settingsController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Child Controllers

    private var scheduledActionsController: ScheduledActionsWindowController?
    private var recentActionsController: RecentActionsWindowController?
    private var workflowsController: WorkflowsWindowController?
    private var memoryController: MemoryWindowController?
    private var settingsController: SettingsWindowController?
    private var skillsController: SkillsWindowController?
}
