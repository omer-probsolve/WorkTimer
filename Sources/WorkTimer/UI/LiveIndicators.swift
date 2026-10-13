import SwiftUI
import WorkTimerCore

/// A dot with a ring that keeps rippling outward: "working right now".
///
/// Driven by the clock rather than view state, so periodic re-renders of the
/// surrounding view don't restart the animation.
struct BreathingDot: View {
    let color: Color
    var size: CGFloat = 6

    private static let period: TimeInterval = 1.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.period) / Self.period
            Circle()
                .fill(color)
                .background(
                    Circle()
                        .fill(color.opacity(0.55 * (1 - phase)))
                        .frame(width: size + 10 * phase, height: size + 10 * phase)
                )
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Working now")
    }
}

/// The worker's dot: breathing while live, still otherwise.
struct WorkerDot: View {
    let color: Color
    let live: Bool
    var size: CGFloat = 6

    var body: some View {
        if live {
            BreathingDot(color: color, size: size)
        } else {
            Circle().fill(color).frame(width: size, height: size)
        }
    }
}

/// The live marker before a name: a breathing dot while live. Otherwise an
/// empty slot of the same size when `keepsSpace`, so names line up.
struct LiveDot: View {
    let color: Color
    let live: Bool
    var keepsSpace = true

    var body: some View {
        if live {
            BreathingDot(color: color)
        } else if keepsSpace {
            Color.clear.frame(width: 6, height: 6)
        }
    }
}

extension View {
    /// A thin bar in `color` along the leading edge when `live`.
    func liveEdge(_ color: Color, live: Bool) -> some View {
        overlay(alignment: .leading) {
            if live {
                Rectangle().fill(color).frame(width: 2)
            }
        }
    }
}
