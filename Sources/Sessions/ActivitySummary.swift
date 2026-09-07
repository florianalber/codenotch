import SwiftUI

/// What the activity cell shows: the state of every live session, reduced to
/// the one thing worth knowing at a glance.
struct ActivitySummary: Equatable {
    enum State: Equatable {
        case working
        case waiting
        case idle
    }

    let state: State
    let sessions: [AgentSession]

    /// Nil when nothing is running — the cell disappears rather than sitting
    /// there saying nothing.
    init?(sessions: [AgentSession]) {
        guard !sessions.isEmpty else { return nil }
        self.sessions = sessions
        // Anything blocked on you outranks anything merely busy: it is the only
        // state where the notch is asking for something.
        if sessions.contains(where: { $0.state == .waiting }) {
            state = .waiting
        } else if sessions.contains(where: { $0.state == .busy }) {
            state = .working
        } else {
            state = .idle
        }
    }

    /// One short word, for the tooltip.
    var label: String {
        switch state {
        case .working: return "working"
        case .waiting: return "waiting"
        case .idle:    return "idle"
        }
    }

    /// White for working, deliberately: the indicator sits inside a ring whose
    /// colour already means "how much of your limit is gone", and a neutral
    /// tone cannot be misread as part of that scale. Waiting gets amber because
    /// it is the one state that wants something from you.
    var color: Color {
        switch state {
        case .working: return Palette.textPrimary
        case .waiting: return Palette.watch
        case .idle:    return Palette.ringTrack
        }
    }

    var waitingSessions: [AgentSession] { sessions.filter { $0.state == .waiting } }

    /// When the session that has been kept waiting longest started waiting.
    /// The oldest, not the newest: a second session blocking behind the first
    /// must not make the pair look freshly blocked.
    var waitingSince: Date? { waitingSessions.map(\.since).min() }

    // MARK: - The glyph

    /// How loudly the provider's mark asks for you.
    ///
    /// Deliberately *only* about being blocked. The mark sits inside a ring
    /// whose yellow and orange already mean "this much of your limit is gone",
    /// and colouring the mark on the same scale for a second, unrelated fact
    /// would put two orange things with different meanings in one circle.
    /// Colour on the mark has exactly one meaning — a session is waiting on you
    /// — and the two steps say for how long. Working stays neutral: the arc
    /// inside the ring already turns for it.
    enum Attention: Equatable {
        case none
        /// Blocked, just now.
        case waiting
        /// Blocked long enough that it is being kept waiting.
        case overdue
    }

    /// When waiting becomes overdue.
    ///
    /// Two minutes: long enough that a prompt answered as soon as it was seen
    /// never turns the mark red, short enough that something forgotten on
    /// another desktop does.
    static let overdueAfter: TimeInterval = 120

    func attention(now: Date = Date()) -> Attention {
        guard state == .waiting, let waitingSince else { return .none }
        return now.timeIntervalSince(waitingSince) >= Self.overdueAfter ? .overdue : .waiting
    }

    /// What the provider's mark is tinted, or nil to leave it as it is.
    func glyphTint(now: Date = Date()) -> Color? {
        switch attention(now: now) {
        case .none:    return nil
        case .waiting: return Palette.watch
        case .overdue: return Palette.critical
        }
    }
}
