import Foundation

/// A local-only, printable recap. User/model text is never interpreted as HTML or as a resource URL.
public enum RecapHTML {
    /// Unmodified CSS from sopenlaz0/skills, anthropic-pdf-style/assets/template.html.
    public static let stylesheet: String = {
        guard let url = Bundle.module.url(forResource: "Recap", withExtension: "css"),
              let css = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return css
    }()

    /// `css` and `fontCSS` are trusted application styles, never recording or model content.
    public static func render(markdown: String, title: String, date: String, duration: String,
                              app: String?, css: String = stylesheet, fontCSS: String = "",
                              topicTimes: [String: Double] = [:]) -> String {
        let split = RecapFormat.splitTopicTimes(markdown)
        let document = RecapDocument(split.recap).with(times: split.times).with(times: topicTimes)
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (RecapFormat.title(of: split.recap) ?? "Meeting recap") : title
        var body = ""
        if !document.intro.isEmpty { body += "<section>\(blocks(document.intro))</section>" }
        if !document.summary.isEmpty {
            body += "<section lang=\"km\"><h2>\(RecapDocument.summaryHeading)</h2>\(blocks(document.summary))</section>"
        }
        for section in document.sections {
            let name = section.number.map { $0 + ". " } ?? ""
            body += "<section><h2\(language(section.title))>\(inline(name + section.title))</h2>"
            if let time = section.time, time.isFinite, time >= 0 {
                body += "<p class=\"meta num\">At \(timestamp(time))</p>"
            }
            body += blocks(section.blocks) + "</section>"
        }
        let source = document.source.map { "<footer\(language($0))>Source: \(inline($0))</footer>" } ?? ""
        return """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src data:; img-src 'none'; base-uri 'none'; form-action 'none'">
        <title>\(escape(heading))</title>
        <style>\(css)\n\(fontCSS)</style>
        <style>
        /* Protect arbitrary recap text without changing the supplied template's visual tokens. */
        main { overflow-wrap: anywhere; }
        .facts { break-inside: avoid; }
        li { break-inside: auto; }
        </style></head><body>
        <table class="page"><thead><tr><td></td></tr></thead><tfoot><tr><td></td></tr></tfoot><tbody><tr><td>
        <main><header><div class="eyebrow">Tape · Meeting recap</div>
        <h1\(language(heading))>\(escape(heading))</h1><div class="meta">\(escape(date))</div></header>
        <div class="facts">\(fact("Duration", duration))\(fact("Recorded", date))\(fact("Call app", app ?? "Not specified"))</div>
        \(body)\(source)
        </main></td></tr></tbody></table>
        </body></html>
        """
    }

    /// A basename only, with enough UTF-8 headroom for the extension on common filesystems.
    public static func filename(for title: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var name = title.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.isEmpty { name = "Meeting recap" }
        while name.utf8.count > 220 { name.removeLast() }
        return name + ".pdf"
    }

    private static func fact(_ label: String, _ value: String) -> String {
        "<div class=\"fact\"><div class=\"k\">\(label)</div><div class=\"v\"\(language(value))>\(escape(value))</div></div>"
    }

    private static func blocks(_ blocks: [MarkdownBlock]) -> String {
        var result = ""
        var inList = false
        for block in blocks {
            if case .bullet = block {} else if inList { result += "</ul>"; inList = false }
            switch block {
            case .heading(let level, let text):
                let tag = level <= 2 ? "h2" : "h3"
                result += "<\(tag)\(language(text))>\(inline(text))</\(tag)>"
            case .bullet(_, let text):
                if !inList { result += "<ul>"; inList = true }
                result += "<li\(language(text))>\(inline(text))</li>"
            case .numbered(let number, let text):
                result += "<p\(language(text))>\(escape(number)). \(inline(text))</p>"
            case .paragraph(let text):
                result += "<p\(language(text))>\(inline(text))</p>"
            case .rule:
                result += "<hr>"
            }
        }
        if inList { result += "</ul>" }
        return result
    }

    /// Deliberately small inline subset. Links, images, HTML and unknown syntax stay literal text.
    private static func inline(_ text: String, depth: Int = 0) -> String {
        guard depth < 16 else { return escape(text) }
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let rest = text[cursor...]
            // CommonMark only escapes ASCII punctuation, not letters, digits, whitespace or Khmer.
            if rest.hasPrefix("\\"), text.index(after: cursor) < text.endIndex,
               isEscapable(text[text.index(after: cursor)]) {
                cursor = text.index(after: cursor)
                result += escape(String(text[cursor]))
                cursor = text.index(after: cursor)
                continue
            }
            var matched = false
            for (delimiter, tag) in [("`", "code"), ("**", "strong"), ("*", "em")] {
                guard rest.hasPrefix(delimiter) else { continue }
                let start = text.index(cursor, offsetBy: delimiter.count)
                guard let end = text.range(of: delimiter, range: start..<text.endIndex), end.lowerBound > start else { continue }
                let content = String(text[start..<end.lowerBound])
                result += "<\(tag)>" + (tag == "code" ? escape(content) : inline(content, depth: depth + 1)) + "</\(tag)>"
                cursor = end.upperBound
                matched = true
                break
            }
            if !matched {
                result += escape(String(text[cursor]))
                cursor = text.index(after: cursor)
            }
        }
        return result
    }

    private static func isEscapable(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return (0x21...0x2F).contains(scalar.value) || (0x3A...0x40).contains(scalar.value)
            || (0x5B...0x60).contains(scalar.value) || (0x7B...0x7E).contains(scalar.value)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func language(_ text: String) -> String {
        text.unicodeScalars.contains { (0x1780...0x17FF).contains($0.value) } ? " lang=\"km\"" : ""
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = Int(min(seconds.rounded(.down), Double(Int32.max)))
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
