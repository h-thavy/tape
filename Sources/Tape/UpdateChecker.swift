import AppKit
import CryptoKit
import Security
import os

/// Keeps Tape up to date from GitHub releases, as Onword does: checks the public "latest release" of
/// h-thavy/tape (sending nothing about you) at launch and every few hours and, with one click, downloads it,
/// verifies its checksum and that it's signed by the same certificate as this copy (so permissions and the
/// Keychain keep working), swaps the app in place and relaunches. Never in the middle of a recording or a recap:
/// then it waits until they're done.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    /// Test hook: TAPE_TEST_VERSION=0.1.0 pretends this is an older version, to try the update flow.
    static let currentVersion = ProcessInfo.processInfo.environment["TAPE_TEST_VERSION"]
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    private static let repo = "h-thavy/tape"
    private static let releases = URL(string: "https://github.com/\(repo)/releases/latest")!

    enum State: Equatable {
        case unknown, checking, upToDate, available(String)
        /// Asked to update while recording or making a recap: it happens once they're done.
        case waiting(String)
        /// Downloading the new version (0…1).
        case downloading(String, Double)
        case installing(String)
        case failed(String)
    }
    @Published private(set) var state: State = .unknown
    private var lastCheck = Date.distantPast
    private var timer: Timer?
    private var announced: String?
    private let log = Logger(subsystem: "io.github.h-thavy.tape", category: "updates")

    /// The newer version on GitHub, if one is available.
    var availableVersion: String? {
        switch state {
        case .available(let version), .waiting(let version): version
        default: nil
        }
    }

    /// Checks now and every 6 hours.
    func start() {
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            MainActor.assumeIsolated { UpdateChecker.shared.check() }
        }
    }

    func checkIfStale(maxAge: TimeInterval = 60) {
        if Date().timeIntervalSince(lastCheck) > maxAge { check() }
    }

    func check() {
        switch state {
        case .checking, .downloading, .installing, .waiting: return
        default: break
        }
        state = .checking
        lastCheck = Date()
        Task {
            do {
                let tag = try await Self.latestTag()
                let latest = String(tag.dropFirst())
                state = Self.isNewer(latest, than: Self.currentVersion) ? .available(latest) : .upToDate
                log.notice("Update check: latest \(latest, privacy: .public), this \(Self.currentVersion, privacy: .public)")
                // Test hook: TAPE_TEST_AUTOUPDATE=1 updates without asking.
                if case .available = state, ProcessInfo.processInfo.environment["TAPE_TEST_AUTOUPDATE"] != nil {
                    update()
                    return
                }
                if case .available(let version) = state, announced != version {
                    announced = version
                    Toast.shared.show(.init(
                        id: "update", symbol: "arrow.down.circle", title: "Tape \(version) is available",
                        message: "Updates in a few seconds; your recordings and settings stay.",
                        primary: .init(title: "Update", symbol: "arrow.down") { UpdateChecker.shared.update() },
                        secondary: .init(title: "Later") {},
                        timeout: 20))
                }
            } catch {
                log.notice("Update check failed: \(error.localizedDescription, privacy: .public)")
                state = .unknown
            }
        }
    }

    /// The newest release's tag ("v0.3.1"): from GitHub's API, which is current at once; if that's
    /// unavailable (it allows 60 requests an hour per network), from github.com/…/releases/latest, which
    /// redirects to …/releases/tag/vX.Y.Z but can lag a few minutes behind a new release.
    private static func latestTag() async throws -> String {
        var api = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 10)
        api.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let (data, response) = try? await URLSession.shared.data(for: api), (response as? HTTPURLResponse)?.statusCode == 200,
           let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String, tag.hasPrefix("v") {
            return tag
        }
        var request = URLRequest(url: releases, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        let tag = response.url?.lastPathComponent ?? ""
        guard tag.hasPrefix("v"), (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("no release found") }
        return tag
    }

    func openRelease() {
        NSWorkspace.shared.open(Self.releases)
    }

    // MARK: - One-click update

    /// Something that an update would cut off.
    private var busy: Bool {
        Recorder.shared.isRecording || Recorder.shared.saving > 0 || Library.shared.items.contains(where: \.isWorking)
    }

    /// Downloads the new release, checks it, replaces this app and relaunches; while recording or making a recap,
    /// once that's done.
    func update() {
        guard let version = availableVersion else { return }
        guard !busy else {
            state = .waiting(version)
            log.notice("Update to \(version, privacy: .public) waits for the recording or recap to finish")
            Task {
                while busy { try? await Task.sleep(for: .seconds(5)) }
                state = .available(version)
                update()
            }
            return
        }
        state = .downloading(version, 0)
        Task {
            do {
                let app = try await download(version)
                state = .installing(version)
                try install(app)
            } catch {
                log.error("Update failed: \(error.localizedDescription, privacy: .public)")
                state = .failed("Couldn’t update: \(error.localizedDescription)")
            }
        }
    }

    private struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Downloads and unpacks the release zip, verifying its SHA-256 and that it's signed like this copy.
    private func download(_ version: String) async throws -> URL {
        let base = URL(string: "https://github.com/\(Self.repo)/releases/download/v\(version)")!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TapeUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let (checksumData, _) = try await URLSession.shared.data(from: base.appendingPathComponent("Tape.zip.sha256"))
        let expected = String(decoding: checksumData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").first.map(String.init) ?? ""

        let zip = try await downloadWithProgress(base.appendingPathComponent("Tape.zip"), version: version)
        let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        guard !expected.isEmpty, actual == expected else { throw UpdateError("the download didn’t match its checksum") }

        let unpacked = folder.appendingPathComponent("unpacked")
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        let app = unpacked.appendingPathComponent("Tape.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw UpdateError("the download had no Tape.app") }
        try verifySameSigner(app)
        return app
    }

    /// The new app must meet this copy's designated requirement (same identifier, same certificate). Then macOS
    /// sees it as the same app: permissions and the Keychain items holding the API keys keep working, and no one
    /// else's build can be swapped in.
    private func verifySameSigner(_ app: URL) throws {
        var me: SecCode?
        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyDesignatedRequirement(unsafeBitCast(me, to: SecStaticCode.self), [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError("its signature couldn’t be checked")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(newCode, flags, requirement) == errSecSuccess else {
            throw UpdateError("it isn’t signed like this copy of Tape")
        }
    }

    private func downloadWithProgress(_ url: URL, version: String) async throws -> URL {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("the download wasn’t found") }
        let total = max(1, response.expectedContentLength)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Tape-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                state = .downloading(version, Double(received) / Double(total))
            }
        }
        try handle.write(contentsOf: buffer)
        return destination
    }

    /// Hands off to a tiny script that waits for Tape to quit, swaps the bundle and opens the new one.
    private func install(_ newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("Tape can’t write to \(parent.path). Run the install command instead.")
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let backup = parent.appendingPathComponent(".Tape-previous.app")
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(backup.path)"
        mv "\(current.path)" "\(backup.path)" || exit 1
        if /usr/bin/ditto "\(newApp.path)" "\(current.path)"; then
          rm -rf "\(backup.path)"
        else
          rm -rf "\(current.path)"; mv "\(backup.path)" "\(current.path)"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null
        /usr/bin/open "\(current.path)"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try process.run()   // keeps running after Tape quits
        log.notice("Installing update; relaunching")
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed") }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
