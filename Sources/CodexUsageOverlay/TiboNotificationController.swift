import Foundation
import UserNotifications
import CodexUsageCore

@MainActor
final class TiboNotificationController: NSObject, TiboNotificationSending, UNUserNotificationCenterDelegate {
    var onSelection: ((String) -> Void)?

    private let center: UNUserNotificationCenter
    private static let identifierPrefix = "tibo-reset-"

    override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    func deliver(_ request: TiboNotificationRequest) async {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.badge = 1
        let notification = UNNotificationRequest(
            identifier: Self.identifierPrefix + request.messageID,
            content: content,
            trigger: nil
        )
        try? await center.add(notification)
    }

    func removeDelivered(id: String) {
        let identifier = Self.identifierPrefix + id
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        let identifierPrefix = "tibo-reset-"
        if identifier.hasPrefix(identifierPrefix) {
            let id = String(identifier.dropFirst(identifierPrefix.count))
            Task { @MainActor [weak self] in self?.onSelection?(id) }
        }
        completionHandler()
    }
}
