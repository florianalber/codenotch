import XCTest
@testable import Codenotch

/// A second Claude Code login kept under `~/.claude-<slug>` is its own account,
/// with its own token, its own limits and its own sessions. Reading only
/// `~/.claude` showed one of them and was blind to the rest.
final class ClaudeProfileTests: XCTestCase {
    private func home(_ layout: [String: [String]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeProfileTests.\(UUID().uuidString)")
        for (directory, files) in layout {
            let url = root.appendingPathComponent(directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for file in files {
                FileManager.default.createFile(atPath: url.appendingPathComponent(file).path,
                                               contents: Data())
            }
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    // MARK: - Identity

    /// The default keeps the id it has always had, so archived readings and
    /// connection choices survive the update.
    func testTheDefaultProfileIsUnchanged() {
        let profile = ClaudeProfile.default(home: URL(fileURLWithPath: "/Users/vinz"))
        XCTAssertNil(profile.slug)
        XCTAssertEqual(profile.id, "claude")
        XCTAssertEqual(profile.displayName, "Claude")
        XCTAssertEqual(profile.keychainService, "Claude Code-credentials")
        XCTAssertEqual(profile.sessionsDirectory.path, "/Users/vinz/.claude/sessions")
        XCTAssertEqual(profile.sourceName, "Claude Code")
        XCTAssertEqual(profile.signInCommand, "claude")
    }

    func testAProfileIsNamedAfterItsSlug() {
        let profile = ClaudeProfile(slug: "work",
                                    configDirectory: URL(fileURLWithPath: "/Users/vinz/.claude-work"))
        XCTAssertEqual(profile.id, "claude-work")
        XCTAssertEqual(profile.displayName, "Claude (work)")
        XCTAssertEqual(profile.sessionsDirectory.path, "/Users/vinz/.claude-work/sessions")
    }

    /// Claude Code files a non-default profile's token under the service name
    /// plus the first eight hex digits of the SHA-256 of the directory path.
    /// Getting this wrong means "sign in" on a ring for an account that is
    /// signed in.
    func testTheKeychainServiceCarriesClaudeCodesHashOfThePath() {
        let profile = ClaudeProfile(slug: "work",
                                    configDirectory: URL(fileURLWithPath: "/Users/vinz/.claude-work"))
        // `shasum -a 256` of the path, no trailing slash, no newline.
        XCTAssertEqual(profile.keychainService, "Claude Code-credentials-19914660")
    }

    /// The path is hashed as Claude Code sees it, and Claude Code does not see
    /// a trailing slash.
    func testATrailingSlashDoesNotChangeTheHash() {
        let slashed = ClaudeProfile(slug: "work",
                                    configDirectory: URL(fileURLWithPath: "/Users/vinz/.claude-work/"))
        XCTAssertEqual(slashed.keychainService, "Claude Code-credentials-19914660")
    }

    func testProviderIDsAreRecognised() {
        XCTAssertTrue(ClaudeProfile.isClaude(providerID: "claude"))
        XCTAssertTrue(ClaudeProfile.isClaude(providerID: "claude-work"))
        XCTAssertFalse(ClaudeProfile.isClaude(providerID: "claudex"))
        XCTAssertFalse(ClaudeProfile.isClaude(providerID: "cursor"))
        XCTAssertEqual(ClaudeProfile.slug(fromProviderID: "claude-work"), "work")
        XCTAssertNil(ClaudeProfile.slug(fromProviderID: "claude"))
        XCTAssertNil(ClaudeProfile.slug(fromProviderID: "claude-"))
    }

    // MARK: - Discovery

    func testDirectoryNamesAreParsedStrictly() {
        XCTAssertEqual(ClaudeProfile.slug(fromDirectoryName: ".claude-work"), "work")
        XCTAssertEqual(ClaudeProfile.slug(fromDirectoryName: ".claude-client-a"), "client-a")
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claude"), "the default is not a slug")
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claude-"), "an empty slug is no profile")
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claude.json"), "a file beside the default")
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: ".claudette"))
        XCTAssertNil(ClaudeProfile.slug(fromDirectoryName: "claude-work"), "not hidden, not ours")
    }

    /// The default comes first, then the rest by slug, so the rings keep their
    /// places from one launch to the next.
    func testDiscoveryFindsEveryUsedProfileInAStableOrder() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-work": ["settings.json"],
            ".claude-alpha": ["history.jsonl"]
        ])
        let found = ClaudeProfile.discover(home: home)
        XCTAssertEqual(found.map(\.id), ["claude", "claude-alpha", "claude-work"])
        XCTAssertEqual(found[2].configDirectory.path, home.appendingPathComponent(".claude-work").path)
    }

    /// An empty directory is not a profile: a permanent "sign in" ring for an
    /// account that does not exist is worse than no ring.
    func testDirectoriesClaudeCodeHasNeverUsedAreIgnored() throws {
        let home = try home([
            ".claude": ["settings.json"],
            ".claude-empty": [],
            ".claude-notes": ["README.md"]
        ])
        XCTAssertEqual(ClaudeProfile.discover(home: home).map(\.id), ["claude"])
    }

    /// Any one of the files Claude Code writes on first run is enough — they
    /// are not all present on every version.
    func testAnyFirstRunMarkerCounts() throws {
        let home = try home([
            ".claude-a": ["sessions"],
            ".claude-b": ["projects"],
            ".claude-c": [".claude.json"]
        ])
        XCTAssertEqual(ClaudeProfile.discover(home: home).map(\.id),
                       ["claude", "claude-a", "claude-b", "claude-c"])
    }

    /// A file named like a profile is not one, and must not crash discovery.
    func testAFileNamedLikeAProfileIsIgnored() throws {
        let home = try home([".claude": ["settings.json"]])
        FileManager.default.createFile(atPath: home.appendingPathComponent(".claude-work").path,
                                       contents: Data("not a directory".utf8))
        XCTAssertEqual(ClaudeProfile.discover(home: home).map(\.id), ["claude"])
    }

    /// `~/.claude` has always been read whether or not it exists yet, and a
    /// fresh Mac with no Claude Code still gets the ring that says so.
    func testTheDefaultIsAlwaysPresent() throws {
        let home = try home([:])
        XCTAssertEqual(ClaudeProfile.discover(home: home).map(\.id), ["claude"])
    }

    // MARK: - What the rest of the app derives from the id

    /// The tooltip's sign-in prompt has to name the directory, because plain
    /// `claude` signs the default profile in, not this one.
    func testTheSignInPromptNamesTheDirectory() {
        let snapshot = ProviderSnapshot(
            id: "claude-work", displayName: "Claude (work)", glyph: .claude,
            fidelity: .official, status: .needsAuth, windows: []
        )
        XCTAssertEqual(snapshot.statusMessage,
                       "Sign in to Claude Code in ~/.claude-work to read your usage")
    }

    /// Every profile's token is a keychain item, so every profile can be
    /// refused and needs the "Allow access…" button.
    func testEveryProfileUsesTheKeychain() {
        let summary = ProviderSummary(id: "claude-work", name: "Claude (work)", glyph: .claude,
                                      account: nil, signIn: .guidance("x"))
        XCTAssertTrue(summary.usesKeychain)
    }

    /// The rate limit is per account. A penalty on the work profile must not
    /// hold the personal one back, and the default keeps its old key so a
    /// penalty in progress survives the update.
    func testBackoffIsRememberedPerProfile() throws {
        let name = "ClaudeProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let archive = UsageArchive(defaults: defaults)

        let until = Date().addingTimeInterval(300)
        archive.saveBackoffUntil(until, providerID: "claude-work")
        XCTAssertNil(archive.loadBackoffUntil(providerID: "claude"))
        XCTAssertNil(archive.loadBackoffUntil(), "the no-argument form is the default profile")
        XCTAssertNotNil(archive.loadBackoffUntil(providerID: "claude-work"))

        archive.saveBackoffUntil(until)
        XCTAssertNotNil(defaults.object(forKey: "backoffUntil"), "the default's key is unchanged")
        archive.saveBackoffUntil(nil, providerID: "claude-work")
        XCTAssertNil(archive.loadBackoffUntil(providerID: "claude-work"))
        XCTAssertNotNil(archive.loadBackoffUntil(providerID: "claude"))
    }

    /// Two providers, one id each, both drawn: the store has no idea they are
    /// the same tool and must not collapse them.
    @MainActor
    func testTwoProfilesAreTwoCells() {
        let name = "ClaudeProfileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let home = URL(fileURLWithPath: "/Users/vinz")
        let store = UsageStore(
            providers: [
                ClaudeOAuthProvider(profile: .default(home: home), archive: UsageArchive(defaults: defaults)),
                ClaudeOAuthProvider(profile: ClaudeProfile(slug: "work",
                                                           configDirectory: home.appendingPathComponent(".claude-work")),
                                    archive: UsageArchive(defaults: defaults))
            ],
            archive: UsageArchive(defaults: defaults)
        )
        XCTAssertEqual(store.snapshots.map(\.id), ["claude", "claude-work"])
        XCTAssertEqual(store.snapshots.map(\.displayName), ["Claude", "Claude (work)"])
        XCTAssertEqual(store.providerSummaries.map(\.name), ["Claude", "Claude (work)"])
    }
}

