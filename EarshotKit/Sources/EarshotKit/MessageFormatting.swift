import Foundation

/// Turns the raw text of a message into styled pieces for display.
///
/// Nothing here changes what is stored or sent: phones always exchange the raw text the
/// person typed, so every Earshot version can read every message. Formatting is only
/// drawn on screen, and only by phones that understand it.
///
/// **Links.** Web addresses, email addresses and phone numbers are found with Apple's
/// `NSDataDetector`. Only `http`, `https`, `mailto` and `tel` links are kept; anything else
/// (for example `javascript:` or `ftp:`) stays plain text. Text inside a link is never
/// treated as formatting, so `https://a.com/x_y_z` stays exactly as typed.
///
/// **Styles.** Wrap words in a marker:
///
/// | typed          | shown as            |
/// |----------------|---------------------|
/// | `*bold*`       | **bold**            |
/// | `_italic_`     | *italic*            |
/// | `~struck~`     | ~~struck~~          |
/// | `` `code` ``   | `code` (monospaced) |
///
/// The rules are deliberately strict, so ordinary text is never mangled:
/// - A marker opens only at the start of a word: the character before it is the start of
///   the text, a space or punctuation, and the character after it is not a space.
///   So `snake_case_name` and `2*3*4` stay as they are.
/// - A marker closes only at the end of a word: the character before it is not a space,
///   and the character after it is the end of the text, a space or punctuation.
/// - Doubled markers never count: `**x**` stays as typed.
/// - A style must open and close on the same line, and never across or around a link.
/// - Inside `` `code` `` everything is shown literally: `` `a *b* c` `` keeps its stars.
/// - Styles of different kinds may nest properly (`*bold _and italic_*`). If they cross
///   (`*a _b* c_`), the inner one is shown literally: bold "a _b", then " c_".
/// - Any marker that does not pair up is shown as typed.
///
/// Example: `see *you* at https://example.com/a_b ok_` shows "see ", "you" in bold,
/// " at ", a tappable link, and " ok_" exactly as typed.
///
/// The work is a few straight passes over the text, so even hostile input (thousands of
/// markers) takes time in proportion to its length.
public enum MessageFormatting {
    public struct Style: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let bold = Style(rawValue: 1 << 0)
        public static let italic = Style(rawValue: 1 << 1)
        public static let strikethrough = Style(rawValue: 1 << 2)
        public static let code = Style(rawValue: 1 << 3)
    }

    /// One piece of a message that is drawn the same way throughout.
    public struct Run: Equatable, Sendable {
        /// The characters to show (markers that took effect are already removed).
        public var text: String
        public var style: Style
        /// Set when this piece is a detected link. Always one of the openable schemes.
        public var link: URL?

        public init(text: String, style: Style = [], link: URL? = nil) {
            self.text = text
            self.style = style
            self.link = link
        }
    }

    /// The styled pieces of a message, in order. Concatenating `text` gives `plainText`.
    public static func runs(for text: String) -> [Run] {
        guard !text.isEmpty else { return [] }
        var parser = Parser(text)
        return parser.runs()
    }

    /// The message with the formatting markers that took effect removed (used for list
    /// previews and VoiceOver). `"see *you*"` becomes `"see you"`.
    public static func plainText(_ text: String) -> String {
        runs(for: text).map(\.text).joined()
    }

    /// Detected, openable links in order (http, https, mailto, tel only).
    public static func links(in text: String) -> [URL] {
        guard !text.isEmpty else { return [] }
        let characters = Array(text)
        return detectLinks(in: text, characters: characters).map(\.url)
    }

    /// True for the only schemes Earshot will ever open: http, https, mailto, tel (case-insensitive).
    public static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return openableSchemes.contains(scheme)
    }

    // MARK: - Links

    private static let openableSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    /// `NSDataDetector` is immutable and safe to use from any thread.
    private static let detector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue | NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    /// A link found in the text, as a range of character positions.
    fileprivate struct FoundLink {
        var start: Int
        var end: Int
        var url: URL
    }

    /// Finds links and converts their positions from UTF-16 offsets to character offsets.
    fileprivate static func detectLinks(in text: String, characters: [Character]) -> [FoundLink] {
        guard let detector else { return [] }
        let matches = detector.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return [] }
        // The index where each character starts, so a String.Index can be turned into a
        // character position by binary search.
        let starts = Array(text.indices)
        func offset(of index: String.Index) -> Int {
            var low = 0, high = starts.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] < index { low = mid + 1 } else { high = mid }
            }
            return low
        }

        var found: [FoundLink] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let start = offset(of: range.lowerBound)
            let end = offset(of: range.upperBound)
            guard start < end, end <= characters.count, start >= (found.last?.end ?? 0) else { continue }
            let url: URL?
            switch match.resultType {
            case .phoneNumber:
                url = match.phoneNumber.flatMap(telURL)
            case .link:
                url = match.url
            default:
                url = nil
            }
            guard let url, isOpenable(url) else { continue }
            found.append(FoundLink(start: start, end: end, url: url))
        }
        return found
    }

    /// `+44 20 7946 0958` becomes `tel:+442079460958`. Fewer than three digits is not a number.
    private static func telURL(_ number: String) -> URL? {
        let digits = number.filter { $0.isASCII && $0.isNumber }
        guard digits.count >= 3 else { return nil }
        let plus = number.trimmingCharacters(in: .whitespaces).hasPrefix("+") ? "+" : ""
        return URL(string: "tel:" + plus + digits)
    }

    // MARK: - Parser

    private struct Parser {
        let text: String
        let chars: [Character]
        let count: Int
        var styles: [Style]
        /// Markers that took effect and are not shown.
        var hidden: [Bool]
        /// Characters inside a code span: never markers for other styles.
        var literal: [Bool]
        /// Index into `found` for characters that belong to a link, otherwise -1.
        var linkIndex: [Int]
        var found: [FoundLink] = []

        init(_ text: String) {
            self.text = text
            chars = Array(text)
            count = chars.count
            styles = Array(repeating: [], count: count)
            hidden = Array(repeating: false, count: count)
            literal = Array(repeating: false, count: count)
            linkIndex = Array(repeating: -1, count: count)
        }

        mutating func runs() -> [Run] {
            found = MessageFormatting.detectLinks(in: text, characters: chars)
            for (index, link) in found.enumerated() {
                for position in link.start..<link.end { linkIndex[position] = index }
            }
            // Split into segments at newlines and links; a style never crosses one.
            var segmentStart = 0
            var position = 0
            while position < count {
                if linkIndex[position] >= 0 {
                    styleSegment(segmentStart, position)
                    position = found[linkIndex[position]].end
                    segmentStart = position
                } else if chars[position].isNewline {
                    styleSegment(segmentStart, position)
                    position += 1
                    segmentStart = position
                } else {
                    position += 1
                }
            }
            styleSegment(segmentStart, count)
            return buildRuns()
        }

        // MARK: Marker rules

        private static let markers: [Character: Style] = ["*": .bold, "_": .italic, "~": .strikethrough]

        /// Letters and digits glue a marker to a word; anything else is a boundary.
        private func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        private func canOpen(_ i: Int, end: Int) -> Bool {
            let marker = chars[i]
            if i > 0 {
                let previous = chars[i - 1]
                if previous == marker || isWordCharacter(previous) { return false }
            }
            guard i + 1 < end else { return false }
            let next = chars[i + 1]
            return !next.isWhitespace && next != marker
        }

        private func canClose(_ i: Int, start: Int) -> Bool {
            let marker = chars[i]
            guard i > start else { return false }
            let previous = chars[i - 1]
            if previous.isWhitespace || previous == marker { return false }
            if i + 1 < count {
                let next = chars[i + 1]
                if next == marker || isWordCharacter(next) { return false }
            }
            return true
        }

        // MARK: Segments

        private mutating func styleSegment(_ start: Int, _ end: Int) {
            guard end - start >= 3 else { return } // the shortest span is three characters: *x*
            markCode(start, end)
            markStyles(start, end)
        }

        /// Code spans first: their contents are shown literally.
        private mutating func markCode(_ start: Int, _ end: Int) {
            // nextCloser[k - start] = first position ≥ k holding a backtick that can close, or `end`.
            var nextCloser = Array(repeating: end, count: end - start + 1)
            var position = end - 1
            while position >= start {
                let isCloser = chars[position] == "`" && canClose(position, start: start)
                nextCloser[position - start] = isCloser ? position : nextCloser[position - start + 1]
                position -= 1
            }
            position = start
            while position < end {
                guard chars[position] == "`", canOpen(position, end: end) else {
                    position += 1
                    continue
                }
                let closer = nextCloser[position + 1 - start]
                guard closer < end, closer > position + 1 else {
                    position += 1
                    continue
                }
                hidden[position] = true
                hidden[closer] = true
                for inside in (position + 1)..<closer {
                    styles[inside].insert(.code)
                    literal[inside] = true
                }
                literal[position] = true
                literal[closer] = true
                position = closer + 1
            }
        }

        /// Bold, italic and strikethrough in one left-to-right pass. The stack holds at most
        /// one open marker of each kind, so it never grows past three entries.
        private mutating func markStyles(_ start: Int, _ end: Int) {
            var stack: [(position: Int, marker: Character)] = []
            for position in start..<end where !literal[position] {
                let c = chars[position]
                guard let style = Self.markers[c] else { continue }
                if let match = stack.lastIndex(where: { $0.marker == c }), canClose(position, start: start) {
                    let opener = stack[match].position
                    // Anything opened after it and still open crossed this span: show it literally.
                    stack.removeSubrange(match...)
                    hidden[opener] = true
                    hidden[position] = true
                    for inside in (opener + 1)..<position { styles[inside].insert(style) }
                } else if !stack.contains(where: { $0.marker == c }), canOpen(position, end: end) {
                    stack.append((position, c))
                }
            }
        }

        // MARK: Output

        private func buildRuns() -> [Run] {
            var runs: [Run] = []
            var current = ""
            var currentStyle: Style = []
            var currentLink = -1
            func flush() {
                guard !current.isEmpty else { return }
                runs.append(Run(text: current, style: currentStyle,
                                link: currentLink >= 0 ? found[currentLink].url : nil))
                current = ""
            }
            for position in 0..<count where !hidden[position] {
                let link = linkIndex[position]
                let style: Style = link >= 0 ? [] : styles[position]
                if style != currentStyle || link != currentLink {
                    flush()
                    currentStyle = style
                    currentLink = link
                }
                current.append(chars[position])
            }
            flush()
            return runs
        }
    }
}
