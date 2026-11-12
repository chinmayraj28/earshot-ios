import EarshotKit
import SwiftUI

/// Settings: "Relay through friends", and what this phone is carrying for friends.
struct RelaySettingsSection: View {
    @Environment(Messenger.self) private var messenger
    @State private var confirmErase = false

    private var isOn: Bool { messenger.carryMode == .friends }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { isOn }, set: { messenger.setCarryMode($0 ? .friends : .off) })) {
                Text("Relay through friends")
                    .foregroundStyle(Palette.ink)
            }
            .tint(Palette.accent)
            .accessibilityHint("Lets sealed text messages travel through your contacts' phones while you're apart")
            .accessibilityIdentifier("settings.relay")

            if messenger.carriedMailCount > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Text(RelayText.carrying(count: messenger.carriedMailCount, bytes: messenger.carriedMailBytes))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.relay.carrying")
                    Button("Delete Carried Messages") { confirmErase = true }
                        .foregroundStyle(Palette.danger)
                        .accessibilityIdentifier("settings.relay.deleteCarried")
                }
                .padding(.vertical, 4)
            }
        } header: {
            SectionHeader("Relaying")
        } footer: {
            Text(isOn ? RelayText.footerOn : RelayText.footerOff)
                .font(.footnote)
                .foregroundStyle(Palette.inkSecondary)
                .accessibilityIdentifier("settings.relay.footer")
        }
        .listRowBackground(Palette.surface)
        .confirmationDialog("Delete carried messages?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Delete Carried Messages", role: .destructive) { messenger.eraseCarriedMail() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("These are sealed messages your phone is holding for your contacts. It can't read them. If you delete them, they may arrive later another way, or not at all.")
        }
    }
}

/// Relaying wording used in more than one place.
enum RelayText {
    static let footerOn = "On: when you and a contact are apart, your text messages to them can travel sealed through your other contacts' phones, and your phone carries theirs, for up to 48 hours. Off: this phone takes no part, and messages are only ever delivered directly."
    static let footerOff = "Off: this phone takes no part. Your messages are only delivered directly, and it carries nothing for anyone. If you turn it back on, relaying with each contact starts after you next connect directly."

    static func carrying(count: Int, bytes: Int) -> String {
        let size = "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
        return count == 1
            ? "Carrying 1 sealed message for friends (\(size))"
            : "Carrying \(count) sealed messages for friends (\(size))"
    }

    /// Status under a Waiting message that has been sealed for friends to carry.
    static func sealed(handoffs: Int) -> String {
        switch handoffs {
        case 0: "Waiting · sealed for friends to carry"
        case 1: "Waiting · sealed, with 1 friend's phone"
        default: "Waiting · sealed, with \(handoffs) friends' phones"
        }
    }

    static func sealedSpoken(handoffs: Int, name: String) -> String {
        let carriers = switch handoffs {
        case 0: "No friend's phone has taken it yet."
        case 1: "One friend's phone has a copy."
        default: "\(handoffs) friends' phones have a copy."
        }
        return "Waiting. Sealed so friends can carry it to \(name). \(carriers) Not delivered yet."
    }

    static let deliveredViaFriends = "Delivered · via friends"
    static let viaFriends = "via friends"
}

/// The quiet line under a message that arrived through friends' phones.
struct ViaFriendsMarker: View {
    var body: some View {
        Label(RelayText.viaFriends, systemImage: "person.2")
            .font(.caption)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Palette.inkSecondary)
            .accessibilityLabel("Arrived through friends' phones")
            .accessibilityIdentifier("chat.viaFriends")
    }
}

/// Contact details: can messages to this person travel through friends?
struct RelayContactSection: View {
    let contact: Contact
    @Environment(Messenger.self) private var messenger
    @Environment(AppRouter.self) private var router

    var body: some View {
        let first = contact.displayName.firstName
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: messenger.canRelay(to: contact.id) ? "person.2.fill" : "person.2")
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(first))
                        .foregroundStyle(Palette.ink)
                    Text(detail(first))
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("contact.relay")
            if messenger.carryMode == .off {
                Button("Relaying Settings") { router.path.append(.settings) }
                    .foregroundStyle(Palette.accent)
            }
        } header: {
            SectionHeader("Relay through friends")
        }
        .listRowBackground(Palette.surface)
    }

    private func title(_ first: String) -> String {
        if messenger.carryMode == .off { return "Relaying is off" }
        return messenger.canRelay(to: contact.id) ? "Messages can travel through friends" : "Not yet"
    }

    private func detail(_ first: String) -> String {
        if messenger.carryMode == .off {
            return "Messages to \(first) are only delivered directly, when your phones are near each other."
        }
        if messenger.canRelay(to: contact.id) {
            return "While you're apart, messages to \(first) are sealed so your mutual contacts' phones can carry them. Text only, for up to 48 hours."
        }
        return "Relaying starts after you two next connect directly, and only if \(first) has relaying on too."
    }
}
