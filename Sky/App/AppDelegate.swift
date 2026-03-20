import AppKit
import ServiceManagement
import Combine
import UserNotifications

/// Application entry point. Owns all top-level services and coordinates the panel lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Services

    private let menuBarController = MenuBarController()
    private let hotkeyManager: HotkeyManager
    private let panelVC = PanelViewController()
    private var panel: FloatingPanel?
    private var outsideClickMonitor: Any?

    // MARK: - Init

    override init() {
        let config = ConfigService.shared.config
        hotkeyManager = HotkeyManager(
            keyCode: config.hotkeyKeyCode,
            modifiers: config.hotkeyModifiers
        )
        super.init()
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent the app from appearing in the Dock or app switcher (belt-and-suspenders with LSUIElement)
        NSApp.setActivationPolicy(.accessory)

        // Set up persistent services
        ConfigService.shared.load()
        SchedulerService.shared.start()
        SkillsService.shared.seedDefaultSkillsIfNeeded()

        // Set up notifications
        NotificationService.registerCategories()
        UNUserNotificationCenter.current().delegate = self

        // Pre-warm Phase 1 services — delay contacts load to avoid noisy system log spam at launch.
        Task {
            _ = PermissionsManager.shared          // initialise event store on main actor
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if await PermissionsManager.shared.requestContacts() {
                ContactsService.shared.load()
            }
            // Request notification permission after contacts are loaded
            _ = await PermissionsManager.shared.requestNotifications()
            // Trigger screen recording permission prompt (user may need to grant + restart)
            PermissionsManager.shared.requestScreenRecording()
        }

        // Re-show the panel when ActionRouter signals that a computer-use action completed
        NotificationCenter.default.addObserver(
            forName: Constants.NotificationName.skyShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showPanel() }
        }

        // Properly hide the panel (with monitor cleanup) when posted from ActionRouter or VC
        NotificationCenter.default.addObserver(
            forName: Constants.NotificationName.hidePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }

        // Set up the menu bar icon
        menuBarController.onTogglePanel = { [weak self] in self?.togglePanel() }
        menuBarController.setup()

        // Set up the global hotkey
        hotkeyManager.onHotkey = { [weak self] in self?.togglePanel() }
        hotkeyManager.register()

        // Set up launch-at-login
        configureLaunchAtLogin()

        // Check Node.js availability for headless browser
        Task {
            let nodePath = await MainActor.run { HeadlessBrowserService.shared.nodePath }
            let nodeExists = FileManager.default.fileExists(atPath: nodePath)
            print("🌐 [Browser] Node.js at \(nodePath): \(nodeExists ? "found ✓" : "not found ✗")")
            if !nodeExists {
                print("🌐 [Browser] Install Node.js from https://nodejs.org to enable headless browser features")
            }
        }

        print("[AppDelegate] Sky launched and ready")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager.unregister()
        SchedulerService.shared.stop()
    }

    // MARK: - Panel Management

    /// Toggles the floating panel: shows it if hidden, hides it if visible.
    /// The show path awaits ContextService.refresh() so selected text and clipboard
    /// are fully captured before the panel appears.
    func togglePanel() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            Task { @MainActor in
                // Refresh config from disk so API key changes are picked up without a restart.
                ConfigService.shared.load()
                // Await context refresh — selected text read completes (or times out) first.
                await ContextService.shared.refresh()
                self.showPanel()
            }
        }
    }

    /// Shows the floating command bar panel with a fade-in animation.
    /// Context is already refreshed by togglePanel() before this is called.
    private func showPanel() {

        let existingPanel = panel ?? buildPanel()
        panel = existingPanel

        positionPanel(existingPanel)
        existingPanel.alphaValue = 0
        existingPanel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        existingPanel.makeKey()
        panelVC.focusInput()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Constants.Panel.fadeInDuration
            existingPanel.animator().alphaValue = 1
        }

        startOutsideClickMonitor()
    }

    /// Hides the floating panel.
    private func hidePanel() {
        stopOutsideClickMonitor()
        panel?.orderOut(nil)
        panelVC.viewModel.reset()
        NSApp.hide(nil)
    }

    // MARK: - Panel Construction

    /// Builds and configures the FloatingPanel with PanelViewController as content.
    private func buildPanel() -> FloatingPanel {
        let initialFrame = NSRect(x: 0, y: 0,
                                  width: Constants.Panel.width,
                                  height: Constants.Panel.inputHeight)
        let newPanel = FloatingPanel(contentRect: initialFrame,
                                     styleMask: [],
                                     backing: .buffered,
                                     defer: false)
        newPanel.contentViewController = panelVC
        return newPanel
    }

    /// Centers the panel horizontally and places it at 35% from the top of the main screen.
    private func positionPanel(_ panel: FloatingPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelWidth = panel.frame.width
        let panelHeight = panel.frame.height

        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - (screenFrame.height * Constants.Panel.topOffsetRatio) - panelHeight
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Outside Click Monitor

    /// Installs a global event monitor to hide the panel when the user clicks outside it.
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor() // always remove any stale monitor first
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.hidePanel()
        }
    }

    /// Removes the global click monitor.
    private func stopOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Launch at Login

    /// Registers the app as a login item using SMAppService (macOS 13+).
    private func configureLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .notRegistered {
                try SMAppService.mainApp.register()
                print("[AppDelegate] Launch at login registered")
            }
        } catch {
            print("[AppDelegate] Launch at login registration failed: \(error)")
        }
    }
}

// MARK: - AppDelegate Extension for viewModel access

extension AppDelegate {
    /// Exposes the panel view model for internal access (e.g., resizing the panel from VC).
    var panelViewModel: PanelViewModel { panelVC.viewModel }
}

// MARK: - UNUserNotificationCenterDelegate

extension AppDelegate: UNUserNotificationCenterDelegate {

    /// Show notification banners even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Handle "Join Now" action — opens the meeting URL stored in userInfo.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let urlString = response.notification.request.content.userInfo[Constants.Notification.meetingURLKey] as? String
        let isJoin = response.actionIdentifier == Constants.Notification.joinAction
        if isJoin, let urlString, let url = URL(string: urlString) {
            Task { @MainActor in
                NSWorkspace.shared.open(url)
            }
        }
        completionHandler()
    }
}
