import SwiftUI

/// The ring around a provider glyph: a grey track with a coloured arc that
/// starts at 12 o'clock and sweeps clockwise by the fraction used.
///
/// When that provider is doing something right now, a second, much thinner arc
/// appears *inside* the ring, in the gap between the glyph and the track. It is
/// deliberately a different radius, a different weight and a neutral colour, so
/// it reads as a separate fact rather than as the usage number moving.
struct ProviderRing: View {
    /// Nil when the provider reports what is left but never says out of what —
    /// there is no arc to draw, and inventing one would be a lie in a shape.
    let usedFraction: Double?
    let glyph: ProviderGlyph
    var isStale: Bool = false
    /// Blocked right now. Shown as spent whatever the arc says, because that is
    /// what it means for you — a ring reading 16% while the account is paused
    /// is technically true and practically a lie.
    var isBlocked: Bool = false
    var activity: ActivitySummary?
    /// A fetch this cell asked for, in flight.
    var isRefreshing: Bool = false
    /// The clock the "how long has it been waiting" step is measured against.
    /// Passed in rather than read here so it ticks with the rest of the notch.
    var now: Date = Date()

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spin: Double = 0

    private var band: UsageBand {
        isBlocked ? .exhausted : UsageBand.band(for: usedFraction ?? 0)
    }
    private var sweep: CGFloat { CGFloat(min(max(usedFraction ?? 0, 0), 1)) }

    /// Yellow while a session waits on you, orange once it has waited a while,
    /// white the rest of the time — see `ActivitySummary.Attention`.
    private var glyphTint: Color { activity?.glyphTint(now: now) ?? Palette.textPrimary }

    /// Whether the mark is currently asking for something.
    private var isAsking: Bool { activity?.attention(now: now) != .none && activity != nil }

    /// How dimmed the mark is.
    ///
    /// A stale reading and a spent limit each dim it, and together they
    /// compound — that is the existing behaviour and it is right: both say the
    /// ring is not worth acting on. A waiting session overrules both. It is
    /// known first-hand rather than fetched, so an old percentage says nothing
    /// about it, and a mark faded to a sixth of its strength is not a mark that
    /// can carry a colour at all.
    private var glyphOpacity: Double {
        guard !isAsking else { return 1 }
        return (band == .exhausted ? 0.35 : 1) * (isStale ? 0.45 : 1)
    }

    var body: some View {
        ZStack {
            // Dimming applies to the usage reading only — the track and the
            // arc. Whether Claude is working, or waiting on you, is known
            // first-hand and stays at full strength even when the percentage
            // behind it has gone stale, so both the mark and the activity arc
            // sit outside this group.
            ZStack {
                Circle()
                    .strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)

                if usedFraction != nil {
                    Circle()
                        .inset(by: NotchLayout.trackStroke / 2)
                        .trim(from: 0, to: sweep)
                        .stroke(
                            band.color,
                            style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round)
                        )
                        // Refreshing spins the reading itself rather than
                        // overlaying a separate spinner: the thing being
                        // refetched is the thing that should move, and a second
                        // arc on the same track only competes with it.
                        .rotationEffect(.degrees(-90 + spin))
                        // A ring that snaps to a new value reads as a glitch; one
                        // that sweeps reads as a measurement being taken.
                        .animation(NotchMotion.reading, value: sweep)
                        .animation(NotchMotion.reading, value: band)
                }
            }
            .opacity(isStale ? 0.45 : 1)

            // The mark is the indicator: it pulses while the session works,
            // harder while one waits on you. Not a second moving shape inside
            // a 44pt ring that already has a coloured arc around it.
            GlyphActivity(state: reduceMotion ? .idle : (activity?.state ?? .idle)) {
                ProviderGlyphView(glyph: glyph)
                    .foregroundStyle(glyphTint)
                    .opacity(glyphOpacity)
                    // A mark that snaps to a new colour reads as a glitch; the
                    // same easing the reading itself uses makes it a state
                    // changing.
                    .animation(NotchMotion.reading, value: glyphTint)
                    .animation(NotchMotion.reading, value: glyphOpacity)
            }

            // Reduce Motion keeps the arc that used to carry this. It says the
            // same two things with nothing moving — three quarters of a ring
            // for working, a whole one for waiting — which a mark that is
            // simply *not turning* cannot say at all.
            if reduceMotion, let activity, activity.state != .idle {
                ActivityArc(summary: activity)
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        // Pressed in while it works, and released when the answer lands. The
        // ring is the button, so the ring is what should feel pressed.
        .scaleEffect(isRefreshing ? 0.93 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isRefreshing)
        .onChange(of: isRefreshing) { _, refreshing in
            guard refreshing, !reduceMotion else { return }
            // Exactly one turn, and it stops by itself.
            //
            // The obvious spelling is a `repeatForever` linear spin started on
            // the way in and cancelled on the way out — but `repeatForever` does
            // not stop when you set the value back, and if the value you set is
            // the one it is already animating toward, nothing changes and it
            // simply keeps going. The ring then spins for ever after a refresh
            // that finished half a second in.
            //
            // A single finite turn has no cancellation problem at all: 360° is
            // the same angle as 0°, so it lands exactly where the reading
            // belongs. It eases out, so it settles rather than stopping dead.
            withAnimation(.timingCurve(0.32, 0, 0.14, 1, duration: 0.95)) {
                spin += 360
            }
        }
    }
}

