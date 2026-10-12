import AppKit
import UserNotifications

/// Posts clock-in / clock-out notifications and routes their action buttons back.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Action: String {
        /// Clicked the notification body.
        case open
        /// Auto clock-in: the activity wasn't work.
        case discard = "DISCARD"
        /// Auto clock-in: discard and turn auto clock-in off.
        case disableAutoClockIn = "DISABLE_AUTO"
        /// Auto clock-out: count the idle gap as work and keep going.
        case countIdleTime = "COUNT_IDLE"
    }

    enum Category: String {
        case autoStart = "AUTO_START"
        case autoStop = "AUTO_STOP"
    }

    static let sessionIDKey = "sessionID"

    var onAction: ((Action, UUID?) -> Void)?

    // UNUserNotificationCenter crashes when the binary isn't inside an app bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setUp() {
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Category.autoStart.rawValue,
                actions: [
                    UNNotificationAction(identifier: Action.discard.rawValue, title: "Not work — discard"),
                    UNNotificationAction(identifier: Action.disableAutoClockIn.rawValue, title: "Discard & turn off auto clock-in"),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: Category.autoStop.rawValue,
                actions: [
                    UNNotificationAction(identifier: Action.countIdleTime.rawValue, title: "I was working — count idle time"),
                ],
                intentIdentifiers: []
            ),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, category: Category, sessionID: UUID?) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category.rawValue
        if let sessionID {
            content.userInfo = [Self.sessionIDKey: sessionID.uuidString]
        }
        // Replace the previous notification of the same kind instead of stacking them.
        let request = UNNotificationRequest(identifier: category.rawValue, content: content, trigger: nil)
        center.add(request)
    }

    func authorizationDenied(_ completion: @escaping (Bool) -> Void) {
        guard let center else { return completion(false) }
        center.getNotificationSettings { settings in
            DispatchQueue.main.async { completion(settings.authorizationStatus == .denied) }
        }
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let action: Action? = response.actionIdentifier == UNNotificationDefaultActionIdentifier
            ? .open
            : Action(rawValue: response.actionIdentifier)
        let sessionID = (response.notification.request.content.userInfo[Self.sessionIDKey] as? String)
            .flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async { [weak self] in
            if let action { self?.onAction?(action, sessionID) }
            completionHandler()
        }
    }
}
