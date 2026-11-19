import XCTest
@testable import TapeCore

final class RecapHTMLTests: XCTestCase {
    private func html(_ markdown: String, title: String = "Weekly review") -> String {
        RecapHTML.render(markdown: markdown, title: title, date: "11 November 2026", duration: "32:45", app: "Google Meet")
    }

    func testRecapKeepsSummaryTopicsSourceAndFormatting() {
        let result = html("""
        # Original heading

        Source: recording `demo.wav`.

        Intro with **important** and *emphasis*.

        ## សង្ខេប
        - អ្នកគ្រប់គ្រង និង developer

        ## 1. Reports
        - **Decision:** Keep all reports.

        ## Next steps
        - Team: verify exports.

        [topic times] 1=01:20
        """)
        XCTAssertTrue(result.contains("<h1>Weekly review</h1>"))
        XCTAssertTrue(result.contains("<strong>important</strong>"))
        XCTAssertTrue(result.contains("<em>emphasis</em>"))
        XCTAssertTrue(result.contains("<section lang=\"km\"><h2>សង្ខេប</h2>"))
        XCTAssertTrue(result.contains("អ្នកគ្រប់គ្រង និង developer"))
        XCTAssertTrue(result.contains("<h2>1. Reports</h2>"))
        XCTAssertTrue(result.contains("At 1:20"))
        XCTAssertTrue(result.contains("Team: verify exports."))
        XCTAssertTrue(result.contains("Source: recording <code>demo.wav</code>."))
        XCTAssertFalse(result.contains("[topic times]"))
    }

    func testEscapesUntrustedContentWithoutLoadingResources() {
        let result = html("""
        <script>alert('x')</script>

        - ![picture](https://example.invalid/image)
        - [link](javascript:alert(1))
        - **<img src=x onerror=alert(1)>**
        - `</code><script>bad</script>`
        """, title: "</h1><iframe src='https://evil.invalid'>")
        XCTAssertFalse(result.contains("<script>"))
        XCTAssertFalse(result.contains("<iframe"))
        XCTAssertFalse(result.contains("<img"))
        XCTAssertFalse(result.contains("<a href"))
        XCTAssertTrue(result.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;"))
        XCTAssertTrue(result.contains("default-src 'none'"))
        XCTAssertTrue(result.contains("font-src data:"))
        XCTAssertTrue(result.contains("[link](javascript:alert(1))"))
    }

    func testPlainAndSummaryOnlyRecapsAreNotDropped() {
        XCTAssertTrue(html("A plain recap without sections.").contains("<p>A plain recap without sections.</p>"))
        XCTAssertTrue(html("## សង្ខេប\n\n- ចំណុចសំខាន់").contains("ចំណុចសំខាន់"))
        XCTAssertTrue(html("# \"Fallback\" — Meeting Recap\n\nBody", title: "  ").contains("<h1>Fallback</h1>"))
    }

    func testEmbeddedTopicTimeAndUnknownMarkdown() {
        let result = html("""
        ## 1. Topic
        <!-- at 1:02:03 -->
        7. Preserve this numbered step

        Unmatched **bold and `code remain.
        """)
        XCTAssertTrue(result.contains("At 1:02:03"))
        XCTAssertTrue(result.contains("7. Preserve this numbered step"))
        XCTAssertTrue(result.contains("Unmatched **bold and `code remain."))
        XCTAssertFalse(result.contains("<!-- at"))
    }

    func testSeparateTopicTimes() {
        let result = RecapHTML.render(markdown: "## 1. Topic\n\nContent", title: "Test", date: "Today",
                                      duration: "2:00", app: nil, topicTimes: ["1": 45])
        XCTAssertTrue(result.contains("At 0:45"))
    }

    func testBackslashesPreservePathsAndNonPunctuation() {
        let result = html(#"Paths C:\Users\Bob and D:\2026\recap. Keep \ក and \ space and final \"#)
        XCTAssertTrue(result.contains(#"C:\Users\Bob"#))
        XCTAssertTrue(result.contains(#"D:\2026\recap"#))
        XCTAssertTrue(result.contains(#"\ក and \ space and final \"#))
        XCTAssertTrue(html(#"Escape \*literal\* and \<tag\> and \\ slash."#)
            .contains("Escape *literal* and &lt;tag&gt; and \\ slash."))
        XCTAssertTrue(html(#"`C:\Users\Bob` and `\*literal\*`"#)
            .contains(#"<code>C:\Users\Bob</code> and <code>\*literal\*</code>"#))
    }

    func testSafeUnicodeFilenames() {
        XCTAssertEqual(RecapHTML.filename(for: " ../Review: Q4/next\\part\n "), "-Review- Q4-next-part-.pdf")
        XCTAssertEqual(RecapHTML.filename(for: " ... "), "Meeting recap.pdf")
        XCTAssertEqual(RecapHTML.filename(for: "សង្ខេប"), "សង្ខេប.pdf")
        let long = RecapHTML.filename(for: String(repeating: "ក", count: 500))
        XCTAssertLessThanOrEqual(long.utf8.count, 224)
        XCTAssertTrue(long.hasSuffix(".pdf"))
    }

    func testTemplateResourceAndRepeatedPageMargins() {
        XCTAssertTrue(RecapHTML.stylesheet.contains("--bg: #f9f9f7"))
        XCTAssertTrue(RecapHTML.stylesheet.contains("@page { size: A4; margin: 0; }"))
        XCTAssertTrue(RecapHTML.stylesheet.contains("font: 400 30pt/1.08 var(--hero)"))
        XCTAssertTrue(html("Body").contains("<table class=\"page\"><thead><tr><td></td></tr></thead><tfoot>"))
    }
}
