import AppKit

/// NSPanel subclass providing the floating command bar window.
/// Uses .floating level, vibrancy background, no titlebar, and won't appear in Mission Control.
final class FloatingPanel: NSPanel {

    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        configure()
    }

    /// Configures the panel's visual properties.
    private func configure() {
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isFloatingPanel = true
        ignoresMouseEvents = false
        // Never let AppKit auto-hide on app deactivation — all dismissal goes through our code
        hidesOnDeactivate = false

        // Soft, natural shadow
        if let contentView {
            contentView.wantsLayer = true
            contentView.layer?.shadowOpacity = 0
        }
    }

    /// NSPanel override — allows the panel to become key and main so button clicks are fully routed.
    override var canBecomeKey: Bool  { true }
    override var canBecomeMain: Bool { true }

    /// Forward standard edit commands so Cmd+V/C/X/A work inside the text field
    /// even though the panel uses .nonactivatingPanel and may not have full app focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)),      to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)),       to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)),        to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)),  to: nil, from: self)
        default:  return super.performKeyEquivalent(with: event)
        }
    }
}
