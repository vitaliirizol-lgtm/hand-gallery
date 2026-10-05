import SwiftUI

/// Round floating map control on `.regularMaterial` (my location, layers, close). Icon-only, so an accessibility
/// label is required. `isActive` fills it with `shade` and adds the selected trait (e.g. shade overlay on).
///
/// The size follows Dynamic Type up to `maxDiameter`, so a column of controls never covers the map; at larger text
/// sizes a long press shows the Large Content Viewer instead.
struct FloatingIconButton: View {
    /// Largest diameter at any text size, points.
    static let maxDiameter: CGFloat = 60

    private let systemImage: String
    private let label: Text
    private let isActive: Bool
    private let tint: Color
    private let action: () -> Void

    @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 48

    init(systemImage: String, accessibilityLabel: LocalizedStringKey, isActive: Bool = false, tint: Color = Theme.ink,
         action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.label = Text(accessibilityLabel)
        self.isActive = isActive
        self.tint = tint
        self.action = action
    }

    private var size: CGFloat { min(diameter, FloatingIconButton.maxDiameter) }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(.title3, design: .default, weight: .semibold))
                .foregroundStyle(isActive ? Theme.onShade : tint)
                .frame(width: size, height: size)
                .background {
                    if isActive {
                        Circle().fill(Theme.shade)
                    } else {
                        Circle().fill(.regularMaterial)
                    }
                }
                .overlay {
                    Circle().strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
                .shadow(color: Theme.cardShadow, radius: 10, x: 0, y: 4)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : [.isButton])
        .accessibilityShowsLargeContentViewer {
            Label {
                label
            } icon: {
                Image(systemName: systemImage)
            }
        }
    }
}

#if DEBUG
#Preview("Floating buttons") {
    HStack(spacing: 16) {
        FloatingIconButton(systemImage: "location.fill", accessibilityLabel: "Show my location") {}
        FloatingIconButton(systemImage: "square.3.layers.3d", accessibilityLabel: "Map layers", isActive: true) {}
    }
    .padding(40)
    .background(Theme.canvas)
}
#endif
