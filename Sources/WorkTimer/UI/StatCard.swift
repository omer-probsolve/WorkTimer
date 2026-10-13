import SwiftUI

/// Tooltips explaining the numbers, shared by the popover and the dashboard.
enum Explain {
    static let leverage = "Work logged per hour of your time: you plus every agent session, divided by your time"

    static func agent(_ worker: Worker) -> String {
        "Agent-hours (parallel sessions each count) · sessions running at once, on average, while \(worker.name) worked"
    }
}

extension WorkLog {
    /// An agent card's second line: agent-hours, then the parallelism multiplier.
    /// Compact: "× 1:53 · 1.2×"; regular: "1:53 agent-hours · 1.2×".
    func agentSummary(_ worker: Worker, in interval: DateInterval, now: Date, compact: Bool) -> String? {
        guard worker != .you else { return nil }
        let clock = Format.clock(agentHours(worker, in: interval, now: now), seconds: false)
        let hours = compact ? "× \(clock)" : "\(clock) agent-hours"
        guard let parallel = parallelism(worker, in: interval, now: now) else { return hours }
        return "\(hours) · \(Format.multiplier(parallel))"
    }
}

extension Color {
    /// The quiet fill behind cards, badges and hovered rows.
    static let cardFill = Color.primary.opacity(0.05)
    static let cardFillHover = Color.primary.opacity(0.08)
}

extension View {
    /// The quiet rounded fill behind cards and grouped boxes.
    func cardBackground(cornerRadius: CGFloat = StatCard.cornerRadius) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius).fill(Color.cardFill))
    }
}

/// A totals card: title, a duration, an optional multiplier badge and a second
/// line. Used for the popover's cards and the dashboard's filter cards.
struct StatCard: View {
    enum Size { case compact, regular }

    static let cornerRadius: CGFloat = 8

    let title: String
    let color: Color
    let value: TimeInterval
    /// `.some(nil)` shows an empty badge ("—"); nil shows none.
    var badge: Double?? = nil
    var subtitle: String?
    var subtitleHelp = ""
    var live = false
    var size: Size = .regular
    /// Raised onto the window surface, like the selected segment of a picker.
    var selected = false
    var hovering = false
    /// Shows a clear button while selected.
    var onClear: (() -> Void)?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)
        VStack(alignment: .leading, spacing: size == .compact ? 1 : 2) {
            HStack(spacing: 6) {
                LiveDot(color: color, live: live, keepsSpace: false)
                Text(title).font(.caption).foregroundStyle(color)
                Spacer(minLength: 0)
                if selected, let onClear {
                    Button(action: onClear) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Show all sessions")
                }
            }
            HStack(spacing: 6) {
                Text(Format.clock(value, seconds: false))
                    .font(size == .compact ? .title3.weight(.medium) : .title2.weight(.medium))
                    .monospacedDigit()
                if let badge {
                    MultiplierBadge(value: badge)
                }
            }
            Text(subtitle ?? " ")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .lineLimit(1)
                .help(subtitle == nil ? "" : subtitleHelp)
        }
        .padding(size == .compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if selected {
                shape
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
            } else {
                shape.fill(hovering ? Color.cardFillHover : Color.cardFill)
            }
        }
        .liveEdge(color, live: live)
        .clipShape(shape)
        .shadow(color: .black.opacity(selected ? 0.15 : 0), radius: 2, y: 1)
    }
}
