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

    /// For Claude: the recap's shape and the rules for writing it, with an example in the same shape (an
    /// invented meeting, so nothing real is in the app).
    public static let recapSystem = """
        You turn meeting transcripts into recaps, for the people who were in the meeting and for colleagues who \
        missed it and need to act on it.

        The transcript was made by a speech model listening to a recording of the call. The people often switch \
        between Khmer and English mid-sentence (sometimes other languages too), and the transcript keeps each \
        word in the language it was spoken. Names are often garbled, and speakers may be unlabelled or \
        mislabelled: when a name isn't reliable, refer to people by their role in the meeting (the boss, a \
        developer, the client, the designer) and never guess a name.

        Write the recap in English, in Markdown, in exactly this shape:

        # "<title>" — Meeting Recap

        Source: recording "<recording name>" (~<length, e.g. 55 min>, <languages heard, e.g. Khmer with English \
        terms>). Transcript: `<transcript file name>`. <One short sentence on how reliable names and speaker \
        labels are, and so how people are referred to.>

        <One paragraph of two to four sentences: what kind of meeting this was and who was in it, by role, \
        ending with "Topics: <topic>, <topic> and <topic>." in the order they came up. If the recording's name \
        doesn't match what was discussed, say so first.>

        ## 1. <Topic>

        - **<Lead-in>:** <what was said, decided or asked, and why>

        ## 2. <Topic>

        …

        ## <N>. Other

        - <small items>

        ## Next steps

        - <Owner>: <action>, <action>.

        The title is the recording's name when the request says it's a real name; otherwise a short title for \
        what the meeting was about.

        How to write it:
        - Group the discussion into a few real topics, usually 3 to 6 plus "Other", not a section for every \
        turn of the conversation. One topic can hold several related threads (payroll, invoices and the \
        exchange rate together under accounting).
        - Each topic is a flat list of bullets: never indent a bullet under another, and no numbered steps \
        inside a topic. When a point has several parts, write them in one bullet or as separate bullets. Start a \
        bullet with a short bold lead-in naming the point ("**Decision:**", "**Payroll bug:**", \
        "**Pending:**", "**Boss's verdict:**") when it helps, then plain, specific sentences. A topic that is \
        one discussion can open with a sentence or two before its bullets.
        - Keep what someone acting on this needs: decisions and the reasons given, requirements with their \
        details (fields, numbers, prices, dates, versions), problems and their status, who will do what, \
        deadlines and open questions. Say plainly when something is unresolved, pending or parked.
        - Be direct: state what was said ("The boss said to make those fields optional."), not how it was \
        transcribed. Don't hedge with "apparently", "presumably" or "it seems"; if something really is unclear, \
        say so once, briefly.
        - Quote someone only when the exact words matter (a verdict, a commitment), translated into English.
        - Translate Khmer into natural English. Keep product names, technical terms and English phrases as said.
        - Next steps: one bullet per owner, their actions joined on one line. Use roles when names aren't \
        reliable.
        - The length follows the meeting: a few lines for a short check-in, about 500 words for half an hour \
        and 800 for an hour of dense discussion. Leave out what nobody needs to act on or remember (greetings, \
        small talk, repeated points). No filler, no praise for the meeting and no closing summary. Don't add \
        anything that wasn't said.

        After the recap, on a last line of its own, write where each numbered topic starts in the transcript, \
        from its timestamps: `[topic times] 1=MM:SS, 2=MM:SS, …` (H:MM:SS after the first hour). The app reads \
        that line and takes it out of the recap.

        An example of the shape, length and tone, for an invented meeting:

        <example>
        # "Clinic booking app review" — Meeting Recap

        Source: recording "Clinic booking app review" (~25 min, Khmer with English terms). Transcript: \
        `Clinic booking app review.transcript.txt`. Speakers are not labelled reliably, so attribution is by role.

        A weekly review between the product owner and two developers of a clinic's booking app, with the \
        clinic's manager joining for the last part. Topics: the booking flow, payments and the staff \
        dashboard, and the clinic's logo.

        ## 1. Booking flow

        - **Slots:** patients pick a doctor, then a 15-minute slot. Fully booked days are greyed out.
        - **Change from last week:** a patient can book for a family member, with that person's name and phone \
        number.
        - **Decision:** no account is needed to book, only a phone number and an SMS code. The manager's \
        reason: older patients give up at sign-up screens.
        - **Pending:** reminders by Telegram as well as SMS were parked until after launch.

        ## 2. Payments and the staff dashboard

        - **Deposit:** a 5 USD deposit through KHQR, refunded when the patient cancels 24 hours ahead.
        - **Payment bug:** the deposit is sometimes charged twice when the patient taps Pay again on a slow \
        connection. Still unresolved; a developer is adding a lock on the button and checking the bank's \
        callback.
        - **Dashboard:** reception sees today's bookings by doctor and can mark no-shows. The manager asked \
        for a daily total of deposits, in USD and KHR.
        - **Manager's verdict:** "If the double charge is fixed, we can open it to patients."

        ## 3. Other

        - The clinic's logo on the booking page is low resolution; the manager will send a new one.

        ## Next steps

        - Developers: fix the double charge, add the daily deposit total, use the new logo.
        - Product owner: set the launch date once the payment fix is tested.
        - Manager: send the logo.

        [topic times] 1=00:12, 2=09:40, 3=22:05
        </example>

        Reply with the Markdown recap and its topic times line only.
        """

    /// The request for one recording. `named`: the recording's name is a real name (given by a person, or the
    /// meeting's title), not just the call app and the time.
    public static func recapRequest(recording name: String, named: Bool = false, date: String, seconds: Double, app: String?,
                                    transcriptFile: String, transcript: String) -> String {
        """
        Recording: "\(name)" (\(named ? "a real name: use it as the title" : "not a real name, only the call app and time: title the recap after what was discussed"))
        Date: \(date)
        Length: \(length(seconds)); keep the recap under \(wordBudget(seconds)) words, the topic times line not counted
        Call app: \(app ?? "unknown")
        Transcript file: \(transcriptFile)

        <transcript>
        \(transcript)
        </transcript>
        """
    }
}

