import SwiftUI

/// Range, foreground-only and radios, explained plainly with a small diagram.
struct HowItWorksView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                RangeDiagram()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                ExplainerRow(systemImage: "antenna.radiowaves.left.and.right",
                             title: "Bluetooth, phone to phone",
                             detail: "Earshot talks straight from your phone to theirs over Bluetooth. It uses no Wi‑Fi, internet or mobile signal, and messages aren't passed along through other phones. Bluetooth can stay on in Airplane Mode.")
                ExplainerRow(systemImage: "dot.radiowaves.left.and.right",
                             title: "Short range",
                             detail: "About one room — a few tens of metres in the open, less through walls and bodies.")
                ExplainerRow(systemImage: "lock.iphone",
                             title: "Works in the background",
                             detail: "If you've opened Earshot and haven't swiped it away, a contact nearby can reach you while your phone is locked or in your pocket, and you get a notification (if you allow them).")
                ExplainerRow(systemImage: "info.circle",
                             title: "What it can't do",
                             detail: "The person sending needs Earshot open. Two phones that are both locked when they first come near each other don't link up until one person opens Earshot. Swiping Earshot away in the app switcher, or restarting the phone, stops it until it's opened again.")
                ExplainerRow(systemImage: "tortoise",
                             title: "Slower in the background",
                             detail: "When your phone is locked, a message can take longer to arrive — from a few seconds up to a minute or so.")
                ExplainerRow(systemImage: "clock",
                             title: "Messages that wait",
                             detail: "If someone is out of range, your message shows “Waiting” and sends by itself the next time your phones link up.")
                ExplainerRow(systemImage: "checkmark.circle",
                             title: "“Delivered” means delivered",
                             detail: "Delivered appears only after the other phone confirms it received and saved your message. “Not delivered” means no confirmation came back — for example, their phone couldn't save it. Tap it to try again.")
                ExplainerRow(systemImage: "photo",
                             title: "Photos, slowly but surely",
                             detail: "Tap the photo button while you're connected to send one photo at a time. Earshot shrinks it to about 150 KB and removes its location and camera details first. Over Bluetooth that takes a few seconds to about half a minute. If the connection drops, the photo starts again when you're back in range. Video isn't supported.")
                ExplainerRow(systemImage: "textformat",
                             title: "Formatting",
                             detail: "Type *bold*, _italic_, ~strikethrough~ or `code`. Web links, email addresses and phone numbers become tappable. Nothing opens until you tap it, and Earshot never loads link previews.")
            }
            .padding(20)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle("How Earshot works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// You at the centre of fading rings; one phone inside earshot, one beyond it.
struct RangeDiagram: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let radius = min(w * 0.36, h * 0.46)
            let you = CGPoint(x: w * 0.36, y: h * 0.5)
            let near = CGPoint(x: you.x + radius * 0.55, y: you.y - radius * 0.42)
            let far = CGPoint(x: min(w - 34, you.x + radius * 1.45), y: you.y + radius * 0.35)

            ZStack {
                EarshotRings(color: Palette.signal, ringCount: 3, dotFraction: 0)
                    .frame(width: radius * 2, height: radius * 2)
                    .position(you)

                Path { path in
                    path.move(to: you)
                    path.addLine(to: near)
                }
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 5]))

                phone(at: you, label: "You", emphasized: true)
                phone(at: near, label: "In range", emphasized: true)
                phone(at: far, label: "Out of range", emphasized: false)
            }
        }
        .frame(height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Diagram: your phone reaches another phone a short distance away. A phone further away is out of range.")
    }

    private func phone(at point: CGPoint, label: String, emphasized: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(emphasized ? Palette.ink : Palette.inkTertiary)
                .padding(6)
                .background(Palette.surface, in: Circle())
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(emphasized ? Palette.ink : Palette.inkSecondary)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Palette.surface, in: Capsule())
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .position(x: point.x, y: point.y + 12)
    }
}

#Preview { NavigationStack { HowItWorksView() } }
