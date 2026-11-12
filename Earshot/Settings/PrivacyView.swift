import SwiftUI

/// A plain-language summary of what Earshot does and doesn't do with your data.
struct PrivacyView: View {
    /// Kept in line with "What Earshot does not protect against" in docs/HOW_IT_WORKS.md.
    private static let limits = [
        "Someone holding your unlocked phone can read your messages in the app.",
        "Names aren't unique. Someone new can pick the same name as a person you know — compare safety codes if it matters.",
        "People with radio equipment can tell that Earshot phones are nearby and talking, and roughly how much.",
        "A recorded broadcast from one of your contacts can be replayed to make your phone react. Your identity isn't revealed, but the person replaying it learns that you know that contact.",
        "A friend whose phone carries your sealed message can see that you handed it a message, and when. If they pass it straight to the person it's for, they may be able to guess who that was and that it arrived.",
        "If your phone or your contact's phone is taken, relayed messages still on their way could be read until you two next connect directly, and for up to a week after. Messages already delivered stay protected.",
        "A message you wrote to someone before blocking them may still reach them through friends who already carry it. Earshot asks friends to delete it but can't guarantee that.",
        "Neither the encryption nor the relaying has had an independent security audit.",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Earshot has no servers and no accounts. Your messages go from your phone to theirs — directly, or sealed through your mutual contacts' phones if you both allow it. Nowhere else.")
                    .font(.display(.title3, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                ExplainerRow(systemImage: "lock.fill",
                             title: "End-to-end encrypted",
                             detail: "Every conversation is encrypted with keys that stay on the two phones. Compare safety codes to be sure nobody was in between when you first connected.")
                ExplainerRow(systemImage: "internaldrive",
                             title: "Stored only on this phone",
                             detail: "Messages and contacts stay on this device and are left out of iCloud and computer backups. iOS keeps them encrypted until the phone has been unlocked once after a restart; after that Earshot can read them, so it can save a message that arrives while the phone is locked.")
                ExplainerRow(systemImage: "person.2",
                             title: "Relaying through friends",
                             detail: "If you and a contact both leave relaying on, a text message to them can travel through your other contacts' phones while you're apart. Strangers never carry your messages, and your phone never carries strangers'. Carrying friends can't read a message or see who it's for. Relaying starts only after you and a contact have connected directly with this version, and nothing is guaranteed to arrive this way.")
                ExplainerRow(systemImage: "shippingbox",
                             title: "What your phone carries",
                             detail: "Up to 2 MB of sealed messages for your contacts, each for at most 48 hours. Your phone can't read them and keeps no record of who handed it which one. Turn relaying off in Settings and your phone takes no part: your messages are only delivered directly and it carries nothing for anyone.")
                ExplainerRow(systemImage: "photo",
                             title: "Photos without the hidden details",
                             detail: "Before a photo is sent, Earshot removes its location, camera model and date. Photos are kept only on your two phones, protected like messages and left out of backups. Earshot never sees your photo library: you pick one photo at a time.")
                ExplainerRow(systemImage: "link",
                             title: "Links are never fetched",
                             detail: "Earshot doesn't load link previews or anything else from the internet. A link only opens, in Safari, Mail or Phone, when you tap it.")
                ExplainerRow(systemImage: "bell",
                             title: "Notifications stay on the phone",
                             detail: "Notifications are created on this phone. Nothing goes to any server. By default they show only who wrote; showing the text is your choice in Settings.")
                ExplainerRow(systemImage: "person.wave.2",
                             title: "What people nearby see",
                             detail: "While “Visible to people nearby” is on, anyone nearby running Earshot can see the name you chose — also while Earshot is in the background. Earshot never uses your device's name.")
                ExplainerRow(systemImage: "eye.slash",
                             title: "Hard to follow",
                             detail: "Your contacts recognise your phone automatically. To anyone else the code that identifies it changes each time Earshot starts, so apart from the name you choose, strangers can't link one session to the next.")
                ExplainerRow(systemImage: "checkmark.seal",
                             title: "Safety codes",
                             detail: "Each contact has a safety code. Compare it in person to be sure you're talking to the right phone, then mark them as verified.")
                ExplainerRow(systemImage: "hand.raised",
                             title: "Few permissions",
                             detail: "Earshot asks for Bluetooth, to find phones nearby, and — only if you want them — notifications. No location, contacts, tracking or analytics.")

                VStack(alignment: .leading, spacing: 10) {
                    Text("What Earshot doesn't protect against")
                        .font(.display(.title3, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Self.limits, id: \.self) { limit in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("•").accessibilityHidden(true)
                            Text(limit).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.subheadline)
                        .foregroundStyle(Palette.inkSecondary)
                    }
                }
                .padding(.top, 8)
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview { NavigationStack { PrivacyView() } }
