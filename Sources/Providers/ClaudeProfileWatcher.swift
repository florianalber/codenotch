import Foundation

/// Notices Claude Code profiles appearing and disappearing while the app runs.
///
/// `ClaudeProfile.discover()` is read once at launch, and everything built on
/// it — the rings, each profile's session monitor, which account owns which
/// session, the names that tell two accounts apart — is wired up together
/// from that one list. So signing a second account in with
/// `CLAUDE_CONFIG_DIR=~/.claude-work claude` produced nothing at all until the
/// app was restarted, with no hint that a restart was what was missing. This
/// only says *that* the list changed; `AppDelegate` answers by relaunching,
/// so a new profile goes through exactly the path the others went through.
///
/// Watched *and* polled, because neither alone is enough. The home directory's
/// own events fire when `~/.claude-<slug>` is created, but at that moment it is
/// an empty directory and deliberately not a profile yet: it becomes one when
/// Claude Code writes `sessions/` inside it and files a token for it, neither
/// of which a watch on the home directory sees. The event catches the mkdir,
/// the timer catches the sign-in a moment later.
@MainActor
final class ClaudeProfileWatcher {
    /// The list the app was built from, in `discover()`'s own order.
    private(set) var profiles: [ClaudeProfile]

    /// Called with the new list once a change has held — see `settle`.
    var onChange: (([ClaudeProfile]) -> Void)?

    private let home: URL
    private let interval: TimeInterval
    /// How long a changed list has to stay changed before it is reported.
    ///
    /// A profile counts only while Claude Code has a token filed for it, and
    /// Claude Code replaces that keychain item on every token rotation rather
    /// than updating it. Caught between the delete and the add, a profile that
    /// is signed in looks signed out — and answering that with a relaunch
    /// would relaunch twice in a row for nothing.
    private let settle: TimeInterval
    private let discover: (URL) -> [ClaudeProfile]
    private var source: DispatchSourceFileSystemObject?
    private var timer: Timer?
    private var debounce: DispatchWorkItem?
    private var confirmation: DispatchWorkItem?

    init(profiles: [ClaudeProfile],
         home: URL = ClaudeProfile.homeDirectory,
         interval: TimeInterval = 30,
         settle: TimeInterval = 5,
         discover: @escaping (URL) -> [ClaudeProfile] = { ClaudeProfile.discover(home: $0) }) {
        self.profiles = profiles
        self.home = home
        self.interval = interval
        self.settle = settle
        self.discover = discover
    }

    func start() {
        watchHome()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rescan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        debounce?.cancel()
        confirmation?.cancel()
        source?.cancel()
        source = nil
    }

    /// Compare what is on disk with what the app was built from.
    ///
    /// Reports nothing by itself: the home directory changes constantly for
    /// reasons that have nothing to do with Claude Code, and each of those
    /// changes lands here. A genuine difference is only a candidate until
    /// `confirm` sees it again.
    func rescan() {
        guard Self.differ(discover(home), profiles) else {
            confirmation?.cancel()
            confirmation = nil
            return
        }
        guard confirmation == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.confirm() }
        }
        confirmation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settle, execute: work)
    }

    /// The second look. Reports only a change that is still there.
    func confirm() {
        confirmation = nil
        let found = discover(home)
        guard Self.differ(found, profiles) else { return }
        profiles = found
        onChange?(found)
    }

    /// By id, which is what everything built from the list is keyed by.
    private static func differ(_ a: [ClaudeProfile], _ b: [ClaudeProfile]) -> Bool {
        a.map(\.id) != b.map(\.id)
    }

    private func watchHome() {
        let descriptor = open(home.path, O_EVTONLY)
        guard descriptor >= 0 else { return }   // the timer still covers us

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// One `mkdir` produces several events, and a sign-in produces a burst of
    /// them; coalesce.
    private func scheduleRescan() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.rescan() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
