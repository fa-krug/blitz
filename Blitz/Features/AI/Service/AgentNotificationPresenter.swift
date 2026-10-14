import Foundation
import OSLog
import UserNotifications

/// Posts and withdraws the agent's waiting notifications, and routes a click back to its chat.
@MainActor
final class AgentNotificationPresenter: NSObject {
    /// Told which chat a clicked notification belongs to.
    var onOpen: ((UUID) -> Void)?
    /// Asked before a banner shows while Blitz is in front, so a chat already on screen shows none.
    var isOnScreen: ((UUID) -> Bool)?
    /// Each one's wait is still on; a post that lands after its wait ended withdraws itself.
    private var posted: Set<String> = []

    private nonisolated static let logger = Logger(
        subsystem: "de.fa-krug.blitz", category: "AgentNotifications")

    /// Before any notification can be clicked, so a click is never delivered to nobody.
    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    func post(_ notice: AgentWaitNotice) {
        posted.insert(notice.identifier)
        Task {
            guard await Self.deliver(notice), !posted.contains(notice.identifier) else { return }
            Self.remove([notice.identifier])
        }
    }

    func withdraw(chatID: UUID) {
        let identifier = AgentWaitNotice.identifier(for: chatID)
        guard posted.remove(identifier) != nil else { return }
        Self.remove([identifier])
    }

    /// Quitting ends every wait, and nothing would be left to answer the ones still showing.
    func withdrawAll() {
        Self.remove(Array(posted))
        posted = []
    }

    private nonisolated static func remove(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Denied, or never answered, posts nothing: the sidebar badge and menu bar dot still show.
    private nonisolated static func deliver(_ notice: AgentWaitNotice) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard await isAuthorized(center) else { return false }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        content.userInfo = notice.userInfo
        let request = UNNotificationRequest(
            identifier: notice.identifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            logger.error("Agent notification not posted: \(error.localizedDescription)")
            return false
        }
    }

    /// Asked on first need rather than at launch, so a Mac that never leaves a turn is never asked.
    private nonisolated static func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                logger.error("Notification authorization failed: \(error.localizedDescription)")
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func open(_ chatID: UUID) {
        onOpen?(chatID)
    }

    private func shouldPresent(_ chatID: UUID) -> Bool {
        posted.contains(AgentWaitNotice.identifier(for: chatID)) && isOnScreen?(chatID) != true
    }
}

extension AgentNotificationPresenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
            let chatID = AgentWaitNotice.chatID(in: response.notification.request.content.userInfo)
        else { return }
        await open(chatID)
    }

    /// Blitz in front is no reason to stay quiet: the chat that waits may be one it is not showing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard let chatID = AgentWaitNotice.chatID(in: notification.request.content.userInfo),
            await shouldPresent(chatID)
        else { return [] }
        return [.banner, .list, .sound]
    }
}
