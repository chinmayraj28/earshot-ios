import EarshotKit
import SwiftUI

/// Message text with its formatting drawn: *bold*, _italic_, ~struck~, `code`, and
/// tappable links. The rules live in `MessageFormatting` (EarshotKit); this only draws them.
///
/// Links: tapping one is the only way it opens, and only `http`, `https`, `mailto` and
/// `tel` links are ever handed to iOS. Earshot never loads a link itself and never shows
/// previews, so it makes no network requests.
struct FormattedText: View {
    let text: String
    let isOutgoing: Bool

    var body: some View {
        Text(Self.attributed(text))
            .tint(isOutgoing ? Palette.linkOnOutgoing : Palette.linkOnIncoming)
            .environment(\.openURL, OpenURLAction { url in
                MessageFormatting.isOpenable(url) ? .systemAction : .discarded
            })
    }

    /// Builds the styled string. Markers that took effect are already removed by the parser.
    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for run in MessageFormatting.runs(for: text) {
            var piece = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if run.style.contains(.italic) { intent.insert(.emphasized) }
            if run.style.contains(.strikethrough) { intent.insert(.strikethrough) }
            if run.style.contains(.code) { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if let link = run.link {
                piece.link = link
                piece.underlineStyle = .single
            }
            result += piece
        }
        return result
    }
}

extension MessageFormatting {
    /// How a link is named in menus and to VoiceOver: "example.com", "sam@example.org", "+44 20 7946 0958".
    static func label(for url: URL, in text: String) -> String {
        if let run = runs(for: text).first(where: { $0.link == url }) { return run.text }
        return url.absoluteString
    }
}
