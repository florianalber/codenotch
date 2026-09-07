import XCTest
@testable import Codenotch

/// "At this rate, will it last?" — measured from two of our own readings,
/// because the endpoint never says when a window began.
final class UsageForecastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func baseline(_ fraction: Double, minutesAgo: Double,
                          resetsAt: Date? = nil) -> UsagePace {
        UsagePace(fraction: fraction, takenAt: now.addingTimeInterval(-minutesAgo * 60),
                  resetsAt: resetsAt)
    }

    /// 10% in half an hour, so 20% an hour: the 80% that is left goes in four
    /// hours, and the window does not roll for nine. It runs out five hours
    /// before it would have been given back — which is the whole point.
    func testAWindowThatWillNotLast() throws {
        let runsOut = try XCTUnwrap(UsageForecast.runsOut(
            baseline: baseline(0.10, minutesAgo: 30),
            fraction: 0.20,
            resetsAt: now.addingTimeInterval(9 * 3600),
            now: now
        ))
        XCTAssertEqual(runsOut.timeIntervalSince(now), 4 * 3600, accuracy: 60)
    }

    /// Exactly on the reset is not "before" it: a window that runs out at the
    /// moment it rolls has lasted.
    func testExactlyOnTheResetCountsAsLasting() {
        XCTAssertNil(UsageForecast.runsOut(
            baseline: baseline(0.10, minutesAgo: 30),
            fraction: 0.20,
            resetsAt: now.addingTimeInterval(4 * 3600),
            now: now
        ))
    }

    /// A gentler rate says nothing at all: 2% in half an hour leaves 88% to
    /// spend, which at that pace takes twenty-two hours — long past a reset
    /// four hours out.
    func testAWindowThatLastsSaysNothing() {
        XCTAssertNil(UsageForecast.runsOut(
            baseline: baseline(0.10, minutesAgo: 30),
            fraction: 0.12,
            resetsAt: now.addingTimeInterval(4 * 3600),
            now: now
        ))
    }

    /// Standing still lasts for ever, whatever the clock says.
    func testNoBurnMeansNoForecast() {
        XCTAssertNil(UsageForecast.runsOut(
            baseline: baseline(0.40, minutesAgo: 120),
            fraction: 0.40,
            resetsAt: now.addingTimeInterval(600),
            now: now
        ))
    }

    /// A rate needs a span to be a rate. One percent between two polls ninety
    /// seconds apart projects to nonsense, and the bar would flick amber every
    /// time a single request landed between readings.
    func testAFreshBaselineIsNotYetARate() {
        XCTAssertNil(UsageForecast.runsOut(
            baseline: baseline(0.01, minutesAgo: 1.5),
            fraction: 0.02,
            resetsAt: now.addingTimeInterval(4 * 3600),
            now: now
        ))
        // The same burn, once the baseline has stood long enough to mean it.
        XCTAssertNotNil(UsageForecast.runsOut(
            baseline: baseline(0.01, minutesAgo: 30),
            fraction: 0.50,
            resetsAt: now.addingTimeInterval(4 * 3600),
            now: now
        ))
    }

    /// A spent window is already at its last band; a forecast adds nothing.
    func testAnExhaustedWindowNeedsNoForecast() {
        XCTAssertNil(UsageForecast.runsOut(
            baseline: baseline(0.5, minutesAgo: 60),
            fraction: 1.0,
            resetsAt: now.addingTimeInterval(3600),
            now: now
        ))
    }

    /// Without a reset time there is nothing to run out *before*.
    func testNoResetTimeMeansNoForecast() {
        XCTAssertNil(UsageForecast.runsOut(
            baseline: baseline(0.1, minutesAgo: 60), fraction: 0.9,
            resetsAt: nil, now: now
        ))
    }

    // MARK: - Keeping the baseline

    func testTheBaselineIsHeldWhileTheWindowStands() {
        let reset = now.addingTimeInterval(3600)
        let held = baseline(0.2, minutesAgo: 45, resetsAt: reset)
        XCTAssertEqual(
            UsageForecast.baseline(held, fraction: 0.3, resetsAt: reset, now: now),
            held
        )
    }

    /// The reported bug: the endpoint's reset time drifts by milliseconds
    /// between polls, and comparing it exactly read that as a fresh window.
    /// The baseline then restarted on every reading, its age was always zero,
    /// and the forecast was never made at all — with nothing visibly broken.
    func testMillisecondDriftIsTheSameWindow() {
        let reset = now.addingTimeInterval(4 * 3600)
        let held = baseline(0.20, minutesAgo: 45, resetsAt: reset)
        let drifted = reset.addingTimeInterval(0.046)   // the figures actually seen
        XCTAssertTrue(UsageForecast.isSameWindow(reset, drifted))
        XCTAssertEqual(
            UsageForecast.baseline(held, fraction: 0.30, resetsAt: drifted, now: now),
            held,
            "a 46ms drift must not throw the measurement away"
        )
    }

    /// And a window that has genuinely rolled moves its reset by hours, which
    /// the tolerance must still catch.
    func testARealRolloverIsStillNoticed() {
        let reset = now.addingTimeInterval(600)
        XCTAssertFalse(UsageForecast.isSameWindow(reset, reset.addingTimeInterval(5 * 3600)))
        XCTAssertFalse(UsageForecast.isSameWindow(reset, nil))
        XCTAssertTrue(UsageForecast.isSameWindow(nil, nil))
    }

    /// A new reset time is a new window, and the old baseline says nothing
    /// about it.
    func testARolloverRestartsTheBaseline() {
        let held = baseline(0.9, minutesAgo: 45, resetsAt: now.addingTimeInterval(60))
        let fresh = UsageForecast.baseline(held, fraction: 0.0,
                                           resetsAt: now.addingTimeInterval(5 * 3600), now: now)
        XCTAssertEqual(fresh.fraction, 0)
        XCTAssertEqual(fresh.takenAt, now)
    }

    /// And a reading that has gone *down* is a rollover the reset time did not
    /// announce — without this the rate would come out negative and the window
    /// would be reported as lasting for ever.
    func testAFallingReadingAlsoRestartsIt() {
        let reset = now.addingTimeInterval(3600)
        let held = baseline(0.8, minutesAgo: 45, resetsAt: reset)
        let fresh = UsageForecast.baseline(held, fraction: 0.05, resetsAt: reset, now: now)
        XCTAssertEqual(fresh.fraction, 0.05)
        XCTAssertEqual(fresh.takenAt, now)
    }
}

