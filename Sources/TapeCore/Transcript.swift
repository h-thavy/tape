import Foundation

/// A transcript as Gemini writes it: one line per turn, `[MM:SS] Speaker 1: what was said`.
public struct Transcript: Equatable {
    public struct Line: Equatable, Identifiable {
        public let id: Int
        /// Seconds into the recording (nil for a line without a time).
        public let time: Double?
        public let stamp: String?
        public let speaker: String?
        public let text: String
    }

    /// Someone talking without interruption, from `start` to `end` (seconds).
    public struct Turn: Equatable {
        public let speaker: Int
        public let start: Double
        public let end: Double
    }

    public let lines: [Line]
    /// The speakers, most talk time first.
    public let speakers: [String]
    public let turns: [Turn]

    /// `duration` is the recording's length (the last turn runs to it).
    public init(_ text: String, duration: Double) {
        let pattern = try! NSRegularExpression(pattern: #"^\[((?:\d+:)?\d{1,2}:\d{2})\]\s*(?:([^:\[\]]{1,40}):\s+)?(.*)$"#)
        var lines: [Line] = []
        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else {
                lines.append(Line(id: index, time: nil, stamp: nil, speaker: nil, text: line))
                continue
            }
            func group(_ i: Int) -> String? { Range(match.range(at: i), in: line).map { String(line[$0]) } }
            let stamp = group(1) ?? ""
            lines.append(Line(id: index, time: Self.seconds(stamp), stamp: stamp,
                              speaker: group(2)?.trimmingCharacters(in: .whitespaces), text: group(3) ?? ""))
        }
        self.lines = lines

        // Timed lines in order, each running until the next one starts.
        let timed = lines.filter { $0.time != nil }
        let end = max(duration, timed.last?.time ?? 0)
        var spans: [(speaker: String, start: Double, end: Double)] = []
        for (i, line) in timed.enumerated() {
            let start = line.time!
            let next = i + 1 < timed.count ? timed[i + 1].time! : end
            guard next > start else { continue }
            let speaker = line.speaker ?? "Speaker"
            if let last = spans.last, last.speaker == speaker, abs(last.end - start) < 0.5 {
                spans[spans.count - 1].end = next
            } else {
                spans.append((speaker, start, next))
            }
        }
        var talk: [String: Double] = [:]
        for span in spans { talk[span.speaker, default: 0] += span.end - span.start }
        let speakers = talk.keys.sorted { talk[$0]! != talk[$1]! ? talk[$0]! > talk[$1]! : $0 < $1 }
        self.speakers = speakers
        turns = spans.map { Turn(speaker: speakers.firstIndex(of: $0.speaker)!, start: $0.start, end: $0.end) }
    }

    /// The transcript with every line's time moved `offset` seconds later (a part of a long recording put
    /// back on the whole recording's clock).
    public static func shifted(_ text: String, by offset: Double) -> String {
        guard offset > 0 else { return text }
        let pattern = try! NSRegularExpression(pattern: #"^(\s*)\[((?:\d+:)?\d{1,2}:\d{2})\]"#)
        return text.components(separatedBy: "\n").map { line in
            guard let match = pattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let stampRange = Range(match.range(at: 2), in: line), let whole = Range(match.range, in: line),
                  let lead = Range(match.range(at: 1), in: line), let seconds = seconds(String(line[stampRange])) else { return line }
            return String(line[lead]) + "[" + stamp(seconds + offset) + "]" + line[whole.upperBound...]
        }.joined(separator: "\n")
    }

    /// A part's transcript without what isn't transcript: an introduction ("This is a word-for-word
    /// transcript…"), the model reasoning about who is who, and notes in brackets about the speakers. Every
    /// transcript line starts with its time, so lines that don't are dropped.
    public static func cleanedPart(_ text: String) -> String {
        let timed = try! NSRegularExpression(pattern: #"^\s*\[(?:\d+:)?\d{1,2}:\d{2}\]"#)
        let note = try! NSRegularExpression(pattern: #"\s*\((?:This is|Note|Speaker \d+ (?:is|continu))[^)]*\)"#, options: .caseInsensitive)
        return text.components(separatedBy: "\n").compactMap { line in
            guard timed.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { return nil }
            return note.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
        }.joined(separator: "\n\n")
    }

    /// Seconds → "MM:SS", or "H:MM:SS" from the first hour on.
    public static func stamp(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "1:02:03" or "02:03" → seconds.
    public static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }
}
