import Foundation

/// "how long has it been like this" — the second half of answering "is Claude
/// still working".
enum ElapsedCopy {
    /// The same span, phrased as a point in the past.
    static func ago(since: Date, now: Date = Date()) -> String {
        let elapsed = text(since: since, now: now)
        return elapsed == "just now" ? elapsed : "\(elapsed) ago"
    }

    /// The same phrasing for a span that lies ahead rather than behind, so
    /// "2 hr" means the same thing in both directions. "just now" would read
    /// as nonsense forwards, so an imminent one is simply "now".
    static func until(_ date: Date, now: Date = Date()) -> String {
        let span = text(since: now, now: date)
        return span == "just now" ? "now" : span
    }

    static func text(since: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 45 { return "just now" }

        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) min" }

        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "\(hours) hr" }
        return "\(hours) hr \(rest) min"
    }
}
