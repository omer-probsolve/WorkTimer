import SwiftUI

/// What Work Timer adds on top of the shared `IslandTheme` (which is copied
/// between apps and never edited here).

extension Color {
    /// The empty background of lanes and heat-map cells.
    static let trackFill = IslandTheme.control
}

extension AnyTransition {
    /// How rows and lanes arrive and leave: a short slide with a fade, or just
    /// the fade with Reduce Motion on.
    static var islandAppear: AnyTransition {
        IslandTheme.reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
    }
}

extension View {
    /// The soft box a chart sits in: quieter than a card, so the tracks and
    /// bars inside it stand out.
    func islandSoftCard(padding: CGFloat = 14) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IslandTheme.row, in: RoundedRectangle(cornerRadius: IslandTheme.Radius.card, style: .continuous))
    }

    /// An always-dark floating card (hover cards, the menu bar window): ink with
    /// a hairline edge so it reads on dark and light backgrounds alike.
    func islandInk(radius: CGFloat = IslandTheme.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(IslandTheme.ink, in: shape)
            .overlay(shape.strokeBorder(IslandTheme.hairline, lineWidth: 1))
            .clipShape(shape)
            .tint(IslandTheme.accent)
            .environment(\.colorScheme, .dark)
    }
}

/// A square icon button on the theme's control fill.
struct IslandIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, size: size)
    }

    private struct Label: View {
        let configuration: Configuration
        let size: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .frame(width: size, height: size)
                .background(
                    hovering ? IslandTheme.controlHover : IslandTheme.control,
                    in: RoundedRectangle(cornerRadius: IslandTheme.Radius.control, style: .continuous)
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !IslandTheme.reduceMotion ? 0.94 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(IslandTheme.spring(0.2, damping: 0.7), value: configuration.isPressed)
        }
    }
}

/// A text-only button in the accent color, for "Show all" and "Open…".
struct IslandLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(IslandTheme.accent)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}
