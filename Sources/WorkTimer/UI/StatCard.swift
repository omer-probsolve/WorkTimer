import SwiftUI
import WorkTimerCore

/// A totals card: title, a duration, an optional multiplier badge and a second
/// line. Used for the popover's cards and the dashboard's filter cards.
struct StatCard: View {
    enum Size { case compact, regular }

    static let shape = RoundedRectangle(cornerRadius: IslandTheme.Radius.card, style: .continuous)

    let title: String
    let color: Color
    let value: TimeInterval
    /// `.some(nil)` shows an empty badge ("—"); nil shows none.
    var badge: Double?? = nil
    var subtitle: String?
    var subtitleHelp = ""
    var live = false
    var size: Size = .regular
    /// Outlined: the one the session table is showing.
    var selected = false
    /// Shows a clear button while selected.
    var onClear: (() -> Void)?

    var body: some View {
        let clock = Format.clock(value, seconds: false)
        VStack(alignment: .leading, spacing: size == .compact ? 2 : 4) {
            HStack(spacing: 6) {
                LiveDot(color: color, live: live, keepsSpace: false)
                IslandLabel(title, color: color)
                Spacer(minLength: 0)
                if selected, let onClear {
                    Button(action: onClear) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(IslandTheme.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show all sessions")
                }
            }
            HStack(spacing: 6) {
                Text(clock)
                    .islandNumber(size: size == .compact ? 16 : 22, value: clock)
                    .lineLimit(1)
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
        .padding(size == .compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(IslandTheme.card, in: Self.shape)
        .liveEdge(color, live: live)
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(Color.primary.opacity(selected ? 0.4 : 0), lineWidth: 1))
        .animation(IslandTheme.spring(), value: selected)
    }
}
