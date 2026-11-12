import EarshotKit
import SwiftUI

struct SettingsView: View {
    @Environment(Messenger.self) private var messenger
    @State private var nameDraft = ""
    @State private var confirmErase = false
    @FocusState private var nameFocused: Bool

    private var cleanName: String { Limits.sanitizedName(nameDraft) }
    private var nameChanged: Bool { !cleanName.isEmpty && cleanName != messenger.profile.displayName }
    private var blockedCount: Int { messenger.contacts.filter(\.isBlocked).count }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Avatar(name: cleanName.isEmpty ? messenger.profile.displayName : cleanName, size: 44)
                    TextField("Your name", text: $nameDraft)
                        .font(.headline)
                        .foregroundStyle(Palette.ink)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($nameFocused)
                        .onSubmit(saveName)
                        .onChange(of: nameDraft) { _, value in
                            if value.count > Limits.maxNameLength { nameDraft = String(value.prefix(Limits.maxNameLength)) }
                        }
                        .accessibilityLabel("Your name")
                        .accessibilityIdentifier("settings.name")
                    if nameChanged {
                        Button("Save", action: saveName)
                            .buttonStyle(PillButtonStyle())
                            .accessibilityIdentifier("settings.saveName")
                    }
                }
                .frame(minHeight: 52)
            } header: {
                SectionHeader("Your name")
            } footer: {
                Text("Shown to people nearby. Changing it reconnects you briefly.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .listRowBackground(Palette.surface)

            Section {
                Toggle(isOn: Binding(get: { messenger.profile.isVisible }, set: { messenger.setVisible($0) })) {
                    Text("Visible to people nearby")
                        .foregroundStyle(Palette.ink)
                }
                .tint(Palette.accent)
                .accessibilityIdentifier("settings.visible")
            } footer: {
                Text(messenger.profile.isVisible
                     ? "Anyone nearby running Earshot can see the name “\(messenger.profile.displayName)” and send you a request — also while Earshot is in the background. Turn this off to stay hidden; you can still find people who are visible and reach your contacts when your phone finds theirs."
                     : "You're hidden. People nearby can't see you or send you requests, and contacts only connect when your phone finds theirs.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .listRowBackground(Palette.surface)

            NotificationSettingsSection()

            Section {
                NavigationLink(value: Route.howItWorks) {
                    SettingsLabel(title: "How Earshot works", systemImage: "dot.radiowaves.left.and.right")
                }
                NavigationLink(value: Route.privacy) {
                    SettingsLabel(title: "Privacy", systemImage: "lock")
                }
                if blockedCount > 0 {
                    NavigationLink(value: Route.blocked) {
                        HStack {
                            SettingsLabel(title: "Blocked people", systemImage: "hand.raised")
                            Spacer()
                            Text("\(blockedCount)")
                                .foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
            }
            .listRowBackground(Palette.surface)

            Section {
                Button("Delete Everything", role: .destructive) { confirmErase = true }
                    .foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("settings.deleteEverything")
            } footer: {
                Text("Erases your messages, contacts, name and this phone's identity key. Your contacts will see you as someone new.")
                    .font(.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .listRowBackground(Palette.surface)

            Section {
                VStack(spacing: 8) {
                    EarshotRings().frame(width: 28, height: 28)
                    Text("Earshot \(Self.version)")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.clear)
        }
        .listStyle(.insetGrouped)
        .earshotList()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { nameDraft = messenger.profile.displayName }
        .confirmationDialog("Delete everything?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Delete Everything", role: .destructive) { messenger.eraseEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All messages, contacts and your identity on this phone will be erased. This can't be undone.")
        }
    }

    private func saveName() {
        if nameChanged { messenger.setDisplayName(cleanName) }
        nameDraft = messenger.profile.displayName
        nameFocused = false
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
}

private struct SettingsLabel: View {
    let title: String
    let systemImage: String

    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 28

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Palette.accent)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minHeight: 32)
    }
}

struct BlockedContactsView: View {
    @Environment(Messenger.self) private var messenger

    var body: some View {
        let blocked = messenger.contacts.filter(\.isBlocked)
        List {
            if blocked.isEmpty {
                Text("Nobody is blocked.")
                    .foregroundStyle(Palette.inkSecondary)
                    .listRowBackground(Palette.surface)
            }
            Section {
                ForEach(blocked) { contact in
                    HStack(spacing: 12) {
                        Avatar(name: contact.displayName, size: 40)
                        Text(contact.displayName)
                            .font(.headline)
                            .foregroundStyle(Palette.ink)
                        Spacer()
                        Button("Unblock") { messenger.setBlocked(false, for: contact.id) }
                            .buttonStyle(PillButtonStyle(kind: .tinted))
                            .accessibilityLabel("Unblock \(contact.displayName)")
                    }
                }
            } footer: {
                if !blocked.isEmpty {
                    Text("Blocked people's phones can't link to yours or send you messages, and they aren't told. They could still appear as a new request under another name; accepting it won't link you.")
                        .font(.footnote)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            .listRowBackground(Palette.surface)
        }
        .listStyle(.insetGrouped)
        .earshotList()
        .navigationTitle("Blocked")
        .navigationBarTitleDisplayMode(.inline)
    }
}
