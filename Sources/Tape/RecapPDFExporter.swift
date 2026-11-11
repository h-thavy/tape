import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit
import TapeCore

/// Local-only export: WebKit prints the same A4 HTML used by the supplied report template.
@MainActor
final class RecapPDFExporter: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var isExporting = false
    @Published var error: String?
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Void, Error>?
    private var printContinuation: CheckedContinuation<Bool, Never>?

    func export(_ item: RecordingItem, markdown: String) {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export recap as PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = RecapHTML.filename(for: item.displayTitle)
        panel.canCreateDirectories = true
        panel.message = "Saves this recap locally. Installed Anthropic fonts are embedded; otherwise system fonts are used."
        isExporting = true
        panel.begin { [self] result in
            guard result == .OK, let url = panel.url else { isExporting = false; return }
            Task { @MainActor in
                defer { isExporting = false }
                do {
                    let html = RecapHTML.render(markdown: markdown, title: item.displayTitle,
                        date: item.created.formatted(date: .long, time: .shortened),
                        duration: Recorder.duration(item.duration), app: item.app ?? "Recording",
                        fontCSS: Self.fontCSS(), topicTimes: item.topicTimes ?? [:])
                    let data = try await render(html)
                    try data.write(to: url, options: .atomic)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    /// Kept separate from Save so native smoke tests can validate pagination and extracted text.
    func render(_ html: String) async throws -> Data {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123), configuration: configuration)
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        web.navigationDelegate = self
        webView = web
        let timeout = Task { @MainActor [weak self, weak web] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, let pending = self.continuation else { return }
            self.continuation = nil
            web?.stopLoading()
            pending.resume(throwing: ExportError.printFailed)
        }
        defer { timeout.cancel(); window.contentView = nil; web.navigationDelegate = nil; webView = nil }
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // WebKit does not repeat HTML table headers/footers when printing. Print page margins
            // provide the template's 16 mm breathing room on every page instead.
            let printHTML = html.replacingOccurrences(of: "</head>", with:
                "<style>@page { margin: 16mm 0; } table.page > thead > tr > td, table.page > tfoot > tr > td { height: 0; }</style></head>")
            web.loadHTMLString(printHTML, baseURL: nil)
        }
        // evaluateJavaScript is app-owned only; content scripting is disabled.
        _ = try await web.callAsyncJavaScript("await Promise.race([document.fonts.ready, new Promise((_, reject) => setTimeout(() => reject(new Error('Font loading timed out')), 15000))]);", arguments: [:], in: nil, contentWorld: .page)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 16 * 72 / 25.4; info.bottomMargin = 16 * 72 / 25.4; info.leftMargin = 0; info.rightMargin = 0
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporary
        let operation = web.printOperation(with: info)
        operation.canSpawnSeparateThread = true
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        // WebKit computes its page range asynchronously. run() can print an unbounded placeholder
        // range before those pages arrive; use the completion-based API even without a print panel.
        operation.view?.frame = web.bounds
        let succeeded = await withCheckedContinuation { continuation in
            printContinuation = continuation
            operation.runModal(for: window, delegate: self,
                didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
        }
        guard succeeded else { throw ExportError.printFailed }
        let data = try Data(contentsOf: temporary)
        guard let pdf = PDFDocument(data: data), pdf.pageCount > 0 else { throw ExportError.printFailed }
        return try withPageBackground(data)
    }

    /// Print margins have no paint. Fill behind each vector page so the warm page reaches every edge.
    private func withPageBackground(_ data: Data) throws -> Data {
        guard let provider = CGDataProvider(data: data as CFData), let source = CGPDFDocument(provider),
              let output = CFDataCreateMutable(nil, 0), let consumer = CGDataConsumer(data: output) else {
            throw ExportError.printFailed
        }
        var bounds = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw ExportError.printFailed }
        for index in 1...source.numberOfPages {
            guard let page = source.page(at: index) else { throw ExportError.printFailed }
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 249/255, green: 249/255, blue: 247/255, alpha: 1))
            context.fill(bounds)
            context.drawPDFPage(page)
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    @objc nonisolated private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                            contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            printContinuation?.resume(returning: success)
            printContinuation = nil
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume(); continuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        continuation?.resume(throwing: ExportError.printFailed); continuation = nil
    }

    /// Fonts remain on the user's Mac; no proprietary font binaries are distributed with Tape.
    static func fontCSS() -> String {
        let roots = [
            URL(fileURLWithPath: "/Applications/Claude.app/Contents/Resources/fonts"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Fonts")
        ]
        let faces = [("Anthropic Sans", "AnthropicSans-Romans-Variable-25x258.ttf", "normal"),
                     ("Anthropic Sans", "AnthropicSans-Italics-Variable-25x258.ttf", "italic"),
                     ("Anthropic Serif", "AnthropicSerif-Romans-Variable-25x258.ttf", "normal"),
                     ("Anthropic Serif", "AnthropicSerif-Italics-Variable-25x258.ttf", "italic")]
        return faces.compactMap { family, filename, style in
            guard let data = roots.lazy.compactMap({ try? Data(contentsOf: $0.appendingPathComponent(filename)) }).first else { return nil }
            return "@font-face{font-family:'\(family)';src:url(data:font/ttf;base64,\(data.base64EncodedString())) format('truetype');font-weight:300 800;font-style:\(style);}"
        }.joined(separator: "\n")
    }

    private enum ExportError: LocalizedError {
        case printFailed
        var errorDescription: String? { "The PDF could not be created. Please try exporting the recap again." }
    }
}
