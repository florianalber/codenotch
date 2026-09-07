import AppKit
import Foundation

/// Notices Claude Code profiles appearing and disappearing while the app runs.
///
/// `ClaudeProfile.discover()` used to be read once at launch, which meant
/// signing a second account in — `CLAUDE_CONFIG_DIR=~/.claude-work claude` —
/// produced nothing until the app was restarted, with no hint that a restart
/// was what was missing.
///
/// Watched *and* polled, because neither alone is enough. The home directory's
/// own events fire when `~/.claude-<slug>` is created, but at that moment it is
/// an empty directory and deliberately not a profile yet: it becomes one when
/// Claude Code writes `sessions/`, `settings.json` and the rest *inside* it,
/// which a watch on the home directory never sees. So the event catches the
/// mkdir and the timer catches the sign-in a moment later.
@MainActor
final class ClaudeProfileWatcher {
    /// The current list, in `discover()`'s own order.
    private(set) var profiles: [ClaudeProfile]

    /// Called with the new list whenever it actually changes.
    var onChange: (([ClaudeProfile]) -> Void)?

    private let home: URL
    private let interval: TimeInterval
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var timer: Timer?
    private var debounce: DispatchWorkItem?

    init(profiles: [ClaudeProfile],
         home: URL = ClaudeProfile.homeDirectory,
         interval: TimeInterval = 30) {
        self.profiles = profiles
        self.home = home
        self.interval = interval
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
        source?.cancel()
        source = nil
    }

    /// Compare what is on disk with what we are showing, and report a genuine
    /// difference only. The home directory changes constantly for reasons that
    /// have nothing to do with Claude Code, and each of those changes lands
    /// here.
    func rescan() {
        let found = ClaudeProfile.discover(home: home)
        guard found != profiles else { return }
        profiles = found
        onChange?(found)
    }

    private func watchHome() {
        descriptor = open(home.path, O_EVTONLY)
        guard descriptor >= 0 else { return }   // the timer still covers us

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleRescan() }
        }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
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
