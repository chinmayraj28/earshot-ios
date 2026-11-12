import EarshotKit
import SwiftUI

/// Safety code, verification, and the destructive actions for one contact.
struct ContactDetailView: View {
    let contactID: ContactID

    @Environment(Messenger.self) private var messenger
    @Environment(AppRouter.self) private var router
    @State private var confirming: Confirmation?

    enum Confirmation: Identifiable {
        case clear, block, remove
        var id: Self { self }
    }

    var body: some View {
        if let contact = messenger.contact(contactID) {
            content(contact)
        } else {
            ContentUnavailableView("Contact removed", systemImage: "person.crop.circle.badge.xmark")
                .screenBackground()
        }
    }

    private func content(_ contact: Contact) -> some View {
        let link = messenger.linkState(for: contact.id)
        return List {
            Section {
                VStack(spacing: 10) {
                    Avatar(name: contact.displayName, link: contact.isBlocked ? nil : link, size: 84)
                    Text(contact.displayName)
                        .font(.display(.title2, weight: .bold))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                    if contact.isBlocked {
                        Text("Blocked")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Palette.danger)
                    } else {
                        LinkStatusLabel(link: link)
                            .font(.subheadline.weight(.medium))
                    }
                    Text("Contact since \(contact.addedAt.formatted(date: .long, time: .omitted))")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.clear)

            Section {
                SafetyCodeView(code: messenger.safetyCode(for: contact.id) ?? "—", isVerified: contact.isVerified)
                Button {
                    messenger.setVerified(!contact.isVerified, for: contact.id)
                } label: {
                    Label(contact.isVerified ? "Mark as Not Verified" : "Mark as Verified",
                          systemImage: contact.isVerified ? "xmark.seal" : "checkmark.seal")
                        .frame(minHeight: 32)
                }
                .foregroundStyle(Palette.accent)
                .accessibilityIdentifier("contact.verify")
            } header: {
                SectionHeader("Safety code")
            } footer: {
                Text("When you're together, check that \(contact.displayName.firstName)'s phone shows the same number. If it matches, your messages can only be read by the two of you. Codes change if either of you reinstalls Earshot.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .listRowBackground(Palette.surface)

            Section {
                Button("Clear Conversation") { confirming = .clear }
                    .foregroundStyle(Palette.ink)
                    .disabled(messenger.messages(for: contact.id).isEmpty)
                if contact.isBlocked {
                    Button("Unblock \(contact.displayName)") { messenger.setBlocked(false, for: contact.id) }
                        .foregroundStyle(Palette.accent)
                } else {
                    Button("Block \(contact.displayName)") { confirming = .block }
                        .foregroundStyle(Palette.danger)
                }
                Button("Remove Contact") { confirming = .remove }
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("contact.remove")
            }
            .listRowBackground(Palette.surface)
        }
        .listStyle(.insetGrouped)
        .earshotList()
        .navigationTitle("Contact")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(dialogTitle(contact), isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible, presenting: confirming) { action in
            switch action {
            case .clear:
                Button("Clear Conversation", role: .destructive) { messenger.clearConversation(contact.id) }
            case .block:
                Button("Block", role: .destructive) { messenger.setBlocked(true, for: contact.id) }
            case .remove:
                Button("Remove Contact", role: .destructive) {
                    router.popToRoot()
                    messenger.removeContact(contact.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action {
            case .clear: Text("Deletes every message with \(contact.displayName) from this phone. \(contact.displayName.firstName) keeps their copy.")
            case .block: Text("\(contact.displayName.firstName)'s phone won't be able to link to yours or send you messages, and they won't be told. They could still appear as a new request under another name; accepting it won't link you. You can unblock them from Settings.")
            case .remove: Text("Deletes \(contact.displayName) and your conversation from this phone. To talk again, one of you taps Connect and the other sees a normal request.")
            }
        }
    }

    private func dialogTitle(_ contact: Contact) -> String {
        switch confirming {
        case .clear: "Clear conversation?"
        case .block: "Block \(contact.displayName)?"
        case .remove: "Remove \(contact.displayName)?"
        case nil: ""
        }
    }
}

/// The 9-digit code, large and spaced for comparing out loud.
private struct SafetyCodeView: View {
    let code: String
    let isVerified: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    codeText
                    verifiedBadge
                }
            } else {
                HStack(spacing: 8) {
                    codeText
                    Spacer(minLength: 8)
                    verifiedBadge
                }
            }
        }
        .padding(.vertical, 8)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Safety code \(code.map { $0 == " " ? "," : String($0) }.joined(separator: " "))\(isVerified ? ", verified" : "")")
        .accessibilityIdentifier("contact.safetyCode")
    }

    private var codeText: some View {
        Text(code)
            .font(.system(.title, design: .monospaced, weight: .semibold))
            .foregroundStyle(Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var verifiedBadge: some View {
        if isVerified {
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                Text("Verified")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.accent)
            .fixedSize()
        }
    }
}
