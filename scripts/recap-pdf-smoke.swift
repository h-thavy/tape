import AppKit
import PDFKit
import TapeCore

// Minimal app adapters keep this test out of the real recording library and Keychain.
struct RecordingItem {
    var displayTitle: String
    var created: Date
    var duration: Double
    var app: String?
    var topicTimes: [String: Double]?
}
enum Recorder { static func duration(_ value: Double) -> String { "25 min" } }

@main
struct Smoke {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        let source = try String(contentsOfFile: args[1], encoding: .utf8)
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, markdown, fontCSS) in [
            ("sample", source, RecapPDFExporter.fontCSS()),
            ("fallback", source, ":root { --body: system-ui, sans-serif; --hero: Georgia, serif; }"),
            ("long", source + "\n\n## Long discussion\n\n" + (1...100).map { "- **Point \($0):** A long meeting needs readable pagination, complete text, and stable margins. " + String(repeating: "Follow up carefully. ", count: 5) }.joined(separator: "\n") + "\n\nEND-OF-RECAP", RecapPDFExporter.fontCSS())
        ] {
            let html = RecapHTML.render(markdown: markdown, title: "Clinic booking app review", date: "11 November 2026", duration: "25 min", app: "Google Meet", fontCSS: fontCSS)
            try html.write(to: output.appendingPathComponent(name + ".html"), atomically: true, encoding: .utf8)
            let data = try await RecapPDFExporter().render(html)
            try data.write(to: output.appendingPathComponent(name + ".pdf"))
            guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { fatalError("No pages") }
            let text = pdf.string ?? ""
            guard text.contains("Next steps"), text.contains("duplicate charge") else { fatalError("Lost recap content") }
            if name == "long" { precondition(pdf.pageCount > 2 && text.contains("END-OF-RECAP")) }
            for index in 0..<pdf.pageCount {
                let page = pdf.page(at: index)!
                let size = page.bounds(for: .mediaBox).size
                precondition(abs(size.width - 595.28) < 2 && abs(size.height - 841.89) < 2, "Not A4")
                if let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) {
                    let bounds = selection.bounds(for: page)
                    precondition(bounds.minY >= 35 && bounds.maxY <= size.height - 35, "Missing repeated page margins")
                }
                precondition(!(page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Blank page")
            }
            print("PASS \(name): \(pdf.pageCount) A4 pages, \(data.count) bytes; content complete")
        }
    }
}
