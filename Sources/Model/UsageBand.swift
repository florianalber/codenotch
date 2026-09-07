import SwiftUI

/// The colour a ring or bar takes at a given level of use.
///
/// The thresholds come from the mockup, which shows 21% green, 52% yellow and
/// 73% orange. (The prose table in the design spec says 50–79 is yellow, which
/// would make 73% yellow and contradict the frame it claims to describe — the
/// frame wins.)
enum UsageBand: Equatable {
    case ample       // under half
    case watch       // getting close
    case critical    // nearly out
    case exhausted   // limit hit, waiting for the reset

    /// The band a window shows, with what its own pace says folded in.
    ///
    /// A window on course to be spent before it resets is worth watching even
    /// at 20%, which is the one thing a percentage cannot say: the number looks
    /// comfortable right up until it isn't. It can only ever raise the band,
    /// never lower it — a forecast must not make a nearly-spent limit look
    /// better than it is, and "you will run out" is not news beside "you
    /// nearly have".
    static func band(for usedFraction: Double, runsOutBeforeReset: Bool) -> UsageBand {
        let plain = band(for: usedFraction)
        guard runsOutBeforeReset, plain == .ample else { return plain }
        return .watch
    }

    static func band(for usedFraction: Double) -> UsageBand {
        switch usedFraction {
        case ..<0.50: return .ample
        case ..<0.70: return .watch
        case ..<1.00: return .critical
        default:      return .exhausted
        }
    }

    var color: Color {
        switch self {
        case .ample:                 return Palette.ample
        case .watch:                 return Palette.watch
        case .critical, .exhausted:  return Palette.critical
        }
    }
}
