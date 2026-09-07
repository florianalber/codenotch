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

    /// The baseline to hold for the next reading.
    ///
    /// Restarted when the window rolls — a new reset time, or a reading that
    /// has gone *down*, which is a rollover the reset time did not announce.
    static func baseline(_ held: UsagePace?, fraction: Double,
                         resetsAt: Date?, now: Date) -> UsagePace {
        let fresh = UsagePace(fraction: fraction, takenAt: now, resetsAt: resetsAt)
        guard let held else { return fresh }
        guard held.resetsAt == resetsAt, fraction >= held.fraction else { return fresh }
        return held
    }

    /// When this window will be spent at the rate measured since the baseline,
    /// but only where that lands *before* it resets — which is the whole
    /// question. Nil when it comfortably lasts, and nil wherever the answer
    /// cannot honestly be given yet.
    static func runsOut(baseline: UsagePace, fraction: Double,
                        resetsAt: Date?, now: Date) -> Date? {
        // Without a reset time there is nothing to run out *before*.
        guard let resetsAt, resetsAt > now else { return nil }
        // Already spent: the ring is at its last band and a forecast would add
        // nothing to it.
        let remaining = 1 - fraction
        guard remaining > 0 else { return nil }

        let span = now.timeIntervalSince(baseline.takenAt)
        guard span >= minimumSpan else { return nil }

        let burned = fraction - baseline.fraction
        guard burned > 0 else { return nil }   // standing still lasts for ever

        let secondsLeft = remaining / (burned / span)
        let runsOutAt = now.addingTimeInterval(secondsLeft)
        return runsOutAt < resetsAt ? runsOutAt : nil
    }
}
