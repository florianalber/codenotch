import Foundation

/// The first reading of a window since it last rolled over.
///
/// Kept for the windows whose length nobody publishes — a spend limit has no
/// cycle to average over — so that a burn rate can still be *measured* from
/// two of our own readings rather than assumed.
struct UsageBaseline: Codable, Equatable {
    let fraction: Double
    let takenAt: Date
    /// The reset this baseline was taken against. A different one means the
    /// window has rolled and the baseline says nothing about the new one.
    let resetsAt: Date?
}

/// Whether a window will be spent before it resets.
///
/// `UsagePace` answers a different question — how far ahead of an even spread
/// the window is — and says it in the card only. This is the one a colour can
/// carry at a glance: 20% used looks comfortable and is not, if it went in the
/// first half hour of a five-hour window.
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
    /// time did not announce. Without that second case the rate comes out
    /// negative and the window reports as lasting for ever, which is exactly
    /// when it isn't.
    static func baseline(_ held: UsageBaseline?, fraction: Double,
                         resetsAt: Date?, now: Date) -> UsageBaseline {
        let fresh = UsageBaseline(fraction: fraction, takenAt: now, resetsAt: resetsAt)
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

    /// When this window will be spent at the rate it is being spent at, but
    /// only where that lands *before* it resets — which is the whole question.
    /// Nil when it comfortably lasts, and nil wherever the answer cannot
    /// honestly be given yet.
    static func runsOut(_ window: LimitWindow, baseline: UsageBaseline?, now: Date) -> Date? {
        // Without a reset time there is nothing to run out *before*.
        guard let fraction = window.usedFraction, fraction.isFinite,
              let resetsAt = window.resetsAt, resetsAt > now else { return nil }
        // Already spent: the ring is at its last band, and a forecast adds
        // nothing to a limit you have already hit.
        let remaining = 1 - fraction
        guard remaining > 0 else { return nil }
        guard let rate = rate(fraction: fraction, duration: window.duration,
                              resetsAt: resetsAt, baseline: baseline, now: now)
        else { return nil }

        let runsOutAt = now.addingTimeInterval(remaining / rate)
        return runsOutAt < resetsAt ? runsOutAt : nil
    }

    /// Fraction of the window spent per second.
    ///
    /// The window's own average, wherever its length is known: what is gone,
    /// over how long the window has been open — the reset time *is* the start
    /// time, one length earlier.
    ///
    /// Preferred over a rate measured between two recent readings, which was
    /// the first thing tried and is wrong for this job. A colour that has to
    /// mean something at a glance must not flicker, and a rate taken over the
    /// last ten minutes of a bursty workload swings from "idle" to "twice what
    /// the plan allows" between one poll and the next. Measured live it read
    /// 13.7%/h against the window's own 23.3%/h on the same reading, purely
    /// because the previous quarter of an hour happened to be quiet — and the
    /// ring stayed green on a session that was an hour short.
    ///
    /// The average is also the figure a person works out for themselves ("24%
    /// gone and it opened an hour ago"), and it moves smoothly: an hour of
    /// quiet clears a warning by itself as the elapsed time grows, rather than
    /// snapping between colours as each lull begins and ends.
    private static func rate(fraction: Double, duration: TimeInterval?, resetsAt: Date,
                             baseline: UsageBaseline?, now: Date) -> Double? {
        if let duration, duration.isFinite, duration > 0 {
            guard fraction > 0 else { return nil }
            // Clamped: a reset time that has slipped forward would otherwise
            // report a window as *not yet open*.
            let elapsed = min(duration, duration - resetsAt.timeIntervalSince(now))
            // 1% in the first minute of five hours projects to running out in
            // ninety, so every session would go amber on its first request.
            // Proportional as well, so a weekly window is not judged on its
            // first hour either. Below the floor this says nothing at all
            // rather than falling back to a measured rate, which is just as
            // jittery that early and for the same reason.
            guard elapsed >= max(minimumSpan, duration * 0.05) else { return nil }
            return fraction / elapsed
        }

        // No known length, so there is nothing to average over. Two of our own
        // readings are then the only route to a rate at all.
        guard let baseline, now.timeIntervalSince(baseline.takenAt) >= minimumSpan
        else { return nil }
        let burned = fraction - baseline.fraction
        guard burned > 0 else { return nil }   // standing still lasts for ever
        return burned / now.timeIntervalSince(baseline.takenAt)
    }
}
