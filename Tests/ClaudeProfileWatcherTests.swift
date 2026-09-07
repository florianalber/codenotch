import XCTest
@testable import Codenotch

/// Profiles appearing and disappearing while the app runs. The watcher's file
/// events cannot be produced reliably in a test, so `rescan()` is driven
/// directly — it is the whole rule; the event and the timer only call it.
@MainActor
final class ClaudeProfileWatcherTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    /// Signing in writes files *inside* the directory, so this is the state a
    /// real sign-in leaves behind — not the bare `mkdir`.
    private func signIn(_ slug: String) throws {
        let directory = home.appendingPathComponent(".claude-\(slug)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
    }

    func testASignInIsReported() throws {
        let watcher = ClaudeProfileWatcher(profiles: [ClaudeProfile.default(home: home)],
                                           home: home)
        var reported: [[String]] = []
        watcher.onChange = { reported.append($0.map(\.id)) }

        try signIn("enterprise")
        watcher.rescan()

        XCTAssertEqual(reported, [["claude", "claude-enterprise"]])
        XCTAssertEqual(watcher.profiles.map(\.id), ["claude", "claude-enterprise"])
    }

    /// A directory that is merely created is deliberately not a profile yet —
    /// an empty one would put a permanent "sign in" ring in the notch for an
    /// account nobody has. This is why the watcher polls as well as watching:
    /// the files that make it a profile arrive later, inside it, where the
    /// home directory's own events cannot see them.
    func testAnEmptyDirectoryIsNotYetAProfile() throws {
        let watcher = ClaudeProfileWatcher(profiles: [ClaudeProfile.default(home: home)],
                                           home: home)
        var reported = 0
        watcher.onChange = { _ in reported += 1 }

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude-empty"), withIntermediateDirectories: true
        )
        watcher.rescan()
        XCTAssertEqual(reported, 0)

        try signIn("empty")   // now Claude Code has actually run there
        watcher.rescan()
        XCTAssertEqual(reported, 1)
    }

    /// The home directory changes constantly for reasons that have nothing to
    /// do with Claude Code, and every one of those changes lands in `rescan`.
    func testUnrelatedChangesReportNothing() throws {
        try signIn("work")
        let watcher = ClaudeProfileWatcher(
            profiles: ClaudeProfile.discover(home: home), home: home
        )
        var reported = 0
        watcher.onChange = { _ in reported += 1 }

        FileManager.default.createFile(atPath: home.appendingPathComponent("Screenshot.png").path,
                                       contents: nil)
        for _ in 0..<5 { watcher.rescan() }
        XCTAssertEqual(reported, 0)
    }

    /// A login that is deleted has to be reported too, or its ring would sit
    /// there for ever asking to sign in to an account that no longer exists.
    func testARemovedProfileIsReported() throws {
        try signIn("gone")
        let watcher = ClaudeProfileWatcher(
            profiles: ClaudeProfile.discover(home: home), home: home
        )
        var reported: [[String]] = []
        watcher.onChange = { reported.append($0.map(\.id)) }

        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude-gone"))
        watcher.rescan()

        XCTAssertEqual(reported, [["claude"]])
    }
}

extension FileManager {
    fileprivate func createFile(atPath path: String, contents: Data?) {
        createFile(atPath: path, contents: contents, attributes: nil)
    }
}