/// A profile signed in while the app is running. Before this the list of
/// accounts was read once at launch, so a second login produced nothing at all
/// until the app was restarted — with no hint that a restart was what was
/// missing.
@MainActor
final class RuntimeProfileAdoptionTests: XCTestCase {
    private var defaults: UserDefaults!
    private let home = URL(fileURLWithPath: "/Users/vinz")

    override func setUp() {
        let name = "RuntimeProfileAdoption.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    private func provider(_ slug: String?) -> ClaudeOAuthProvider {
        let profile = slug.map {
            ClaudeProfile(slug: $0, configDirectory: home.appendingPathComponent(".claude-\($0)"))
        } ?? .default(home: home)
        return ClaudeOAuthProvider(profile: profile, archive: UsageArchive(defaults: defaults))
    }

    private func store(_ providers: [UsageProvider],
                       disconnected: Set<String> = []) -> UsageStore {
        UsageStore(providers: providers, archive: UsageArchive(defaults: defaults),
                   disconnected: disconnected)
    }

    func testAnAdoptedProfileGetsACellAtOnce() {
        let store = self.store([provider(nil)])
        XCTAssertEqual(store.snapshots.map(\.id), ["claude"])

        store.adopt(provider("enterprise"))
        XCTAssertEqual(store.snapshots.map(\.id), ["claude", "claude-enterprise"])
        XCTAssertEqual(store.providerSummaries.map(\.id), ["claude", "claude-enterprise"])
    }

