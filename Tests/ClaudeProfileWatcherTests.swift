import XCTest
@testable import Codenotch

/// Profiles appearing and disappearing while the app runs. The watcher's file
/// events and its settling delay cannot be produced reliably in a test, so
/// `rescan()` and `confirm()` are driven directly — they are the whole rule;
/// the event, the timer and the delay only call them.
@MainActor
final class ClaudeProfileWatcherTests: XCTestCase {
    private var home: URL!
    /// Stands in for the keychain: which profiles have a token filed.
    private var signedIn: Set<String> = []

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        signedIn = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func discover(_ home: URL) -> [ClaudeProfile] {
        ClaudeProfile.discover(home: home, hasCredential: { [signedIn] in
            signedIn.contains($0.id)
        })
    }

    private func watcher(profiles: [ClaudeProfile]? = nil) -> ClaudeProfileWatcher {
        ClaudeProfileWatcher(profiles: profiles ?? discover(home), home: home,
                             discover: { [unowned self] in self.discover($0) })
    }

    /// What a real sign-in leaves behind: files *inside* the directory, and a
    /// token filed for it — not the bare `mkdir`.
    private func signIn(_ slug: String) throws {
        let directory = home.appendingPathComponent(".claude-\(slug)")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
        signedIn.insert("claude-\(slug)")
    }

    func testASignInIsReported() throws {
        let watcher = watcher()
        var reported: [[String]] = []
        watcher.onChange = { reported.append($0.map(\.id)) }

        try signIn("enterprise")
        watcher.rescan()
        watcher.confirm()

        XCTAssertEqual(reported, [["claude", "claude-enterprise"]])
        XCTAssertEqual(watcher.profiles.map(\.id), ["claude", "claude-enterprise"])
    }

    /// A directory that is merely created is deliberately not a profile yet —
    /// an empty one would put a permanent "sign in" ring in the notch for an
    /// account nobody has. This is why the watcher polls as well as watching:
    /// what makes it a profile arrives later, where the home directory's own
    /// events cannot see it.
    func testAnEmptyDirectoryIsNotYetAProfile() throws {
        let watcher = watcher()
        var reported = 0
        watcher.onChange = { _ in reported += 1 }

        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".claude-empty"), withIntermediateDirectories: true
        )
        watcher.rescan()
        watcher.confirm()
        XCTAssertEqual(reported, 0)

        try signIn("empty")   // now Claude Code has actually run there
        watcher.rescan()
        watcher.confirm()
        XCTAssertEqual(reported, 1)
    }

    /// The home directory changes constantly for reasons that have nothing to
    /// do with Claude Code, and every one of those changes lands in `rescan`.
    func testUnrelatedChangesReportNothing() throws {
        try signIn("work")
        let watcher = watcher()
        var reported = 0
        watcher.onChange = { _ in reported += 1 }

        FileManager.default.createFile(atPath: home.appendingPathComponent("Screenshot.png").path,
                                       contents: nil, attributes: nil)
        for _ in 0..<5 {
            watcher.rescan()
            watcher.confirm()
        }
        XCTAssertEqual(reported, 0)
    }

    /// A login that is deleted has to be reported too, or its ring would sit
    /// there for ever asking to sign in to an account that no longer exists.
    func testARemovedProfileIsReported() throws {
        try signIn("gone")
        let watcher = watcher()
        var reported: [[String]] = []
        watcher.onChange = { reported.append($0.map(\.id)) }

        try FileManager.default.removeItem(at: home.appendingPathComponent(".claude-gone"))
        signedIn.remove("claude-gone")
        watcher.rescan()
        watcher.confirm()

        XCTAssertEqual(reported, [["claude"]])
    }

    /// Claude Code replaces a profile's keychain item on every token rotation
    /// instead of updating it. A scan that lands between the delete and the add
    /// sees a signed-in profile as signed out — and since the app answers a
    /// change by relaunching, reporting it would relaunch twice for nothing.
    func testATokenRotationIsNotAChange() throws {
        try signIn("enterprise")
        let watcher = watcher()
        var reported = 0
        watcher.onChange = { _ in reported += 1 }

        signedIn.remove("claude-enterprise")   // the old item is gone…
        watcher.rescan()
        signedIn.insert("claude-enterprise")   // …and the new one is filed
        watcher.confirm()

        XCTAssertEqual(reported, 0)
        XCTAssertEqual(watcher.profiles.map(\.id), ["claude", "claude-enterprise"])
    }

    /// Reported once, not once per look: after a change the watcher holds the
    /// new list, so the next scan of the same disk is quiet again.
    func testAChangeIsReportedOnce() throws {
        let watcher = watcher()
        var reported = 0
        watcher.onChange = { _ in reported += 1 }

        try signIn("work")
        for _ in 0..<3 {
            watcher.rescan()
            watcher.confirm()
        }
        XCTAssertEqual(reported, 1)
    }
}
