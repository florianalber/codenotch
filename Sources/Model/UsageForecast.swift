import Foundation

/// The first reading of a window since it last rolled over.
///
/// Kept so a burn rate can be *measured* rather than assumed. The endpoint says
/// how much of a window is gone and when it rolls, and nothing at all about
/// when it began — so a rate worked out from an assumed window length ("the
/// session is five hours") is a guess wearing a number's clothes, and would go
/// quietly wrong the day a plan's windows change. Two of our own readings say
/// it without assuming anything.
struct UsagePace: Codable, Equatable {
    let fraction: Double
    let takenAt: Date
    /// The reset this baseline was taken against. A different one means the
    /// window has rolled and the baseline says nothing about the new one.
    let resetsAt: Date?
}

enum UsageForecast {
    /// How long a baseline has to have stood before a rate means anything.
    ///
    /// Under this, ordinary jitter projects to nonsense: one percent appearing
    /// between two polls ninety seconds apart "spends" a five-hour window in
    /// two hours, and the bar would flick amber every time a single request
    /// landed between readings.
    static let minimumSpan: TimeInterval = 10 * 60

    /// How far a window's reset time may move and still be the same window.
    ///
    /// The endpoint's reset time is not stable to the millisecond. Two polls a
    /// minute apart came back with `810490799.838` and `810490799.884`, and
    /// comparing them exactly read that 46-millisecond drift as a fresh
    /// window — so the baseline restarted on *every* reading, its age was
    /// always zero, and the forecast never lived long enough to be made at
    /// all. Nothing was visibly broken; there was simply never a warning.
    ///
    /// A real rollover moves the reset by the whole length of the window:
    /// hours for a session, days for a weekly. Ten minutes separates the two
    /// with room to spare in both directions.
    static let sameWindowTolerance: TimeInterval = 10 * 60

    /// The baseline to hold for the next reading.
    ///
    /// Restarted when the window rolls — a reset time that has genuinely
    /// moved, or a reading that has gone *down*, which is a rollover the reset
    /// time did not announce.
    static func baseline(_ held: UsagePace?, fraction: Double,
                         resetsAt: Date?, now: Date) -> UsagePace {
        let fresh = UsagePace(fraction: fraction, takenAt: now, resetsAt: resetsAt)
        guard let held else { return fresh }
        guard isSameWindow(held.resetsAt, resetsAt), fraction >= held.fraction else { return fresh }
        return held
    }

    /// Whether two reset times name the same window.
    static func isSameWindow(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil):
            return true
        case let (held?, fresh?):
            return abs(held.timeIntervalSince(fresh)) <= sameWindowTolerance
        default:
            // One of them has a reset time and the other does not, which is a
            // different shape of window rather than a moved one.
            return false
        }
    }

    /// How long each of Claude's windows is.
    ///
    /// The endpoint never says: it reports how much of a window is gone and
    /// when it rolls, and nothing about when it began. But the plan fixes it,
    /// and Claude Code's own `/usage` says the same — the session is the
    /// rolling five hours, the weekly windows are seven days — so the reset
    /// time *is* the start time, five hours or seven days earlier. That turns
    /// a single reading into a rate: what is gone, over how much of the window
    /// has passed.
    ///
    /// A kind that is not listed here gets no forecast from one reading. It
    /// still gets one from two, which is what `UsagePace` is for — and a spend
    /// limit, which has no length and no reset, gets none either way.
    static func length(ofWindow id: String) -> TimeInterval? {
        switch id {
        case "session":                    return 5 * 3600
        case _ where id.hasPrefix("weekly_"): return 7 * 24 * 3600
        default:                           return nil
        }
    }

    /// When this window will be spent at the rate it is being spent at, but
    /// only where that lands *before* it resets — which is the whole question.
    /// Nil when it comfortably lasts, and nil wherever the answer cannot
    /// honestly be given yet.
    static func runsOut(baseline: UsagePace?, window id: String, fraction: Double,
                        resetsAt: Date?, now: Date) -> Date? {
        // Without a reset time there is nothing to run out *before*.
        guard let resetsAt, resetsAt > now else { return nil }
        // Already spent: the ring is at its last band, and a forecast adds
        // nothing to a limit you have already hit.
        let remaining = 1 - fraction
        guard remaining > 0 else { return nil }
        guard let rate = rate(baseline: baseline, window: id, fraction: fraction,
                              resetsAt: resetsAt, now: now) else { return nil }

        let runsOutAt = now.addingTimeInterval(remaining / rate)
        return runsOutAt < resetsAt ? runsOutAt : nil
    }

    /// Fraction of the window spent per second.
    ///
    /// The window's own average, wherever the plan fixes its length: what is
    /// gone, over how long the window has been open.
    ///
    /// Preferred over a rate measured between two recent readings, which was
    /// the first thing tried here and is wrong for this job. A colour that has
    /// to mean something at a glance must not flicker, and a rate taken over
    /// the last ten minutes of a bursty workload swings from "idle" to "twice
    /// what the plan allows" between one poll and the next. Measured live it
    /// read 13.7%/h against the window's own 23.3%/h on the same reading,
    /// purely because the previous quarter of an hour happened to be quiet —
    /// and the ring stayed green on a session that was an hour short.
    ///
    /// The average is also the figure a person works out for themselves ("24%
    /// gone and it opened an hour ago"), and it moves smoothly: an hour of
    /// quiet clears a warning by itself as the elapsed time grows, rather than
    /// snapping between colours as each lull begins and ends.
    private static func rate(baseline: UsagePace?, window id: String, fraction: Double,
                             resetsAt: Date, now: Date) -> Double? {
        if let length = length(ofWindow: id) {
            guard fraction > 0 else { return nil }
            // The window opened one length before it closes, so this is how far
            // into it we are. Clamped: a reset time that has slipped forward
            // would otherwise report a window as *not yet open*.
            let elapsed = min(length, length - resetsAt.timeIntervalSince(now))
            // 1% in the first minute of five hours projects to running out in
            // ninety, so every session would go amber on its first request.
            // Proportional as well, so a weekly window is not judged on its
            // first hour either. Below the floor this says nothing at all
            // rather than falling back to a measured rate, which is just as
            // jittery that early and for the same reason.
            guard elapsed >= max(minimumSpan, length * 0.05) else { return nil }
            return fraction / elapsed
        }

        // No published length, so there is nothing to average over: a spend
        // limit's balance is all there is. Two of our own readings are then
        // the only route to a rate at all.
        guard let baseline, now.timeIntervalSince(baseline.takenAt) >= minimumSpan
        else { return nil }
        let burned = fraction - baseline.fraction
        guard burned > 0 else { return nil }   // standing still lasts for ever
        return burned / now.timeIntervalSince(baseline.takenAt)
    }
}
