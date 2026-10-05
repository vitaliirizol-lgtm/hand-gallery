import SwiftUI

/// Visual weight of a chip.
enum ChipStyle: Hashable, Sendable {
    /// Tinted icon on a faint tint fill (default; metric chips such as "62% shade").
    case soft
    /// Solid tint fill (selected filters, highlights).
    case filled
    /// Hairline outline (unselected filters).
    case outline
}

/// Capsule chip: icon + text + tint. Meaning never relies on colour alone — always pass a label (and ideally an icon).
struct ChipView: View {
    private let title: Text
    private let systemImage: String?
    private let tint: Color
    private let style: ChipStyle

    /// Localized title, e.g. `ChipView("Flat", systemImage: "arrow.right")`.
    init(_ title: LocalizedStringKey, systemImage: String? = nil, tint: Color = Theme.shade, style: ChipStyle = .soft) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.tint = tint
        self.style = style
    }

    /// Already-formatted text, e.g. `ChipView(verbatim: Formatters.percent(route.shadeFraction), …)`.
    init(verbatim title: String, systemImage: String? = nil, tint: Color = Theme.shade, style: ChipStyle = .soft) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
        self.tint = tint
        self.style = style
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .foregroundStyle(iconColor)
                    .accessibilityHidden(true)
            }
            title
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .font(.chipLabel)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(fillColor, in: Capsule())
        .overlay {
            if style == .outline {
                Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var fillColor: Color {
        switch style {
        case .soft: return tint.opacity(0.14)
        case .filled: return tint
        case .outline: return Color.clear
        }
    }

    private var iconColor: Color {
        switch style {
        case .soft, .outline: return tint
        case .filled: return Theme.onShade
        }
    }

    private var textColor: Color {
        switch style {
        case .soft, .outline: return Theme.ink
        case .filled: return Theme.onShade
        }
    }
}

/// Toggleable filter chip (e.g. cool-spot kinds, vehicle picker). Selected chips are filled and carry a checkmark,
/// so the state doesn't depend on colour.
struct FilterChip: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    var tint: Color = Theme.shade
    let action: () -> Void

    init(title: String, systemImage: String, isSelected: Bool, tint: Color = Theme.shade,
         action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isSelected = isSelected
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ChipView(verbatim: title, systemImage: isSelected ? "checkmark" : systemImage, tint: tint,
                     style: isSelected ? .filled : .outline)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

#if DEBUG
#Preview("Chips") {
    VStack(alignment: .leading, spacing: 12) {
        HStack {
            ChipView(verbatim: "62%", systemImage: "leaf.fill")
            ChipView("Gentle", systemImage: "arrow.up.right", tint: Theme.shade)
            ChipView(verbatim: "4 min sun", systemImage: "sun.max.fill", tint: Theme.sun)
        }
        HStack {
            FilterChip(title: "Drinking water", systemImage: "drop.fill", isSelected: true) {}
            FilterChip(title: "Park", systemImage: "tree.fill", isSelected: false) {}
        }
    }
    .padding()
    .background(Theme.canvas)
}
#endif
