import Foundation
import AppKit

/// Registers and manages a system-wide global hotkey using CGEventTap.
/// Fires a callback whenever the configured hotkey combination is pressed.
/// Thread-safety: all mutation happens on the main run loop; @unchecked Sendable is safe here.
final class HotkeyManager: @unchecked Sendable {

    /// Called on the main thread when the hotkey fires.
    var onHotkey: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let keyCode: UInt16
    private let modifiers: CGEventFlags
    private var permissionPollTimer: Timer?

    init(keyCode: UInt16 = Constants.Hotkey.defaultKeyCode,
         modifiers: UInt64 = Constants.Hotkey.defaultModifiers) {
        self.keyCode = keyCode
        self.modifiers = CGEventFlags(rawValue: modifiers)
    }

    /// Attempts to register the global hotkey.
    /// If Accessibility permission is not yet granted, triggers the system prompt,
    /// shows a visible alert, and polls until permission is granted then auto-registers.
    func register() {
        if tryCreateTap() {
            return
        }

        // Tap creation failed — trigger the system Accessibility permission prompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        showAccessibilityAlert()
        startPermissionPolling()
    }

    /// Stops the event tap and any pending permission polling.
    func unregister() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil

        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Private

    /// Attempts to create the CGEventTap. Returns true on success.
    @discardableResult
    private func tryCreateTap() -> Bool {
        // Tear down any existing tap before creating a new one.
        if let existing = eventTap {
            CGEvent.tapEnable(tap: existing, enable: false)
            eventTap = nil
        }

        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue
        let selfPtr = Unmanaged.passRetained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            Unmanaged<HotkeyManager>.fromOpaque(selfPtr).release()
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[HotkeyManager] ⌥Space hotkey registered successfully")
        return true
    }

    /// Polls every 2 seconds until Accessibility permission is granted, then registers the tap.
    private func startPermissionPolling() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.permissionPollTimer = nil
                if self.tryCreateTap() {
                    print("[HotkeyManager] Accessibility permission granted — hotkey now active")
                }
            }
        }
    }

    /// Shows a modal alert explaining that Accessibility access is required.
    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Accessibility Permission Required"
            alert.informativeText = "Sky needs Accessibility access to register the ⌥Space global hotkey.\n\nGo to System Settings → Privacy & Security → Accessibility and enable Sky.\n\nThe hotkey will activate automatically once permission is granted — no restart needed."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Later")

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
        }
    }

    // MARK: - Event callback

    /// Checks whether the event matches the hotkey and fires the callback if so.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Only process key-down events; pass everything else through untouched.
        guard type == .keyDown else { return Unmanaged.passRetained(event) }

        // 1. Option modifier must be present — checked first, before reading the key code.
        guard event.flags.contains(.maskAlternate) else {
            return Unmanaged.passRetained(event)
        }

        // 2. Key code must match — only evaluated after the modifier guard passes.
        let pressedKey = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard pressedKey == keyCode else {
            return Unmanaged.passRetained(event)
        }

        // Both conditions met — fire and consume the event.
        DispatchQueue.main.async { [weak self] in self?.onHotkey?() }
        return nil
    }
}
