import Foundation
import UserNotifications

/// Posts and manages local UNUserNotificationCenter notifications (e.g. meeting reminders).
final class NotificationService: @unchecked Sendable {

    static let shared = NotificationService()
    private init() {}

    // MARK: - Meeting Reminders

    /// Schedules a local notification to fire at `date` reminding the user of an upcoming meeting.
    /// The notification includes a "Join Now" action that opens the meeting URL when tapped.
    func scheduleMeetingReminder(urlString: String, title: String, at date: Date) async {
        guard date > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Meeting starting soon"
        content.body = "'\(title)' — tap Join Now to open the link"
        content.categoryIdentifier = Constants.Notification.meetingCategory
        content.userInfo = [Constants.Notification.meetingURLKey: urlString]
        content.sound = .default

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let requestID = Constants.Notification.meetingIDPrefix + UUID().uuidString
        let request = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
            LoggingService.shared.log("Meeting reminder scheduled for \(date)")
        } catch {
            LoggingService.shared.log(error: error, context: "scheduleMeetingReminder")
        }
    }

    // MARK: - Category Registration

    /// Registers the MEETING_JOIN notification category with "Join Now" action.
    /// Call once at app launch before any notifications are delivered.
    static func registerCategories() {
        let joinAction = UNNotificationAction(
            identifier: Constants.Notification.joinAction,
            title: "Join Now",
            options: .foreground
        )
        let category = UNNotificationCategory(
            identifier: Constants.Notification.meetingCategory,
            actions: [joinAction],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}