    /// Adopting twice must not double the ring — the watcher reports the whole
    /// list, and a rescan can arrive while the first adoption is still settling.
    func testAdoptingTwiceIsHarmless() {
        let store = self.store([provider(nil)])
        store.adopt(provider("enterprise"))
        store.adopt(provider("enterprise"))
        XCTAssertEqual(store.snapshots.map(\.id), ["claude", "claude-enterprise"])
    }

    /// Beside its own kind, not at the end: the stack has to be in the same
    /// order now as it will be after the next launch, where `discover()` lists
    /// the profiles together at the front.
    func testItLandsBesideTheOtherProfiles() {
        let store = self.store([provider(nil), CursorLocalProvider()])
        store.adopt(provider("enterprise"))
        XCTAssertEqual(store.providerSummaries.map(\.id),
                       ["claude", "claude-enterprise", "cursor"])
        XCTAssertEqual(store.snapshots.map(\.id), ["claude", "claude-enterprise", "cursor"])
    }

    /// A profile switched off in settings is not fetched and draws no ring, and
    /// adopting it must not smuggle one in.
    func testASwitchedOffProfileStaysOff() {
        let store = self.store([provider(nil)], disconnected: ["claude-enterprise"])
        store.adopt(provider("enterprise"))
        XCTAssertEqual(store.snapshots.map(\.id), ["claude"])
        XCTAssertEqual(store.providerSummaries.map(\.id), ["claude", "claude-enterprise"],
                       "it is still listed in settings, so it can be switched back on")
    }

    /// A deleted login has to take its ring with it, or it would sit there for
    /// ever asking to sign in to an account that no longer exists.
    func testDroppingAProfileTakesItsCell() {
        let store = self.store([provider(nil), provider("enterprise")])
        store.drop(providerID: "claude-enterprise")
        XCTAssertEqual(store.snapshots.map(\.id), ["claude"])
        XCTAssertEqual(store.providerSummaries.map(\.id), ["claude"])
    }

    /// Dropping is not signing out: nothing of the account is deleted, so a
    /// directory that is moved back comes back with its number rather than as
    /// an empty ring.
    func testDroppingKeepsTheRememberedReading() {
        let archive = UsageArchive(defaults: defaults)
        let remembered = ProviderSnapshot(
            id: "claude-enterprise", displayName: "Claude (enterprise)", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "spend", label: "Spend limit", usedFraction: 0.0148,
                                  usedDollars: 2.97, limitDollars: 200, currency: "USD")],
            headlineID: "spend"
        )
        archive.save(["claude-enterprise": (remembered, Date())])

        let store = self.store([provider(nil), provider("enterprise")])
        XCTAssertEqual(store.snapshots.count, 2)
        store.drop(providerID: "claude-enterprise")
        XCTAssertNotNil(archive.load()["claude-enterprise"], "the archive is untouched")

        // And it comes back with the figure it had.
        store.adopt(provider("enterprise"))
        let back = store.snapshots.first { $0.id == "claude-enterprise" }
        XCTAssertEqual(back?.headline?.limitDollars, 200)
        XCTAssertTrue(back?.status.isStale ?? false, "remembered, and dated as such")
    }

    func testDroppingSomethingUnknownDoesNothing() {
        let store = self.store([provider(nil)])
        store.drop(providerID: "claude-nope")
        XCTAssertEqual(store.snapshots.map(\.id), ["claude"])
    }
}
