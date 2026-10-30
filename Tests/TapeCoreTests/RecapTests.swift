import XCTest
@testable import TapeCore

final class RecapTests: XCTestCase {
    func testTitleFromHeading() {
        XCTAssertEqual(RecapFormat.title(of: "# \"Pricing review\" — Meeting Recap\n\nSource: …"), "Pricing review")
        XCTAssertEqual(RecapFormat.title(of: "\n# Payroll and invoices — Meeting Recap"), "Payroll and invoices")
        XCTAssertEqual(RecapFormat.title(of: "# Weekly sync"), "Weekly sync")
        XCTAssertNil(RecapFormat.title(of: "No heading here"))
    }

    func testMarkdownBlocks() {
        let recap = """
            # "Sync" — Meeting Recap

            Source: recording "x" (~5 min).
            Second line of the same paragraph.

            ## 1. Payroll

            - **Bug:** fields clear on save.
              It's still unresolved.
            - Plain point
              - Nested point
            1. First
            ---
            """
        XCTAssertEqual(MarkdownBlock.parse(recap), [
            .heading(level: 1, text: "\"Sync\" — Meeting Recap"),
            .paragraph("Source: recording \"x\" (~5 min). Second line of the same paragraph."),
            .heading(level: 2, text: "1. Payroll"),
            .bullet(depth: 0, text: "**Bug:** fields clear on save. It's still unresolved."),
            .bullet(depth: 0, text: "Plain point"),
            .bullet(depth: 1, text: "Nested point"),
            .numbered(number: "1", text: "First"),
            .rule,
        ])
    }

    func testRecapRequestCarriesTheTranscript() {
        let request = RecapPrompts.recapRequest(recording: "2026-10-30 14.05 Zoom", date: "30 Oct 2026", seconds: 15,
                                                app: "Zoom", transcriptFile: "a.transcript.txt", transcript: "[00:01] សួស្តី hello")
        XCTAssertTrue(request.contains("Length: 15 s"))
        XCTAssertEqual(RecapPrompts.length(3300), "about 55 min")
        XCTAssertTrue(request.contains("<transcript>\n[00:01] សួស្តី hello\n</transcript>"))
    }
}
