import Foundation
import UserNotifications

/// Routes web-based flows to the headless browser agent loop.
/// Native app tasks (Calendar, Reminders, Mail) still use FlowExecutionService.
@MainActor
final class HeadlessFlowService {
    static let shared = HeadlessFlowService()
    private init() {}

    /// Execute a web flow completely in the headless browser.
    func execute(
        goal: String,
        contextURL: String? = nil,
        progressHandler: @escaping @MainActor (String) -> Void
    ) async -> String {
        print("🌐 [HeadlessFlow] Starting: '\(goal)'")

        // Prefer an explicit URL from context (current browser page), then skill default
        let startUrl = contextURL ?? SkillsService.shared.findStartUrl(for: goal, currentURL: contextURL)
        let skillHint = SkillsService.shared.findHint(for: goal, currentURL: startUrl)

        if skillHint != nil {
            print("🎯 [HeadlessFlow] Using skill hint")
        }

        do {
            let browser = HeadlessBrowserService.shared
            try await browser.start()

            let (success, summary) = try await browser.runFlow(
                goal: goal,
                startUrl: startUrl,
                skillHint: skillHint,
                progressHandler: progressHandler
            )

            sendNotification(
                title: success ? "Sky — Done ✓" : "Sky — Could not complete",
                body: summary
            )

            ActionLogService.shared.record(
                summary: "Headless flow: \(goal) → \(summary)",
                succeeded: success
            )

            print("🌐 [HeadlessFlow] Complete: success=\(success) summary=\(summary)")
            return summary

        } catch {
            let errorMsg = "Browser error: \(error.localizedDescription)"
            sendNotification(title: "Sky — Error", body: errorMsg)
            print("🌐 [HeadlessFlow] Error: \(error)")
            return errorMsg
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
