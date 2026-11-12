import SwiftUI
import UIKit

/// Shown in a chat right after the first new contact connects: the moment notifications
/// start to make sense. Allow triggers the system prompt; Not now hides it for good
/// (Settings still offers the switch).
struct NotificationOfferCard: View {
    @Environment(NotificationManager.self) private var notifications
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bell.badge")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Get notified when a message arrives while Earshot is in the background")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Notifications are made on this phone. Nothing goes to a server.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Button("Allow") { Task { await notifications.requestPermission() } }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityLabel("Allow notifications")
                    .accessibilityIdentifier("notifications.offer.allow")
                Button("Not Now") { notifications.declineOffer() }
                    .buttonStyle(PillButtonStyle(kind: .plain))
                    .accessibilityLabel("Not now")
                    .accessibilityIdentifier("notifications.offer.notNow")
            }
            .padding(.leading, typeSize.isAccessibilitySize ? 0 : 30)
        }
        .padding(14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.separator)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notifications.offer")
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

/// The Notifications section in Settings: current state, a way to turn them on, and the
/// "show message text" choice.
struct NotificationSettingsSection: View {
    @Environment(NotificationManager.self) private var notifications
    @Environment(\.openURL) private var openURL
    @AppStorage(NotificationManager.showTextKey) private var showText = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "bell")
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                Text("Message alerts")
                    .foregroundStyle(Palette.ink)
                Spacer(minLength: 8)
                switch notifications.permission {
                case .allowed:
                    Text("On")
                        .foregroundStyle(Palette.inkSecondary)
                case .notDetermined:
                    Button("Turn On") { Task { await notifications.requestPermission() } }
                        .buttonStyle(PillButtonStyle(kind: .tinted))
                        .accessibilityLabel("Turn on notifications")
                        .accessibilityIdentifier("settings.notifications.turnOn")
                case .denied:
                    Button("Off · Open Settings") {
                        if let url = URL(string: Self.systemSettingsURL) { openURL(url) }
                    }
                    .buttonStyle(PillButtonStyle(kind: .tinted))
                    .accessibilityLabel("Notifications are off. Open Settings")
                    .accessibilityIdentifier("settings.notifications.openSettings")
                }
            }
            .frame(minHeight: 44)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings.notifications")

            Toggle(isOn: $showText) {
                Text("Show message text in notifications")
                    .foregroundStyle(Palette.ink)
            }
            .tint(Palette.accent)
            .accessibilityIdentifier("settings.notifications.showText")
        } header: {
            SectionHeader("Notifications")
        } footer: {
            Text(showText
                 ? "Notifications show what was written, including on the lock screen. They are made on this phone; nothing goes to a server."
                 : "Notifications say only who wrote — “New message” — not what they wrote. They are made on this phone; nothing goes to a server.")
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
        }
        .listRowBackground(Palette.surface)
    }

    private static var systemSettingsURL: String {
        if #available(iOS 16.0, *) { return UIApplication.openNotificationSettingsURLString }
        return UIApplication.openSettingsURLString
    }
}