/// The provider's mark, saying what its sessions are doing.
///
/// Why the animation lives in a *branch* rather than behind a flag: a
/// `repeatForever` animation does not stop when the value driving it is set
/// back — and if that value is the one it is already heading for, nothing
/// changes and it simply keeps going. The refresh spin above and `ActivityArc`
/// below are each commented for the same trap. A branch that stops existing
/// takes its animation with it, which is the one cancellation that is reliable.
private struct GlyphActivity<Content: View>: View {
    let state: ActivitySummary.State
    @ViewBuilder let content: Content

    var body: some View {
        switch state {
        // Both pulses are Claude's own, taken from the stylesheet the desktop
        // app ships: `cds-skeleton-breathe` is opacity 1 → .6 over 2s
        // ease-in-out, and the plainer `pulse` is 1 → .4 over 1.5s. So the
        // mark here breathes exactly the way Claude's own surfaces breathe
        // while they are working — which is the thing being reported.
        case .working: Breathing(trough: 0.6, scale: 0.86, period: 2.0) { content }
        // The insistent one of the pair, because this state wants something.
        // The colour says so too; the two together are hard to miss and still
        // not a different vocabulary.
        case .waiting: Breathing(trough: 0.4, scale: 0.78, period: 1.5) { content }
        case .idle:    content
        }
    }
}

/// A breath: the mark draws in and fades, then comes back to full size and
/// full strength.
///
/// Faint *and* small at the bottom of the breath, rather than one or the other
/// — the two move together, so it reads as one movement instead of two effects
/// on the same object. It shrinks rather than blooming: the mark sits inside a
/// ring with a track around it, and growing toward that track makes the pair
/// look crowded at the top of every breath.
///
/// No rotation, on purpose: turning a logo makes it stop reading as that logo
/// for as long as it moves, and the ring's identity is the only thing the mark
/// is there for.
private struct Breathing<Content: View>: View {
    /// How faint it gets at the bottom of the breath.
    let trough: Double
    /// And how small — a fraction of its resting size.
    let scale: Double
    /// Seconds for the whole in-and-out.
    let period: Double
    @ViewBuilder let content: Content
    @State private var out = false

    var body: some View {
        content
            .scaleEffect(out ? scale : 1)
            .opacity(out ? trough : 1)
            .onAppear {
                // Half the period each way, which is what a CSS keyframe at
                // 50% means and what `autoreverses` gives.
                withAnimation(.easeInOut(duration: period / 2).repeatForever(autoreverses: true)) {
                    out = true
                }
            }
    }
}

/// The inner indicator the mark's own movement replaced, kept for Reduce
/// Motion: a static three-quarter arc while work is happening, and a whole ring
/// when something is blocked waiting on you.
private struct ActivityArc: View {
    let summary: ActivitySummary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false
    @State private var pulsing = false

    /// How much of the circle the moving arc covers.
    private let arcFraction: CGFloat = 0.25

    private var inset: CGFloat {
        (NotchLayout.ringDiameter - NotchLayout.activityDiameter) / 2
    }

    var body: some View {
        Group {
            switch summary.state {
            case .working: spinner
            case .waiting: pulse
            case .idle:    EmptyView()
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
    }

    private var spinner: some View {
        Circle()
            .inset(by: inset)
            .trim(from: 0, to: arcFraction)
            .stroke(
                summary.color,
                style: StrokeStyle(lineWidth: NotchLayout.activityStroke, lineCap: .round)
            )
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    spinning = true
                }
            }
            .onDisappear { spinning = false }
    }

    private var pulse: some View {
        Circle()
            .inset(by: inset)
            .stroke(summary.color, lineWidth: NotchLayout.activityStroke)
            .opacity(pulsing ? 0.3 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
            .onDisappear { pulsing = false }
    }
}

/// A ring and the percent burned underneath it.
struct ProviderCell: View {
    let snapshot: ProviderSnapshot
    var activity: ActivitySummary?
    var isRefreshing: Bool = false
    var now: Date = Date()

    /// A dash, not "0%": nothing read is not the same as nothing used.
    private var percentText: String {
        snapshot.hasReading ? snapshot.headlineText : "—"
    }

    var body: some View {
        // Spaced by explicit padding rather than by the stack: the two labels
        // sit at different distances, and the caption's own line box has to be
        // reserved whether or not there is a caption to put in it.
        VStack(spacing: 0) {
            ProviderRing(
                usedFraction: snapshot.hasReading ? snapshot.ringFraction : nil,
                glyph: snapshot.glyph,
                isStale: snapshot.status.isStale || !snapshot.hasReading,
                isBlocked: snapshot.block != nil,
                activity: activity,
                isRefreshing: isRefreshing,
                now: now
            )
            Text(percentText)
                .font(Typography.percent)
                .foregroundStyle(Palette.textPrimary)
                // Never squeezed: across a horizontal edge the cell is only as
                // wide as the ring, and a label wider than that would be
                // truncated rather than allowed to overhang into the spacing
                // that is already there for it.
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: NotchLayout.percentLineHeight)
                .contentTransition(.numericText())
                .animation(NotchMotion.reading, value: percentText)
                .padding(.top, NotchLayout.ringLabelGap)

            // Empty on a ring that needs no caption. Still laid out, so every
            // ring in the stack sits on the same pitch — see
            // `NotchLayout.captionLineHeight`.
            Text(snapshot.caption ?? "")
                .font(Typography.ringCaption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: NotchLayout.captionLineHeight)
                .padding(.top, NotchLayout.captionGap)
        }
        .frame(height: NotchLayout.cellExtent)
    }
}
