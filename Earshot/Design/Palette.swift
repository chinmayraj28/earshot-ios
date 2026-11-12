import SwiftUI
import UIKit

/// Earshot's colour tokens. Every colour in the app comes from here.
///
/// Light mode is warm paper with deep ink text; dark mode is near-black ink with
/// warm off-white text. The single accent is "ember": the colour of a signal.
/// Each token has a stronger variant for Increase Contrast. Text pairs were
/// checked against WCAG AA (4.5:1 for body text):
///
/// | pair                                   | light | dark |
/// |----------------------------------------|-------|------|
/// | ink on background                      | 15.3  | 16.1 |
/// | inkSecondary on background             | 6.2   | 7.2  |
/// | accent (as text) on surface            | 5.5   | 7.4  |
/// | onBubbleOutgoing on bubbleOutgoing     | 5.4   | 5.7  |
/// | onAccent on accent (buttons)           | 5.3   | 8.1  |
/// | danger on surface                      | 6.3   | 7.5  |
enum Palette {
    /// Screen background.
    static let background = dynamic(light: 0xF5EFE6, dark: 0x121110, lightHC: 0xFAF6F0, darkHC: 0x000000)
    /// Cards, list rows, the composer field.
    static let surface = dynamic(light: 0xFFFBF5, dark: 0x1D1B19, lightHC: 0xFFFFFF, darkHC: 0x161412)
    /// Recessed areas: incoming bubbles, avatar placeholders, disabled buttons.
    static let surfaceSunken = dynamic(light: 0xEAE2D6, dark: 0x2A2724, lightHC: 0xE0D6C7, darkHC: 0x34302C)

    /// Primary text.
    static let ink = dynamic(light: 0x1C1916, dark: 0xF2ECE4, lightHC: 0x000000, darkHC: 0xFFFFFF)
    /// Secondary text: previews, captions, footers.
    static let inkSecondary = dynamic(light: 0x5F574D, dark: 0xA89F94, lightHC: 0x3F3830, darkHC: 0xD6CEC3)
    /// Icons and decoration only. Never used for text that must be read.
    static let inkTertiary = dynamic(light: 0x8A8175, dark: 0x6F675E, lightHC: 0x5F574D, darkHC: 0xA89F94)
    static let separator = dynamic(light: 0xE3D9CB, dark: 0x2E2A26, lightHC: 0xB9AD9C, darkHC: 0x5A534B)

    /// Ember. Tint, links, accent text, primary button fill.
    static let accent = dynamic(light: 0xB4421C, dark: 0xFF8A5C, lightHC: 0x8E3010, darkHC: 0xFFAE8A)
    /// Text and icons placed on an `accent` fill.
    static let onAccent = dynamic(light: 0xFFF8F2, dark: 0x1A0E08, lightHC: 0xFFFFFF, darkHC: 0x000000)
    /// The glowing ember used for decorative rings and live indicators.
    static let signal = dynamic(light: 0xE2603A, dark: 0xFF7A4D, lightHC: 0xB4421C, darkHC: 0xFF9C74)
    /// A soft wash of the accent for highlighted cards.
    static let accentWash = dynamic(light: 0xF8E3D6, dark: 0x2E1C14, lightHC: 0xF4D3C0, darkHC: 0x3D2216)

    static let bubbleOutgoing = dynamic(light: 0xB0431E, dark: 0xA9401C, lightHC: 0x8E3010, darkHC: 0x8A3314)
    static let onBubbleOutgoing = dynamic(light: 0xFFF8F2, dark: 0xFFF4EC, lightHC: 0xFFFFFF, darkHC: 0xFFFFFF)
    static let bubbleIncoming = surfaceSunken

    static let danger = dynamic(light: 0xB3261E, dark: 0xFF8A80, lightHC: 0x8C1D18, darkHC: 0xFFB4AB)

    /// Muted, warm avatar backgrounds. Initials are drawn in `ink` on top.
    static func avatar(for name: String) -> Color {
        let tones: [(UInt32, UInt32)] = [
            (0xF2D4C4, 0x4A2E22), // clay
            (0xDCE3CF, 0x2F3A27), // sage
            (0xD5DDE6, 0x26313D), // slate
            (0xEADBC0, 0x40331F), // sand
            (0xE6D3DE, 0x3D2734), // plum
            (0xCFE0DD, 0x213834), // sea
        ]
        let tone = tones[Int(stableHash(name) % UInt64(tones.count))]
        return dynamic(light: tone.0, dark: tone.1)
    }

    /// A hash that is the same on every launch (`String.hashValue` is not).
    private static func stableHash(_ string: String) -> UInt64 {
        string.unicodeScalars.reduce(5381) { ($0 &* 33) &+ UInt64($1.value) }
    }

    private static func dynamic(light: UInt32, dark: UInt32, lightHC: UInt32? = nil, darkHC: UInt32? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let isHigh = traits.accessibilityContrast == .high
            let hex = switch (isDark, isHigh) {
            case (false, false): light
            case (true, false): dark
            case (false, true): lightHC ?? light
            case (true, true): darkHC ?? dark
            }
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}

extension Font {
    /// Rounded, heavy display type for headings. Scales with Dynamic Type.
    static func display(_ style: Font.TextStyle, weight: Font.Weight = .bold) -> Font {
        .system(style, design: .rounded, weight: weight)
    }
}
