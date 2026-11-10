import AppKit
import SwiftUI

/// The "Island" look every MacApp shares: ink and soft layered surfaces, one mint
/// accent, small caps labels, rolling numbers and one spring.
///
/// This file is repeated in each app on purpose (like `Host.swift`), so no Kit
/// depends on another. Keep the copies identical: change one, copy it to the rest.
enum IslandTheme {
    // MARK: Colors

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }

    /// Islands and popups: always black, like the notch.
    static let ink = Color.black
    /// A full window's background; follows the system appearance.
    static let window = dynamic(
        light: NSColor(srgbRed: 0.96, green: 0.96, blue: 0.95, alpha: 1),
        dark: NSColor(srgbRed: 0.055, green: 0.055, blue: 0.063, alpha: 1)
    )
    /// The one accent. Darker in light windows so text in it stays readable.
    static let accent = dynamic(
        light: NSColor(srgbRed: 0.04, green: 0.48, blue: 0.345, alpha: 1),
        dark: NSColor(srgbRed: 0.24, green: 0.85, blue: 0.64, alpha: 1)
    )
    static let card = dynamic(light: gray(1), dark: gray(1, 0.07))
    static let row = dynamic(light: gray(0, 0.04), dark: gray(1, 0.05))
    static let rowHover = dynamic(light: gray(0, 0.08), dark: gray(1, 0.11))
    static let selected = dynamic(light: gray(0, 0.12), dark: gray(1, 0.16))
    static let control = dynamic(light: gray(0, 0.07), dark: gray(1, 0.1))
    static let controlHover = dynamic(light: gray(0, 0.12), dark: gray(1, 0.16))
    static let hairline = dynamic(light: gray(0, 0.1), dark: gray(1, 0.1))
    static let secondary = dynamic(light: gray(0, 0.62), dark: gray(1, 0.6))
    static let warning = Color.orange

    // MARK: Shape

    enum Radius {
        static let row: CGFloat = 8
        static let control: CGFloat = 9
        static let card: CGFloat = 12
        static let panel: CGFloat = 24
    }

    // MARK: Motion

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The one spring; a short ease with Reduce Motion on.
    static func spring(_ response: Double = 0.42, damping: Double = 0.82) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: response, dampingFraction: damping)
    }
}

// MARK: - Text

/// A small caps label above a value or a group.
struct IslandLabel: View {
    let text: String
    var color: Color = IslandTheme.secondary

    init(_ text: String, color: Color = IslandTheme.secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .medium))
            .kerning(0.3)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

extension View {
    /// A time or count: even-width digits that roll when the value changes.
    func islandNumber<V: Equatable>(size: CGFloat = 22, weight: Font.Weight = .semibold, value: V) -> some View {
        font(.system(size: size, weight: weight).monospacedDigit())
            .contentTransition(.numericText())
            .animation(IslandTheme.spring(), value: value)
    }

    /// The soft card every group of content sits on.
    func islandCard(padding: CGFloat = 14, radius: CGFloat = IslandTheme.Radius.card) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(IslandTheme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// A list row: brighter when hovered, brighter still when selected.
    func islandRow(selected: Bool = false, hovering: Bool = false) -> some View {
        background(
            selected ? IslandTheme.selected : (hovering ? IslandTheme.rowHover : IslandTheme.row),
            in: RoundedRectangle(cornerRadius: IslandTheme.Radius.row, style: .continuous)
        )
    }

    /// A full window's background.
    func islandWindow() -> some View {
        background(IslandTheme.window.ignoresSafeArea())
    }

    /// Lifts slightly while the pointer is over it.
    func islandHoverLift() -> some View {
        modifier(IslandHoverLift())
    }
}

private struct IslandHoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !IslandTheme.reduceMotion ? 1.02 : 1)
            .brightness(hovering ? 0.03 : 0)
            .onHover { hovering = $0 }
            .animation(IslandTheme.spring(0.3, damping: 0.7), value: hovering)
    }
}

// MARK: - Containers

/// A titled card: the settings pattern (instead of a grouped form) and any
/// labelled group of content.
struct IslandSection<Content: View>: View {
    let title: String?
    var footer: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 10) {
                if let title { IslandLabel(title) }
                content
            }
            .islandCard()
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(IslandTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// A thin line between rows in a card.
struct IslandDivider: View {
    var body: some View {
        Rectangle().fill(IslandTheme.hairline).frame(height: 1)
    }
}

/// One setting: its name (and an optional note) on the left, its control on the right.
struct IslandSettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(IslandTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
    }
}

/// A switch in the accent colour, as a setting row.
struct IslandToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        IslandSettingRow(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(IslandTheme.accent)
        }
    }
}

// MARK: - Controls

/// The shared button: a solid primary one, or a soft secondary one. Brightens on
/// hover and presses in.
struct IslandButtonStyle: ButtonStyle {
    var primary = false
    var height: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, primary: primary, height: height)
    }

    private struct Label: View {
        let configuration: Configuration
        let primary: Bool
        let height: CGFloat
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: primary ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minHeight: height)
                .foregroundStyle(primary ? IslandTheme.window : Color.primary)
                .background(
                    primary
                        ? AnyShapeStyle(Color.primary.opacity(hovering ? 0.85 : 0.95))
                        : AnyShapeStyle(hovering ? IslandTheme.controlHover : IslandTheme.control),
                    in: RoundedRectangle(cornerRadius: IslandTheme.Radius.control, style: .continuous)
                )
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed && !IslandTheme.reduceMotion ? 0.96 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
        }
    }
}

/// A segmented control whose highlight glides between the options.
struct IslandSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    @Namespace private var namespace

    init(_ options: [(value: Value, label: String)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    withAnimation(IslandTheme.spring(0.3, damping: 0.8)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : IslandTheme.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 24)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(IslandTheme.selected)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(IslandTheme.control, in: RoundedRectangle(cornerRadius: IslandTheme.Radius.control, style: .continuous))
    }
}

/// A key as printed on a keyboard, or a shortcut's key. `highlighted` marks a result.
struct IslandKeyCap: View {
    let text: String
    var highlighted = false

    init(_ text: String, highlighted: Bool = false) {
        self.text = text
        self.highlighted = highlighted
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(highlighted ? IslandTheme.accent : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(highlighted ? Color.clear : IslandTheme.row, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(highlighted ? IslandTheme.accent : Color.primary.opacity(0.25))
            )
    }
}

/// A dot for something running right now; it breathes (still with Reduce Motion on).
struct IslandLiveDot: View {
    var color: Color = IslandTheme.accent
    var size: CGFloat = 7
    var live = true
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(live && dim ? 0.5 : 1)
            .onAppear {
                guard live, !IslandTheme.reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}
