import EarshotKit
import Observation
import UIKit
import UserNotifications

/// Local notifications for messages and connection requests that arrive while the person
/// isn't looking. Everything is created on this phone: there is no push service or server.
///
/// - A message notifies when Earshot isn't active, or when that conversation isn't on screen.
/// - A request notifies only when Earshot isn't active (otherwise the request sheet shows).
/// - The body says "New message" unless the person turned on "Show message text". With it on,
///   a photo says "Photo" (plus its caption), and text is shown raw, exactly as typed.
/// - Permission is asked at a relevant moment (after the first new contact connects, or from
///   Settings), never at launch.
@MainActor
@Observable
final class NotificationManager: NSObject {
    enum Permission: Equatable {
        case notDetermined, allowed, denied
    }

    /// When the in-chat explainer may appear after the first new contact connects.
    enum OfferPolicy {
        /// Only if the system hasn't asked yet and the person hasn't answered the card. The real app.
        case whenUseful
        /// Never. Demo mode by default, so UI tests are never blocked by it.
        case never
        /// Always, whatever the permission state (`-demo … -demoNotificationPrompt`), for its test and screenshot.
        case always
    }

    static let showTextKey = "notifications.showMessageText"
    private static let offerAnsweredKey = "notifications.offerAnswered"
    private static let kindKey = "kind"
    private static let contactKey = "contactID"

    private(set) var permission: Permission = .notDetermined
    /// True while the in-chat "Get notified…" card should be offered.
    private(set) var isOfferingPermission = false
    /// The conversation currently on screen, if any. Set by the chat view.
    var openConversation: ContactID?

    @ObservationIgnored private let center = UNUserNotificationCenter.current()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let remembersOffer: Bool
    @ObservationIgnored private let offerPolicy: OfferPolicy
    @ObservationIgnored private var offerAnsweredThisRun = false
    @ObservationIgnored private weak var router: AppRouter?
    @ObservationIgnored private weak var messenger: Messenger?

    /// - Parameter remembersOffer: false in demo mode, so every demo launch starts fresh.
    init(defaults: UserDefaults = .standard, remembersOffer: Bool = true, offer: OfferPolicy = .whenUseful) {
        self.defaults = defaults
        self.remembersOffer = remembersOffer
        self.offerPolicy = offer
        super.init()
    }

    /// Must run during app launch, so a tap on a notification that launched the app is delivered.
    func attach(messenger: Messenger, router: AppRouter) {
        self.messenger = messenger
        self.router = router
        center.delegate = self
        Task { await refreshPermission() }
    }

    // MARK: Permission

    func refreshPermission() async {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral: permission = .allowed
        case .denied: permission = .denied
        case .notDetermined: permission = .notDetermined
        @unknown default: permission = .denied
        }
        if permission != .notDetermined, offerPolicy != .always { isOfferingPermission = false }
    }

    func requestPermission() async {
        markOfferAnswered()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshPermission()
    }

    /// "Not now" on the in-chat card. Settings still offers to turn notifications on.
    func declineOffer() {
        markOfferAnswered()
    }

    /// Called right after a new contact connects for the first time.
    func offerPermissionIfUseful() {
        switch offerPolicy {
        case .never: return
        case .always: isOfferingPermission = !offerAnswered
        case .whenUseful: isOfferingPermission = permission == .notDetermined && !offerAnswered
        }
    }

    private var offerAnswered: Bool {
        remembersOffer ? defaults.bool(forKey: Self.offerAnsweredKey) : offerAnsweredThisRun
    }

    private func markOfferAnswered() {
        isOfferingPermission = false
        offerAnsweredThisRun = true
        if remembersOffer { defaults.set(true, forKey: Self.offerAnsweredKey) }
    }

    // MARK: Posting

    /// Wire to `Messenger.onEvent`.
    func handle(_ event: Messenger.Event) {
        switch event {
        case .messageReceived(let id, let message):
            let isActive = UIApplication.shared.applicationState == .active
            guard !isActive || openConversation != id else { return }
            let name = messenger?.contact(id)?.displayName ?? "New message"
            let showText = defaults.bool(forKey: Self.showTextKey)
            post(identifier: "message-\(message.id.uuidString)", title: name,
                 body: showText ? Self.body(for: message) : "New message",
                 thread: id.rawValue, userInfo: [Self.kindKey: "message", Self.contactKey: id.rawValue])
        case .requestReceived(let request):
            guard UIApplication.shared.applicationState != .active else { return }
            post(identifier: "request-\(request.id.rawValue)", title: request.displayName,
                 body: "\(request.displayName) wants to connect",
                 thread: "requests", userInfo: [Self.kindKey: "request"])
        case .connected:
            break
        }
    }

    /// What a notification says when message text is shown.
    static func body(for message: Message) -> String {
        guard message.photo != nil else { return message.text }
        return message.text.isEmpty ? "Photo" : "Photo: \(message.text)"
    }

    private func post(identifier: String, title: String, body: String, thread: String, userInfo: [String: String]) {
        guard permission == .allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = thread
        content.userInfo = userInfo
        center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }

    /// Clears a conversation's notifications from Notification Centre once it has been opened.
    func clearDelivered(for id: ContactID) {
        let thread = id.rawValue
        center.getDeliveredNotifications { notifications in
            let ids = notifications.filter { $0.request.content.threadIdentifier == thread }.map(\.request.identifier)
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    // MARK: Responding

    fileprivate func shouldPresentInForeground(thread: String, kind: String?) -> Bool {
        switch kind {
        case "message": return openConversation?.rawValue != thread
        default: return false // The request sheet is already on screen.
        }
    }

    fileprivate func open(kind: String?, contactID: String?) {
        guard let router, let messenger else { return }
        if kind == "message", let raw = contactID, messenger.contact(ContactID(rawValue: raw)) != nil {
            router.presentedRequest = nil
            router.openChat(ContactID(rawValue: raw))
        } else {
            router.popToRoot()
            router.handle(messenger.requests, messenger: messenger)
        }
    }
}

// These use the completion-handler form on purpose. The `async` form of these two methods
// answers iOS from a background thread, and iOS then stops the app with "call must be
// made on main thread". On a real phone that looked like: tap a notification, Earshot
// does not open, and the pending connection request is gone (because the app had died).
// iOS always calls these on the main thread, which `@preconcurrency` lets us rely on.
extension NotificationManager: @preconcurrency UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        let show = shouldPresentInForeground(thread: content.threadIdentifier, kind: content.userInfo["kind"] as? String)
        completionHandler(show ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        open(kind: info["kind"] as? String, contactID: info["contactID"] as? String)
        completionHandler()
    }
}