/// The colour rule the forecast feeds.
final class ForecastBandTests: XCTestCase {
    /// The point of the whole thing: a percentage that looks comfortable, on a
    /// window that will not last, is worth watching.
    func testAComfortablePercentageTurnsAmberOnPace() {
        XCTAssertEqual(UsageBand.band(for: 0.2), .ample)
        XCTAssertEqual(UsageBand.band(for: 0.2, runsOutBeforeReset: true), .watch)
    }

    /// It can only raise. "You will run out" is not news beside "you nearly
    /// have", and a forecast must never make a spent limit look better.
    func testItNeverLowersTheBand() {
        XCTAssertEqual(UsageBand.band(for: 0.75, runsOutBeforeReset: true), .critical)
        XCTAssertEqual(UsageBand.band(for: 1.0, runsOutBeforeReset: true), .exhausted)
        XCTAssertEqual(UsageBand.band(for: 0.6, runsOutBeforeReset: true), .watch)
    }

    func testWithoutAForecastNothingChanges() {
        for fraction in [0.0, 0.2, 0.55, 0.8, 1.2] {
            XCTAssertEqual(UsageBand.band(for: fraction, runsOutBeforeReset: false),
                           UsageBand.band(for: fraction), "\(fraction)")
        }
    }
}

/// The span, phrased forwards.
final class ElapsedUntilTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testItReadsLikeTheOtherSpans() {
        XCTAssertEqual(ElapsedCopy.until(now.addingTimeInterval(2 * 3600), now: now), "2 hr")
        XCTAssertEqual(ElapsedCopy.until(now.addingTimeInterval(51 * 60), now: now), "51 min")
    }

    /// "just now" reads as nonsense forwards.
    func testAnImminentSpanIsNow() {
        XCTAssertEqual(ElapsedCopy.until(now.addingTimeInterval(10), now: now), "now")
    }
}
