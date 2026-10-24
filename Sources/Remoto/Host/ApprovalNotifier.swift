import AppKit
import Foundation
import RemotoCore
import UserNotifications

/// Approval requests as system notifications with Allow and Deny, so the Mac
/// doesn't beep or steal focus (DESIGN §6.2.4). When notifications are off the
/// model shows the floating panel instead.
@MainActor
final class ApprovalNotifier: NSObject, UNUserNotificationCenterDelegate {
    enum Status { case unknown, notDetermined, allowed, off }

    nonisolated private static let category = "approval"
    nonisolated private static let allowAction = "allow"
    nonisolated private static let denyAction = "deny"
    nonisolated private static let idKey = "approvalID"

    private(set) var status: Status = .unknown
    /// `allow` is nil when the person clicked the notification itself.
    var onResponse: ((UInt64, Bool?) -> Void)?
    var onStatusChange: (() -> Void)?

    /// UserNotifications needs a real app bundle.
    private var center: UNUserNotificationCenter? { AppInfo.isBundled ? .current() : nil }

    func setUp() {
        guard let center else {
            status = .off
            return
        }
        center.delegate = self
        let allow = UNNotificationAction(identifier: Self.allowAction, title: String(localized: "Allow"), options: [])
        let deny = UNNotificationAction(
            identifier: Self.denyAction, title: String(localized: "Deny"), options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [allow, deny], intentIdentifiers: [], options: [])
        ])
        refreshStatus()
    }

    func refreshStatus() {
        guard let center else { return }
        Task {
            let settings = await center.notificationSettings()
            let new: Status =
                switch settings.authorizationStatus {
                case .notDetermined: .notDetermined
                case .authorized, .provisional: settings.alertSetting == .disabled ? .off : .allowed
                default: .off
                }
            if new != status {
                status = new
                onStatusChange?()
            }
        }
    }

    func requestAuthorization() {
        guard let center else { return }
        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            refreshStatus()
        }
    }

    /// Posts the request; returns false when notifications can't be shown.
    func post(_ request: ApprovalRequest) -> Bool {
        guard let center, status == .allowed else { return false }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "A phone wants to control this Mac")
        content.body = Self.body(request)
        content.categoryIdentifier = Self.category
        content.sound = .default
        content.userInfo = [Self.idKey: String(request.id)]
        center.add(UNNotificationRequest(identifier: Self.identifier(request.id), content: content, trigger: nil))
        return true
    }

    func remove(_ id: UInt64) {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.identifier(id)])
        center?.removePendingNotificationRequests(withIdentifiers: [Self.identifier(id)])
    }

    /// Name and model come from the phone, so the address (which the phone
    /// can't fake on the LAN) gets its own line, plus a warning for lookalikes.
    static func body(_ request: ApprovalRequest) -> String {
        var lines = [[displayName(request), request.model].filter { !$0.isEmpty }.joined(separator: " · ")]
        lines.append(String(localized: "Address: \(request.address)"))
        if request.nameMatchesTrustedDevice {
            lines.append(String(localized: "A device with this name is already paired"))
        }
        return lines.joined(separator: "\n")
    }

    static func displayName(_ request: ApprovalRequest) -> String {
        request.deviceName.isEmpty ? String(localized: "Unknown device") : request.deviceName
    }

    private static func identifier(_ id: UInt64) -> String { "approval-\(id)" }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action = response.actionIdentifier
        let id = (response.notification.request.content.userInfo[Self.idKey] as? String).flatMap(UInt64.init)
        completionHandler()
        guard let id else { return }
        let allow: Bool? =
            switch action {
            case Self.allowAction: true
            case Self.denyAction: false
            case UNNotificationDismissActionIdentifier: nil
            default: nil
            }
        let openPanel = action == UNNotificationDefaultActionIdentifier
        guard allow != nil || openPanel else { return }
        Task { @MainActor in self.onResponse?(id, allow) }
    }
}