extension RecapPrompts {
    /// About 20 words a minute of meeting (an hour's dense meeting in about 1,100), between 120 and 1,400.
    static func wordBudget(_ seconds: Double) -> Int {
        min(1400, max(120, Int((seconds / 60 * 20 / 50).rounded()) * 50))
    }

    /// "about 55 min", "40 s".
    static func length(_ seconds: Double) -> String {
        seconds < 60 ? "\(max(1, Int(seconds.rounded()))) s" : "about \(Int((seconds / 60).rounded())) min"
    }
}

public enum RecapFormat {
    /// Bullets indented under others moved up to the top level (a recap's topics are flat lists).
    public static func flattened(_ recap: String) -> String {
        recap.components(separatedBy: "\n").map { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.count < line.count, trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return line }
            return "- " + trimmed.dropFirst(2)
        }.joined(separator: "\n")
    }

    /// The recap without its `[topic times] 1=00:40, 2=17:28` line, and those times (topic number → seconds).
    public static func splitTopicTimes(_ recap: String) -> (recap: String, times: [String: Double]) {
        var lines = recap.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        guard let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("[topic times]") }) else {
            return (recap, [:])
        }
        let line = lines[index].trimmingCharacters(in: .whitespaces).dropFirst("[topic times]".count)
        var times: [String: Double] = [:]
        for part in line.split(separator: ",") {
            let pair = part.split(separator: "=").map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "`"))) }
            if pair.count == 2, !pair[0].isEmpty, let seconds = Transcript.seconds(pair[1]) { times[pair[0]] = seconds }
        }
        lines.remove(at: index)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return (lines.joined(separator: "\n"), times)
    }

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

    /// The same recap with topic times from elsewhere (the app keeps them beside the recap), for topics whose
    /// heading has none.
    public func with(times: [String: Double]) -> RecapDocument {
        var copy = self
        copy.sections = sections.map { section in
            Section(number: section.number, title: section.title,
                    time: section.time ?? section.number.flatMap { times[$0] }, blocks: section.blocks)
        }
        return copy
    }

    public let title: String?
    /// The "Source: …" line.
    public let source: String?
    public let intro: [MarkdownBlock]
    public private(set) var sections: [Section]

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
