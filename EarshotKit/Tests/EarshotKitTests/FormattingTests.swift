import Foundation
import Testing
@testable import EarshotKit

@Suite struct FormattingTests {
    typealias Run = MessageFormatting.Run
    typealias Style = MessageFormatting.Style

    private func runs(_ text: String) -> [Run] { MessageFormatting.runs(for: text) }
    private func plain(_ text: String) -> Run { Run(text: text) }
    private func styled(_ text: String, _ style: Style) -> Run { Run(text: text, style: style) }
    private func link(_ text: String, _ url: String) -> Run { Run(text: text, link: URL(string: url)) }

    /// Runs must never be empty, never repeat the previous run's look, and must join up to `plainText`.
    private func checkInvariants(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let result = runs(text)
        #expect(result.allSatisfy { !$0.text.isEmpty }, sourceLocation: sourceLocation)
        for (a, b) in zip(result, result.dropFirst()) {
            #expect(a.style != b.style || a.link != b.link, "adjacent runs should merge", sourceLocation: sourceLocation)
        }
        #expect(result.map(\.text).joined() == MessageFormatting.plainText(text), sourceLocation: sourceLocation)
        #expect(result.allSatisfy { $0.link.map(MessageFormatting.isOpenable) ?? true }, sourceLocation: sourceLocation)
        #expect(result.allSatisfy { $0.link == nil || $0.style.isEmpty }, sourceLocation: sourceLocation)
    }

    // MARK: The example from the spec

