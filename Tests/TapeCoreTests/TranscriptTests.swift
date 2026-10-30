import XCTest
@testable import TapeCore

final class TranscriptTests: XCTestCase {
    func testTurnsMergeAndRankSpeakers() {
        let text = """
            [00:00] Speaker 1: សួស្តី everyone
            [00:05] Speaker 1: let's start
            [00:10] Speaker 2: OK
            [00:12] Speaker 1: the payroll bug
            [1:00:00] Speaker 3: bye
            a line without a time
            """
        let t = Transcript(text, duration: 3610)
        XCTAssertEqual(t.lines.count, 6)
        XCTAssertEqual(t.lines[0].text, "សួស្តី everyone")
        XCTAssertNil(t.lines[5].time)
        // Speaker 1 talks the most (10 s + 3588 s), then Speaker 3 (10 s), then Speaker 2 (2 s).
        XCTAssertEqual(t.speakers, ["Speaker 1", "Speaker 3", "Speaker 2"])
        XCTAssertEqual(t.turns, [
            .init(speaker: 0, start: 0, end: 10),
            .init(speaker: 2, start: 10, end: 12),
            .init(speaker: 0, start: 12, end: 3600),
            .init(speaker: 1, start: 3600, end: 3610),
        ])
    }

    func testUnlabelledTranscriptIsOneSpeaker() {
        let t = Transcript("[00:00] hello\n[00:30] still me", duration: 40)
        XCTAssertEqual(t.speakers, ["Speaker"])
        XCTAssertEqual(t.turns, [.init(speaker: 0, start: 0, end: 40)])
    }

    func testRecapDocumentSections() {
        let recap = """
            # Pricing review — Meeting Recap

            Source: recording "x" (~55 min). Names are unreliable.

            A planning meeting.

            ## 1. Candidate app
            <!-- at 00:40 -->

            - **Privacy:** hidden contacts.

            ## 2. Payroll
            <!-- at 1:02:03 -->
            - **Bug:** fields clear.

            ## Next steps

            - Dev: fix it
            """
        let doc = RecapDocument(recap)
        XCTAssertEqual(doc.title, "Pricing review — Meeting Recap")
        XCTAssertEqual(doc.source, "recording \"x\" (~55 min). Names are unreliable.")
        XCTAssertEqual(doc.intro, [.paragraph("A planning meeting.")])
        XCTAssertEqual(doc.sections.map(\.number), ["1", "2", nil])
        XCTAssertEqual(doc.sections.map(\.title), ["Candidate app", "Payroll", "Next steps"])
        XCTAssertEqual(doc.sections.map(\.time), [40, 3723, nil])
        XCTAssertEqual(doc.sections[1].blocks, [.bullet(depth: 0, text: "**Bug:** fields clear.")])
    }

    func testOldRecapWithoutTimes() {
        let doc = RecapDocument("# T\n\nIntro.\n\n## 1. A\n\n- x\n")
        XCTAssertEqual(doc.sections.count, 1)
        XCTAssertNil(doc.sections[0].time)
        XCTAssertNil(doc.source)
    }
}

final class TranscriptPartsTests: XCTestCase {
    func testShiftOntoTheWholeRecording() {
        let part = "[00:05] Speaker 1: hi\nno time here\n[09:59] Speaker 2: [inaudible] ok"
        XCTAssertEqual(Transcript.shifted(part, by: 3600),
                       "[1:00:05] Speaker 1: hi\nno time here\n[1:09:59] Speaker 2: [inaudible] ok")
        XCTAssertEqual(Transcript.shifted(part, by: 0), part)
    }

    func testPartPromptCarriesThePreviousLines() {
        let prompt = RecapPrompts.transcription(part: 2, of: 4, previous: "[09:58] Speaker 1: bye")
        XCTAssertTrue(prompt.hasPrefix(RecapPrompts.transcription))
        XCTAssertTrue(prompt.contains("part 2 of 4"))
        XCTAssertTrue(prompt.contains("<previous>\n[09:58] Speaker 1: bye\n</previous>"))
        XCTAssertFalse(RecapPrompts.transcription(part: 1, of: 4, previous: nil).contains("<previous>"))
    }
}

final class TranscriptCleaningTests: XCTestCase {
    func testPartKeepsOnlyTranscriptLines() {
        let part = """
            This is a word-for-word transcript of the recording:
            Woman's voice: `Speaker 3`.
            Wait, let's listen to [00:00] onwards!

            [00:00] Speaker 1: of customer, of patient ដែលគាត់អញ្ជើញមកនេះ... (This is Speaker 1 continuing!)

            [00:04] Speaker 3: OK (inaudible) ចា៎
            """
        XCTAssertEqual(Transcript.cleanedPart(part),
                       "[00:00] Speaker 1: of customer, of patient ដែលគាត់អញ្ជើញមកនេះ...\n\n[00:04] Speaker 3: OK (inaudible) ចា៎")
    }
}
