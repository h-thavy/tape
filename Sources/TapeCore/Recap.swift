import Foundation

/// What Tape asks Gemini (the transcript) and Claude (the recap).
public enum RecapPrompts {
    /// For Gemini, with the recording attached. Khmer stays in Khmer script and English in English, as spoken.
    public static let transcription = """
        Transcribe this meeting recording word for word.

        The people often switch between Khmer and English, sometimes in the same sentence, and other languages \
        may come up. Write every word in the language it was spoken: Khmer in Khmer script (not romanised and \
        not translated), English in English. Keep names, product names, technical terms and numbers exactly as \
        said.

        Start a new line whenever the speaker changes or after a long pause, and begin each line with its time \
        in the recording as [MM:SS] (or [H:MM:SS] after the first hour). When you can tell the voices apart, put \
        a label after the time: "Speaker 1:", "Speaker 2:" and so on. Use a person's name instead only when it's \
        clear (they introduce themselves, or someone addresses them). Write [inaudible] for words you can't make \
        out.

        Don't summarise, shorten or skip anything (small talk included), and don't add comments. Reply with the \
        transcript only.
        """

    /// For one part of a long recording (sent in parts: Gemini fails on long audio in one go). Times are
    /// written from the start of the part and moved onto the whole recording's clock afterwards.
    public static func transcription(part: Int, of count: Int, previous: String?) -> String {
        var text = transcription + """


            This is part \(part) of \(count) of a longer recording. Write the times from the start of this part \
            ([00:00] is where this part begins). Reply with transcript lines only, each starting with its time: \
            no introduction, notes or comments.
            """
        if let previous, !previous.isEmpty {
            text += """


                The previous part ended like this. Use the same speaker labels for the same voices, without \
                explaining or discussing the labels, and don't repeat these lines:
                <previous>
                \(previous)
                </previous>
                """
        }
        return text
    }

    /// For Claude: the recap's shape and the rules for writing it.
    public static let recapSystem = """
        You turn meeting transcripts into recaps, for the people who were in the meeting and for colleagues who \
        missed it and need to act on it.

        The transcript was made by a speech model listening to a recording of the call. The people often switch \
        between Khmer and English mid-sentence (sometimes other languages too), and the transcript keeps each \
        word in the language it was spoken. Names are often garbled, and speakers may be unlabelled or \
        mislabelled: when a name isn't reliable, refer to people by their role in the meeting (the boss, a \
        developer, the client, the designer) and never guess a name.

        Write the recap in English, in Markdown, in exactly this shape:

        # <A short title saying what the meeting was about> — Meeting Recap

        Source: recording "<recording name>" (~<length, e.g. 55 min>, <languages heard, e.g. Khmer with English terms>). \
        Transcript: `<transcript file name>`. <One sentence on how reliable names and speaker labels are, and so \
        how people are referred to.>

        <One short paragraph: what kind of meeting this was, who was in it (by role), and the topics, in the order \
        they came up. If the recording's name doesn't match what was discussed, say so.>

        ## 1. <First topic>
        <!-- at <MM:SS where this topic starts in the transcript> -->

        - **<Lead-in>:** <what was said, decided or asked, and why>

        ## 2. <Next topic>
        <!-- at <MM:SS> -->

        …

        ## Next steps

        - <Owner (role or name)>: <action>

        How to write it:
        - Right under each numbered heading, put the time where that topic starts, taken from the \
        transcript's timestamps, as an HTML comment: `<!-- at 17:28 -->` (`<!-- at 1:02:10 -->` after the first \
        hour). It's hidden when the Markdown is shown; the app uses it to link the topic to the recording.
        - One numbered section per real topic, in the order discussed. Put small leftover items in a last \
        section called "Other".
        - Start each bullet with a short bold lead-in naming the point ("**Decision:**", "**Payroll bug:**", \
        "**Pending:**"), then plain, specific sentences. A discussion that doesn't break into points can be a \
        short paragraph instead.
        - Keep what someone acting on this needs: decisions and the reasons given, requirements with their \
        details (fields, numbers, prices, dates, versions), problems and their status, disagreements, deadlines \
        and open questions. Say clearly when something is unresolved, pending or parked.
        - Quote someone only when the exact words matter (a verdict, a commitment), translated into English.
        - Translate Khmer into natural English. Keep product names, technical terms and English phrases as said.
        - Don't add anything that wasn't said. If part of the audio was unclear, say so briefly instead of \
        guessing.
        - No filler, no praise for the meeting and no closing summary. Reply with the Markdown recap only.
        """