    @Test func specExample() {
        let text = "see *you* at https://example.com/a_b ok_"
        #expect(runs(text) == [
            plain("see "),
            styled("you", .bold),
            plain(" at "),
            link("https://example.com/a_b", "https://example.com/a_b"),
            plain(" ok_"),
        ])
        #expect(MessageFormatting.plainText(text) == "see you at https://example.com/a_b ok_")
        checkInvariants(text)
    }

    // MARK: Basic styles

    @Test func eachStyle() {
        #expect(runs("*bold*") == [styled("bold", .bold)])
        #expect(runs("_it_") == [styled("it", .italic)])
        #expect(runs("~gone~") == [styled("gone", .strikethrough)])
        #expect(runs("`code`") == [styled("code", .code)])
        #expect(runs("a *b* c") == [plain("a "), styled("b", .bold), plain(" c")])
    }

    @Test func punctuationAroundMarkersIsFine() {
        #expect(runs("*bold*,") == [styled("bold", .bold), plain(",")])
        #expect(runs("(_it_)") == [plain("("), styled("it", .italic), plain(")")])
        #expect(runs("\"~x~\"!") == [plain("\""), styled("x", .strikethrough), plain("\"!")])
        #expect(runs("*multi word bold*.") == [styled("multi word bold", .bold), plain(".")])
    }

    @Test func markersInsideWordsStayLiteral() {
        for text in ["snake_case_name", "2*3*4", "a*b*c", "x~y~z", "file_name.txt", "don`t do`this"] {
            #expect(runs(text) == [plain(text)], "\(text)")
            checkInvariants(text)
        }
    }

    @Test func markersNextToSpacesStayLiteral() {
        for text in ["* not bold *", "*not bold *", "* not bold*", "_ x _", "~ ~", "` code `", "a * b * c"] {
            #expect(runs(text) == [plain(text)], "\(text)")
        }
    }

    @Test func doubledAndEmptyMarkersStayLiteral() {
        for text in ["**x**", "__x__", "~~x~~", "``x``", "**", "*", "_", "``", "***", "* *"] {
            #expect(runs(text) == [plain(text)], "\(text)")
            checkInvariants(text)
        }
        // A lone marker character between two others is ordinary content.
        #expect(runs("*_*") == [styled("_", .bold)])
    }

    @Test func unmatchedMarkersStayLiteral() {
        #expect(runs("*open only") == [plain("*open only")])
        #expect(runs("close only*") == [plain("close only*")])
        #expect(runs("ok_") == [plain("ok_")])
        #expect(runs("_a *b_") == [styled("a *b", .italic)])
    }

    @Test func stylesStayOnOneLine() {
        #expect(runs("*a\nb*") == [plain("*a\nb*")])
        #expect(runs("`a\nb`") == [plain("`a\nb`")])
        #expect(runs("*a*\n*b*") == [styled("a", .bold), plain("\n"), styled("b", .bold)])
        #expect(runs("_x\r\ny_") == [plain("_x\r\ny_")])
    }

    // MARK: Nesting and crossing

    @Test func properNestingWorks() {
        #expect(runs("*bold _both_*") == [styled("bold ", .bold), styled("both", [.bold, .italic])])
        #expect(runs("_~x~_") == [styled("x", [.italic, .strikethrough])])
        #expect(runs("*a ~b _c_ d~ e*") == [
            styled("a ", .bold), styled("b ", [.bold, .strikethrough]),
            styled("c", [.bold, .strikethrough, .italic]),
            styled(" d", [.bold, .strikethrough]), styled(" e", .bold),
        ])
    }

    @Test func crossingFallsBackToLiteralForTheInnerOne() {
        #expect(runs("*a _b* c_") == [styled("a _b", .bold), plain(" c_")])
        #expect(runs("_a *b_ c*") == [styled("a *b", .italic), plain(" c*")])
    }

    @Test func codeIsLiteralInside() {
        #expect(runs("`a *b* c`") == [styled("a *b* c", .code)])
        #expect(runs("`_x_` and *y*") == [styled("_x_", .code), plain(" and "), styled("y", .bold)])
        #expect(runs("*see `x` here*") == [styled("see ", .bold), styled("x", [.bold, .code]), styled(" here", .bold)])
        #expect(runs("`a` `b`") == [styled("a", .code), plain(" "), styled("b", .code)])
    }

    // MARK: Links

    @Test func linksAreNeverSplitByMarkers() {
        let url = "https://a.com/x_y_z"
        #expect(runs(url) == [link(url, url)])
        #expect(runs("_go to \(url) now_") == [plain("_go to "), link(url, url), plain(" now_")])
        // The detector decides where a link ends; a trailing marker it takes in stays part of the link.
        #expect(runs("_go to \(url)_").allSatisfy { $0.style.isEmpty })
        #expect(runs("*see* https://a.com/*b*") == [styled("see", .bold), plain(" "), link("https://a.com/*b*", "https://a.com/*b*")])
    }

    @Test func styleCannotSpanALink() {
        let result = runs("*a https://example.com b*")
        #expect(result.allSatisfy { $0.style.isEmpty })
        #expect(result.contains { $0.link?.absoluteString == "https://example.com" })
        #expect(MessageFormatting.plainText("*a https://example.com b*") == "*a https://example.com b*")
    }

    @Test func emailsBecomeMailto() {
        let result = runs("mail me@x.org")
        #expect(result == [plain("mail "), link("me@x.org", "mailto:me@x.org")])
        #expect(MessageFormatting.links(in: "mail me@x.org") == [URL(string: "mailto:me@x.org")!])
    }

    @Test func phoneNumbersBecomeTel() {
        let result = runs("call +44 20 7946 0958")
        #expect(result.last?.link == URL(string: "tel:+442079460958"))
        #expect(result.last?.text == "+44 20 7946 0958")
        #expect(result.first == plain("call "))
    }

    @Test func onlySafeSchemesAreLinks() {
        for text in ["javascript:alert(1)", "ftp://x.org", "file:///etc/passwd", "earshot://open", "data:text/html,hi"] {
            #expect(runs(text).allSatisfy { $0.link == nil }, "\(text)")
            #expect(MessageFormatting.links(in: text).isEmpty, "\(text)")
            #expect(MessageFormatting.plainText(text) == text)
        }
    }

    @Test func bareDomainsGetHttp() {
        let urls = MessageFormatting.links(in: "try example.com today")
        #expect(urls.count == 1)
        #expect(urls.first.map(MessageFormatting.isOpenable) == true)
    }

    @Test func severalLinksInOrder() {
        let text = "https://a.com and b@c.org then http://d.org/x"
        let urls = MessageFormatting.links(in: text).map(\.absoluteString)
        #expect(urls == ["https://a.com", "mailto:b@c.org", "http://d.org/x"])
        #expect(runs(text).filter { $0.link != nil }.map(\.text) == ["https://a.com", "b@c.org", "http://d.org/x"])
        checkInvariants(text)
    }

    @Test func openableSchemes() {
        for yes in ["http://a.com", "https://a.com", "HTTPS://A.COM", "mailto:a@b.c", "tel:+123", "Tel:123"] {
            #expect(MessageFormatting.isOpenable(URL(string: yes)!), "\(yes)")
        }
        for no in ["javascript:alert(1)", "file:///x", "sms:123", "data:text/plain,x", "earshot://x", "ftp://a.com", "facetime:1"] {
            #expect(!MessageFormatting.isOpenable(URL(string: no)!), "\(no)")
        }
    }

    // MARK: Unicode

    @Test func emojiAndFlags() {
        #expect(runs("*🎉 party 🇪🇺*") == [styled("🎉 party 🇪🇺", .bold)])
        #expect(runs("👨‍👩‍👧 _family_") == [plain("👨‍👩‍👧 "), styled("family", .italic)])
        #expect(runs("*👍🏽*") == [styled("👍🏽", .bold)])
        checkInvariants("🇪🇺*🇪🇺*🇪🇺")
    }

    @Test func rightToLeftText() {
        #expect(runs("مرحبا *عالم*") == [plain("مرحبا "), styled("عالم", .bold)])
        #expect(runs("שלום _עולם_ !") == [plain("שלום "), styled("עולם", .italic), plain(" !")])
        // Arabic letters glue markers to the word just like Latin ones.
        #expect(runs("كلمة_كلمة_كلمة") == [plain("كلمة_كلمة_كلمة")])
        checkInvariants("\u{202E}*abc*\u{202C}")
    }

    @Test func combiningMarks() {
        let e = "e\u{301}" // é as two scalars, one character
        #expect(runs("*caf\(e)*") == [styled("caf\(e)", .bold)])
        #expect(runs("\(e)*x*") == [plain("\(e)*x*")]) // a letter with an accent is still a letter
    }

    @Test func zeroWidthCharacters() {
        let zwsp = "\u{200B}", zwj = "\u{200D}", bom = "\u{FEFF}"
        for text in ["\(zwsp)*a*\(zwsp)", "*\(zwj)*", "a\(zwj)*b*", "\(bom)_x_", "*a\(zwsp)b*", String(repeating: zwsp + "*", count: 500)] {
            checkInvariants(text)
        }
        // A zero-width space is not a letter, so it works like punctuation around a marker.
        #expect(runs("\(zwsp)*a*") == [plain(zwsp), styled("a", .bold)])
    }

    @Test func emptyAndWhitespace() {
        #expect(runs("") == [])
        #expect(MessageFormatting.plainText("") == "")
        #expect(MessageFormatting.links(in: "").isEmpty)
        #expect(runs(" ") == [plain(" ")])
        #expect(runs("\n\n") == [plain("\n\n")])
    }

    // MARK: Hostile input

    private func timed(_ label: String, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            _ = MessageFormatting.runs(for: text)
            _ = MessageFormatting.plainText(text)
        }
        #expect(elapsed < .milliseconds(500), "\(label) took \(elapsed)", sourceLocation: sourceLocation)
        checkInvariants(text, sourceLocation: sourceLocation)
    }

    @Test func hostileInputIsFastAndSafe() {
        timed("2,000 stars", String(repeating: "*", count: 2000))
        timed("alternating markers", String(repeating: "*_~`", count: 500))
        timed("unclosed openers", String(repeating: "*a ", count: 500))
        timed("unclosed code", String(repeating: "`a ", count: 1000))
        let depth = 300
        let opens = String(repeating: "*_~", count: depth)
        timed("deeply interleaved", opens + "a" + String(opens.reversed()))
        timed("interleaved words", String(repeating: "*a _b ~c `d* e_ f~ g` ", count: 200))
        var mixed = ""
        let pieces = ["*", "_", "~", "`", " ", "a", "é", "🎉", "\n", "x.com", "\u{200B}", "ش", "1", "(", "@"]
        var seed: UInt64 = 42
        var length = 0
        while length < 10_000 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let piece = pieces[Int(seed >> 33) % pieces.count]
            mixed += piece
            length += piece.count
        }
        timed("10,000 mixed characters", mixed)
        timed("many links", String(repeating: "https://a.com/_x_ ", count: 300))
        timed("2,000 backticks", String(repeating: "`", count: 2000))
        timed("long styled", "*" + String(repeating: "word ", count: 2000) + "end*")
    }

    @Test func deeplyInterleavedKeepsEveryCharacter() {
        let opens = String(repeating: "*_~", count: 50)
        let text = opens + "a" + String(opens.reversed())
        let shown = MessageFormatting.plainText(text)
        // Only correctly paired markers disappear; nothing else is lost or invented.
        #expect(shown.contains("a"))
        #expect(shown.count <= text.count)
        #expect(shown.filter { $0 == "a" }.count == 1)
    }

    @Test func plainTextKeepsUnusedMarkers() {
        #expect(MessageFormatting.plainText("snake_case and *bold*") == "snake_case and bold")
        #expect(MessageFormatting.plainText("`*x*`") == "*x*")
    }
}
