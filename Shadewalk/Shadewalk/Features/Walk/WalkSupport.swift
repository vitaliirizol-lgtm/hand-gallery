import ShadeFeatures
import SwiftUI

// Small building blocks shared by the Walk and follow-mode screens.

// MARK: - Chip flow layout

/// Lays chips out left to right and wraps onto new lines when they don't fit.
struct WalkChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for (offset, index) in row.indices.enumerated() {
                let size = row.sizes[offset]
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            if !current.indices.isEmpty, current.width + spacing + size.width > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width += (current.indices.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
            current.sizes.append(size)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Map styling

enum WalkMapStyle {
    /// White casing drawn under the selected route so it reads on any map background.
    static var casing: StrokeStyle {
        StrokeStyle(lineWidth: Theme.selectedRouteWidth + 4, lineCap: .round, lineJoin: .round)
    }

    /// Already-walked part of a route in follow mode.
    static var passed: StrokeStyle {
        StrokeStyle(lineWidth: Theme.alternateRouteWidth, lineCap: .round, lineJoin: .round)
    }

    /// Most shade-overlay polygons drawn at once (keeps the map responsive).
    static let maxOverlayPolygons = 1_500
    /// Most cool-spot annotations drawn at once.
    static let maxCoolSpotAnnotations = 150
}

/// Round material icon matching `FloatingIconButton` (same size limit), for use as a `Menu` label.
struct WalkFloatingIconLabel: View {
    private let systemImage: String
    private let isActive: Bool

    @ScaledMetric(relativeTo: .title3) private var diameter: CGFloat = 48

    init(systemImage: String, isActive: Bool = false) {
        self.systemImage = systemImage
        self.isActive = isActive
    }

    private var size: CGFloat { min(diameter, FloatingIconButton.maxDiameter) }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(.title3, design: .default, weight: .semibold))
            .foregroundStyle(isActive ? Theme.onShade : Theme.ink)
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
}

/// Small capsule message floating over the map ("Zoom in to see shade").
struct WalkMapHint<Icon: View>: View {
    private let text: Text
    private let icon: Icon

    init(_ text: LocalizedStringKey, @ViewBuilder icon: () -> Icon) {
        self.text = Text(text)
        self.icon = icon()
    }

    var body: some View {
        HStack(spacing: 6) {
            icon
                .accessibilityHidden(true)
            text
                .lineLimit(2)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
        .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Weather

/// WHO UV index bands; always shown with their name, never by colour alone.
enum WalkUVLevel: Hashable {
    case low, moderate, high, veryHigh, extreme

    init(index: Int) {
        switch index {
        case ..<3: self = .low
        case 3..<6: self = .moderate
        case 6..<8: self = .high
        case 8..<11: self = .veryHigh
        default: self = .extreme
        }
    }

    var displayName: String {
        switch self {
        case .low: return String(localized: "Low", comment: "UV index band (0–2).")
        case .moderate: return String(localized: "Moderate", comment: "UV index band (3–5).")
        case .high: return String(localized: "High", comment: "UV index band (6–7).")
        case .veryHigh: return String(localized: "Very high", comment: "UV index band (8–10).")
        case .extreme: return String(localized: "Extreme", comment: "UV index band (11+).")
        }
    }

    var tint: Color {
        switch self {
        case .low: return Theme.shade
        case .moderate: return Theme.uvModerate
        case .high: return Theme.sun
        case .veryHigh: return Theme.heat
        case .extreme: return Theme.uvExtreme
        }
    }
}

extension WeatherSnapshot {
    /// SF Symbol for the sky (day / night, cloud cover).
    var walkSymbolName: String {
        let clouds = cloudCover ?? 0
        if !isDay { return clouds >= 60 ? "cloud.moon.fill" : "moon.stars.fill" }
        if clouds >= 80 { return "cloud.fill" }
        if clouds >= 35 { return "cloud.sun.fill" }
        return "sun.max.fill"
    }

    /// What `walkSymbolName` shows, in words (VoiceOver).
    var walkSkyDescription: String {
        let clouds = cloudCover ?? 0
        if !isDay {
            return clouds >= 60
                ? String(localized: "Cloudy night", comment: "Sky in the weather pill: night with clouds.")
                : String(localized: "Clear night", comment: "Sky in the weather pill: night, few clouds.")
        }
        if clouds >= 80 { return String(localized: "Cloudy", comment: "Sky in the weather pill: overcast day.") }
        if clouds >= 35 {
            return String(localized: "Partly cloudy", comment: "Sky in the weather pill: sun and clouds.")
        }
        return String(localized: "Clear sky", comment: "Sky in the weather pill: sunny day, few clouds.")
    }
}

// MARK: - Places

extension CoolSpot {
    /// The spot as a walking destination.
    var walkPlace: Place {
        Place(id: "cool-spot-\(id)", name: displayName, subtitle: kind.displayName, coordinate: coordinate,
              kind: .coolSpot)
    }
}