    /// The request for one recording.
    public static func recapRequest(recording name: String, date: String, seconds: Double, app: String?,
                                    transcriptFile: String, transcript: String) -> String {
        """
        Recording: "\(name)"
        Date: \(date)
        Length: \(length(seconds))
        Call app: \(app ?? "unknown")
        Transcript file: \(transcriptFile)

        <transcript>
        \(transcript)
        </transcript>
        """
    }
}

extension RecapPrompts {
    /// "about 55 min", "40 s".
    static func length(_ seconds: Double) -> String {
        seconds < 60 ? "\(max(1, Int(seconds.rounded()))) s" : "about \(Int((seconds / 60).rounded())) min"
    }
}

public enum RecapFormat {
    /// The meeting's subject from the recap's first heading: `# "Pricing review" — Meeting Recap` → `Pricing review`.
    public static func title(of recap: String) -> String? {
        guard let line = recap.split(separator: "\n", omittingEmptySubsequences: true)
            .first(where: { $0.hasPrefix("# ") }) else { return nil }
        var title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        for suffix in [" — Meeting Recap", " - Meeting Recap", " – Meeting Recap", " — Meeting recap", ": Meeting Recap"]
        where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”' ").union(.whitespaces))
        return title.isEmpty ? nil : title
    }
}

/// The few kinds of Markdown block a recap uses, for showing it in the app.
public enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case bullet(depth: Int, text: String)
    case numbered(number: String, text: String)
    case paragraph(String)
    case rule

    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for raw in markdown.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                if level <= 6, line.dropFirst(level).first == " " {
                    flush()
                    blocks.append(.heading(level: level, text: String(line.dropFirst(level + 1))))
                    continue
                }
            }
            if line == "---" || line == "***" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(depth: indent / 2, text: String(line.dropFirst(2))))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].first == " " {
                flush()
                blocks.append(.numbered(number: String(line[..<dot]), text: String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            // A line continuing the bullet above it.
            if indent >= 2, case .bullet(let depth, let text)? = blocks.last, paragraph.isEmpty {
                blocks[blocks.count - 1] = .bullet(depth: depth, text: text + " " + line)
                continue
            }
            paragraph.append(line)
        }
        flush()
        return blocks
    }
}

/// A recap split the way the app shows it: the source line, the opening paragraphs, then each topic with its
/// number and where it starts in the recording.
public struct RecapDocument: Equatable {
    public struct Section: Equatable {
        /// "1" for "## 1. Pricing"; nil for an unnumbered one ("Next steps").
        public let number: String?
        public let title: String
        /// From the `<!-- at 12:34 -->` line under the heading.
        public let time: Double?
        public let blocks: [MarkdownBlock]
    }

    public let title: String?
    /// The "Source: …" line.
    public let source: String?
    public let intro: [MarkdownBlock]
    public let sections: [Section]

    public init(_ markdown: String) {
        let marker = try! NSRegularExpression(pattern: #"^<!--\s*at\s+((?:\d+:)?\d{1,2}:\d{2})\s*-->$"#)
        var title: String?
        var source: String?
        var intro: [MarkdownBlock] = []
        var sections: [Section] = []
        var current: (number: String?, title: String, time: Double?, blocks: [MarkdownBlock])?
        func close() {
            if let current { sections.append(Section(number: current.number, title: current.title, time: current.time, blocks: current.blocks)) }
            current = nil
        }
        for block in MarkdownBlock.parse(markdown) {
            switch block {
            case .heading(1, let text) where title == nil && current == nil && intro.isEmpty:
                title = text
            case .heading(let level, let text) where level <= 2:
                close()
                if let dot = text.firstIndex(of: "."), !text[..<dot].isEmpty, text[..<dot].allSatisfy(\.isNumber) {
                    current = (String(text[..<dot]), text[text.index(after: dot)...].trimmingCharacters(in: .whitespaces), nil, [])
                } else {
                    current = (nil, text, nil, [])
                }
            case .paragraph(let text) where text.hasPrefix("<!--"):
                // The topic's time (hidden when the Markdown is shown elsewhere).
                if let match = marker.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                   let range = Range(match.range(at: 1), in: text), current != nil, current?.time == nil {
                    current?.time = Transcript.seconds(String(text[range]))
                }
            case .paragraph(let text) where current == nil && source == nil && text.hasPrefix("Source:"):
                source = String(text.dropFirst("Source:".count)).trimmingCharacters(in: .whitespaces)
            default:
                if current != nil { current?.blocks.append(block) } else { intro.append(block) }
            }
        }
        close()
        self.title = title
        self.source = source
        self.intro = intro
        self.sections = sections
    }
}
