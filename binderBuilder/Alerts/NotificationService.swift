//
//  NotificationService.swift
//  binderBuilder
//
//  Thin wrapper over local notifications (no server, no entitlement needed):
//  authorization + firing a local alert. Used by AlertChecker for price-drop
//  and new-release notifications, and by DropScheduler for the dated
//  release-date reminders.
//

import OSLog
import UserNotifications

enum NotificationService {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "NotificationService")

    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    static func fire(title: String, body: String, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    /// Schedules a one-shot notification for a wall-clock moment in the
    /// device's current time zone. Re-using an id replaces the pending request.
    static func schedule(id: String, title: String, body: String, at components: DateComponents) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            log.error("schedule \(id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Cancels every pending request whose identifier starts with `prefix`.
    static func cancel(idsWithPrefix prefix: String) async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(prefix) }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}
