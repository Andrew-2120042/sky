import AppKit
import Contacts
import CoreGraphics
import EventKit
import Speech
import UserNotifications

/// Checks and requests macOS privacy permissions needed by Sky's action handlers.
@MainActor final class PermissionsManager {

    /// Shared singleton; must be accessed on the main actor.
    static let shared = PermissionsManager()

    /// Kept alive here so EventKit observers are not prematurely deallocated.
    let eventStore = EKEventStore()

    private init() {}

    // MARK: - Request

    /// Requests Contacts access and returns `true` if granted.
    func requestContacts() async -> Bool {
        let store = CNContactStore()
        do {
            return try await store.requestAccess(for: .contacts)
        } catch {
            LoggingService.shared.log(error: error, context: "requestContacts")
            return false
        }
    }

    /// Requests Calendar write access and returns `true` if granted.
    func requestCalendars() async -> Bool {
        if #available(macOS 14, *) {
            do {
                return try await eventStore.requestWriteOnlyAccessToEvents()
            } catch {
                LoggingService.shared.log(error: error, context: "requestCalendars")
                return false
            }
        } else {
            return await withCheckedContinuation { cont in
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error { LoggingService.shared.log(error: error, context: "requestCalendars(legacy)") }
                    cont.resume(returning: granted)
                }
            }
        }
    }

    /// Requests Reminders full access and returns `true` if granted.
    func requestReminders() async -> Bool {
        if #available(macOS 14, *) {
            do {
                return try await eventStore.requestFullAccessToReminders()
            } catch {
                LoggingService.shared.log(error: error, context: "requestReminders")
                return false
            }
        } else {
            return await withCheckedContinuation { cont in
                eventStore.requestAccess(to: .reminder) { granted, error in
                    if let error { LoggingService.shared.log(error: error, context: "requestReminders(legacy)") }
                    cont.resume(returning: granted)
                }
            }
        }
    }

    /// Requests Speech Recognition authorization and returns `true` if granted.
    func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Requests screen recording access by triggering the system prompt if not yet granted.
    /// The system dialog is asynchronous — the user may need to restart the app after granting.
    func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Returns `true` when screen recording permission has been granted.
    var screenRecordingGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Requests notification authorization and returns `true` if granted.
    func requestNotifications() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            LoggingService.shared.log(error: error, context: "requestNotifications")
            return false
        }
    }

    // MARK: - Status

    /// Returns `true` when Contacts access has been granted.
    var contactsGranted: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// Returns `true` when Calendar write (or full) access has been granted.
    var calendarsGranted: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14, *) {
            return status == .fullAccess || status == .writeOnly
        } else {
            return status == .authorized
        }
    }

    /// Returns `true` when Reminders full access has been granted.
    var remindersGranted: Bool {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if #available(macOS 14, *) {
            return status == .fullAccess
        } else {
            return status == .authorized
        }
    }

    // MARK: - Helper

    /// Opens the Privacy & Security pane in System Settings.
    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
        NSWorkspace.shared.open(url)
    }
}
