import Foundation

/// The cells the notch draws, which is not always one per provider.
///
/// Claude meters three limits at once — the rolling session, the weekly
/// all-models allowance, and a weekly per-model one — and a ring can only ever
/// show one number. Behind a single ring the other two were readable only by
/// hovering, so the window that actually stopped you working could sit at 100%
/// while the notch showed a comfortable session figure. Each limit gets its own
/// ring instead, in the provider's own order: session, all models, then the
/// per-model window.
///
/// Only Claude splits. Every other provider either meters one window or
/// publishes windows that are not separate allowances, and a ring per row there
/// would be three rings saying one thing.
enum ProviderCells {
    static func cells(for snapshots: [ProviderSnapshot]) -> [ProviderSnapshot] {
        snapshots.flatMap(split)
    }

    static func split(_ snapshot: ProviderSnapshot) -> [ProviderSnapshot] {
        // One window is already one ring, and a provider with none has a
        // status to show rather than a reading — splitting either would drop
        // the cell entirely.
        guard splitsByWindow(snapshot), snapshot.windows.count > 1 else { return [snapshot] }

        // Which cell carries the account's live sessions. They belong to the
        // account, not to a limit window, so they go on the ring the provider
        // itself leads with — three spinning arcs for one agent would read as
        // three things working.
        let primary = snapshot.headlineID ?? snapshot.windows.first?.id

        return snapshot.windows.map { window in
            ProviderSnapshot(
                id: cellID(providerID: snapshot.id, windowID: window.id),
                displayName: snapshot.displayName,
                glyph: snapshot.glyph,
                fidelity: snapshot.fidelity,
                status: snapshot.status,
                // Its own window only: the tooltip names it on the row, so the
                // card says which ring is under the pointer.
                windows: [window],
                headlineID: window.id,
                // Account-wide, so every ring shows it. A window sitting at 4%
                // is no help while the account is paused.
                block: snapshot.block,
                showsActivity: window.id == primary,
                caption: caption(for: window)
            )
        }
    }

    /// The short name drawn under a split ring.
    ///
    /// All three Claude rings carry the same glyph, so the caption is the only
    /// thing on the notch itself that says which limit a percentage belongs to.
    /// It has to fit under a 44pt ring, which rules out the tooltip's own
    /// wording: "Current session" and "All models" are the right words for a
    /// card and far too long for a caption.
    ///
    /// The two fixed windows are named by their period, because that is what
    /// distinguishes them and what people call them. Anything else is a weekly
    /// *model* window — `weekly_opus`, `weekly_fable` — and there the model name
    /// is both shorter and more useful than the period it shares with the
    /// window above it. Falling back to the provider's own label keeps a kind
    /// Anthropic has not shipped yet readable rather than blank.
    static func caption(for window: LimitWindow) -> String {
        // A balance is not a period, so naming it after one would be wrong;
        // and its own label ("Spend limit") does not fit under a 44pt ring.
        if window.isMetered { return "Spend" }
        switch window.id {
        case "session":    return "5h"
        case "weekly_all": return "Weekly"
        default:           return window.label
        }
    }

    /// `claude` + `session` → `claude#session`.
    ///
    /// The separator cannot appear in a provider id or an Anthropic limit kind,
    /// so `ProviderSnapshot.providerID` can always take the account back out —
    /// which is what a refresh click, an in-flight fetch and the hover bands
    /// are all keyed by.
    static func cellID(providerID: String, windowID: String) -> String {
        "\(providerID)\(ProviderSnapshot.cellSeparator)\(windowID)"
    }

    private static func splitsByWindow(_ snapshot: ProviderSnapshot) -> Bool {
        ClaudeProfile.isClaude(providerID: snapshot.providerID)
    }
}
