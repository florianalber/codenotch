import Foundation

/// "how long has it been like this" — the second half of answering "is Claude
/// still working".
enum ElapsedCopy {
    /// The same span, phrased as a point in the past.
    static func ago(since: Date, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        let elapsed = text(since: since, now: now, locale: locale)
        return elapsed == L10n.t("just now", locale: locale)
            ? elapsed
            : L10n.t("\(elapsed) ago", locale: locale)
    }

    /// The same phrasing for a span that lies ahead rather than behind, so
    /// "2 hr" means the same thing in both directions. "just now" would read
    /// as nonsense forwards, so an imminent one is simply "now".
    static func until(_ date: Date, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        guard date.timeIntervalSince(now) >= 45 else { return L10n.t("now", locale: locale) }
        return text(since: now, now: date, locale: locale)
    }

    static func text(since: Date, now: Date = Date(), locale: Locale = L10n.locale) -> String {
        let seconds = max(0, now.timeIntervalSince(since))
        if seconds < 45 { return L10n.t("just now", locale: locale) }

        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return L10n.t("\(max(1, minutes)) min", locale: locale) }

        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return L10n.t("\(hours) hr", locale: locale) }
        return L10n.t("\(hours) hr \(rest) min", locale: locale)
    }
}
