import XCTest
@testable import Codenotch

/// Claude meters three limits at once, and a ring shows one number — so each
/// limit is its own ring. Everything keyed by the *account* has to keep
/// reaching the account after the split.
final class ProviderCellsTests: XCTestCase {
    private func claude(id: String = "claude",
                        windows: [LimitWindow],
                        headlineID: String? = "session",
                        block: UsageBlock? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            id: id, displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .ok,
            windows: windows, headlineID: headlineID, block: block
        )
    }

    private let threeWindows = [
        LimitWindow(id: "session", label: "Current session", usedFraction: 0.68,
                    resetsAt: Date(timeIntervalSince1970: 1_787_910_000)),
        LimitWindow(id: "weekly_all", label: "All models", usedFraction: 0.42,
                    resetsAt: Date(timeIntervalSince1970: 1_788_310_000)),
        LimitWindow(id: "weekly_fable", label: "Fable", usedFraction: 0.91,
                    resetsAt: Date(timeIntervalSince1970: 1_788_310_000)),
    ]

    func testEachClaudeWindowBecomesItsOwnRing() {
        let cells = ProviderCells.split(claude(windows: threeWindows))

        XCTAssertEqual(cells.map(\.id),
                       ["claude#session", "claude#weekly_all", "claude#weekly_fable"],
                       "the provider's own order is kept, so the rings never swap places")
        // Each ring reads its own window and nothing else.
        XCTAssertEqual(cells.map(\.headlineText), ["68%", "42%", "91%"])
        XCTAssertEqual(cells.map { $0.windows.count }, [1, 1, 1])
        XCTAssertEqual(cells.map { $0.headline?.label },
                       ["Current session", "All models", "Fable"])
    }

    /// The split is a display concern: a refresh click, an in-flight fetch and
    /// the archive are all keyed by the account, which every cell still names.
    func testEveryCellStillNamesTheAccount() {
        for cell in ProviderCells.split(claude(windows: threeWindows)) {
            XCTAssertEqual(cell.providerID, "claude")
        }
        for cell in ProviderCells.split(claude(id: "claude-work", windows: threeWindows)) {
            XCTAssertEqual(cell.providerID, "claude-work")
        }
    }

    /// A provider drawn as one ring has no separator in its id at all, so the
    /// account is simply the id.
    func testAnUnsplitProviderIsItsOwnAccount() {
        let codex = ProviderSnapshot(
            id: "codex", displayName: "Codex", glyph: .openai,
            fidelity: .official, status: .ok,
            windows: threeWindows, headlineID: "session"
        )
        XCTAssertEqual(ProviderCells.split(codex).map(\.id), ["codex"],
                       "only Claude splits; three rings elsewhere would say one thing")
        XCTAssertEqual(codex.providerID, "codex")
    }

    /// Live sessions belong to the account, not to a limit window. Put them on
    /// every ring and one agent reads as three things working.
    func testSessionsRideOnTheHeadlineRingOnly() {
        let cells = ProviderCells.split(claude(windows: threeWindows))
        XCTAssertEqual(cells.map(\.showsActivity), [true, false, false])
    }

    /// Three rings with the same glyph need the caption to tell them apart —
    /// short enough for a 44pt ring, unlike the tooltip's own wording.
    func testEachRingIsNamedUnderneath() {
        let cells = ProviderCells.split(claude(windows: threeWindows))
        XCTAssertEqual(cells.compactMap(\.caption), ["5h", "Weekly", "Fable"])
    }

    /// A balance is not a period, so it is not named after one — and its own
    /// label, "Spend limit", does not fit under a 44pt ring.
    func testAMeteredWindowIsCaptionedAsSpend() {
        let spend = LimitWindow(id: "spend_limit", label: "Spend limit",
                                usedFraction: 0.06, usedDollars: 12.5, limitDollars: 200)
        XCTAssertEqual(ProviderCells.caption(for: spend), "Spend")

        let cells = ProviderCells.split(claude(windows: threeWindows + [spend]))
        XCTAssertEqual(cells.compactMap(\.caption), ["5h", "Weekly", "Fable", "Spend"])
        XCTAssertEqual(cells.last?.headlineText, "6%")
    }

    /// An Enterprise seat reports one window and one only, so there is nothing
    /// to split — but the ring still needs its word: it carries the same mark
    /// as the plan's rings, sits beside them, and belongs to a different seat.
    func testALoneBalanceRingIsStillCaptioned() {
        let balance = LimitWindow(id: "spend", label: "Spend limit", usedFraction: 0.01485,
                                  usedDollars: 2.97, limitDollars: 200, currency: "USD")
        let cells = ProviderCells.split(claude(id: "claude-enterprise", windows: [balance],
                                               headlineID: "spend"))
        XCTAssertEqual(cells.map(\.id), ["claude-enterprise"], "one window is already one ring")
        XCTAssertEqual(cells.first?.caption, "Spend")
        XCTAssertEqual(cells.first?.headlineText, "1%")
        XCTAssertEqual(cells.first?.providerID, "claude-enterprise")
    }

    /// A ring that is the only one for its account says what it is by its
    /// glyph, so it gets no caption — only the line box kept for one, so the
    /// stack stays on a single pitch.
    func testAnUnsplitRingIsNotCaptioned() {
        let cursor = ProviderSnapshot(
            id: "cursor", displayName: "Cursor", glyph: .cursor,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "included", label: "Included usage", usedFraction: 0.5)]
        )
        XCTAssertNil(ProviderCells.split(cursor).first?.caption)
        XCTAssertNil(ProviderCells.split(claude(windows: [threeWindows[0]])).first?.caption)
    }

    /// A kind Anthropic has not shipped yet keeps the label the provider made
    /// for it rather than going blank.
    func testAnUnknownWindowFallsBackToItsLabel() {
        XCTAssertEqual(
            ProviderCells.caption(for: LimitWindow(id: "weekly_sonnet", label: "Sonnet")),
            "Sonnet"
        )
    }

    /// A window sitting at 4% is no help while the whole account is paused, so
    /// the block travels with every ring.
    func testABlockShowsOnEveryRing() {
        let block = UsageBlock(reason: "Paused", resetsAt: Date(timeIntervalSince1970: 1_787_910_000))
        let cells = ProviderCells.split(claude(windows: threeWindows, block: block))
        XCTAssertEqual(cells.compactMap { $0.block?.reason }, ["Paused", "Paused", "Paused"])
    }

    /// Splitting a lone window would rename the cell for no gain, and splitting
    /// none would drop the ring that carries the "sign in" message.
    func testNothingToSplitLeavesTheCellAlone() {
        let one = claude(windows: [threeWindows[0]])
        XCTAssertEqual(ProviderCells.split(one).map(\.id), ["claude"])

        let signedOut = ProviderSnapshot(
            id: "claude", displayName: "Claude", glyph: .claude,
            fidelity: .official, status: .needsAuth, windows: []
        )
        XCTAssertEqual(ProviderCells.split(signedOut).map(\.id), ["claude"])
        XCTAssertNotNil(ProviderCells.split(signedOut).first?.statusMessage)
    }

    /// The prompt on a signed-out cell has to name the profile, which it reads
    /// from the id — so it must survive the split too.
    func testTheAuthPromptStillNamesTheProfile() {
        let cells = ProviderCells.split(ProviderSnapshot(
            id: "claude-work", displayName: "Claude (work)", glyph: .claude,
            fidelity: .official, status: .needsAuth,
            windows: [], headlineID: "session"
        ))
        XCTAssertEqual(cells.first?.statusMessage,
                       "Sign in to Claude Code in ~/.claude-work to read your usage")
    }

    func testTheWholeListIsExpandedInPlace() {
        let cursor = ProviderSnapshot(
            id: "cursor", displayName: "Cursor", glyph: .cursor,
            fidelity: .official, status: .ok,
            windows: [LimitWindow(id: "month", label: "This month", used: 412)]
        )
        let cells = ProviderCells.cells(for: [claude(windows: threeWindows), cursor])
        XCTAssertEqual(cells.map(\.id),
                       ["claude#session", "claude#weekly_all", "claude#weekly_fable", "cursor"])
    }
}
