import EarshotKit
import SwiftUI

// MARK: Buttons

/// Full-width ember button for the main action on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .foregroundStyle(isEnabled ? Palette.onAccent : Palette.inkSecondary)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 20)
            .background(isEnabled ? Palette.accent : Palette.surfaceSunken,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Small capsule button used inside rows (Connect, Try again).
struct PillButtonStyle: ButtonStyle {
    enum Kind { case filled, tinted, plain }
    var kind: Kind = .filled
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 16)
            .frame(minHeight: 36)
            .background(background, in: Capsule())
            .frame(minHeight: 44) // keep a 44pt touch target around the visible pill
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var foreground: Color {
        guard isEnabled else { return Palette.inkSecondary }
        switch kind {
        case .filled: return Palette.onAccent
        case .tinted, .plain: return Palette.accent
        }
    }

    private var background: Color {
        guard isEnabled else { return Palette.surfaceSunken }
        switch kind {
        case .filled: return Palette.accent
        case .tinted: return Palette.accentWash
        case .plain: return .clear
        }
    }
}

// MARK: Avatar

/// Initials on a muted tone, with an ember ring when the person is within earshot.
struct Avatar: View {
    let name: String
    var link: LinkState?
    var size: CGFloat = 44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle().fill(Palette.avatar(for: name))
            Text(Self.initials(name))
                .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.ink)
                .minimumScaleFactor(0.5)
        }
        .frame(width: size, height: size)
        .padding(ringInset)
        .overlay { ring }
        .accessibilityHidden(true)
    }

    private var ringInset: CGFloat { link == nil ? 0 : max(3, size * 0.08) }

    @ViewBuilder private var ring: some View {
        let width = max(1.5, size * 0.05)
        switch link {
        case .connected:
            Circle().strokeBorder(Palette.signal, lineWidth: width)
        case .inRange:
            Circle().strokeBorder(Palette.signal.opacity(0.45), lineWidth: width)
        case .connecting:
            Circle()
                .strokeBorder(Palette.signal, style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [size * 0.12, size * 0.1]))
                .opacity(reduceMotion ? 0.8 : (pulsing ? 1 : 0.35))
                .onAppear {
                    guard !reduceMotion else { return }
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
                }
        case .outOfRange, .none:
            EmptyView()
        }
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

// MARK: Link state

extension LinkState {
    /// Short label for status lines.
    var label: String {
        switch self {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .inRange: "Nearby"
        case .outOfRange: "Out of range"
        }
    }
}

/// "Connected" / "Nearby" / "Connecting…" / "Out of range" with an ember dot when live.
struct LinkStatusLabel: View {
    let link: LinkState

    var body: some View {
        HStack(spacing: 5) {
            if link != .outOfRange {
                Circle()
                    .fill(link == .connected ? Palette.signal : Palette.signal.opacity(0.45))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(link.label)
                .foregroundStyle(link == .connected ? Palette.accent : Palette.inkSecondary)
        }
    }
}

// MARK: Text helpers

extension String {
    /// "Jensen Huang" -> "Jensen". Used to keep status copy short and personal.
    var firstName: String {
        split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? self
    }
}

// MARK: Surfaces

extension View {
    /// The warm paper (or ink) background used behind every screen.
    func screenBackground() -> some View {
        background(Palette.background.ignoresSafeArea())
    }

    /// Standard styling for grouped lists on Earshot's backgrounds.
    func earshotList() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
    }
}

/// A rounded tile used for callouts and empty states.
struct Callout<Content: View>: View {
    var tint: Color = Palette.surface
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// An icon + title + body row for explanations (onboarding, How it works).
/// At accessibility text sizes the icon sits above the text so the words get the full width.
struct ExplainerRow: View {
    let systemImage: String
    let title: String
    let detail: String

    @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 40
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        layout {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: min(iconSize, 64), height: min(iconSize, 64))
                .background(Palette.accentWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}
