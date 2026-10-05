import ShadeFeatures
import SwiftUI

/// Next instruction in follow mode: maneuver symbol, distance to it and the localized instruction
/// ("Turn left onto Linden Avenue", "Cross the street", "Take the stairs", "Arrive at your destination").
struct ManeuverBanner: View {
    private let maneuver: Maneuver?
    private let distance: Double?
    private let units: UnitPreference

    @ScaledMetric(relativeTo: .title) private var iconSize: CGFloat = 56

    /// Inner padding of the banner; the icon tile's corners stay concentric with the card's.
    private static let contentInset: CGFloat = 14

    /// - Parameters:
    ///   - maneuver: next maneuver; nil shows "Follow the route".
    ///   - distance: metres to the maneuver, if known.
    init(maneuver: Maneuver?, distance: Double?, units: UnitPreference = .system) {
        self.maneuver = maneuver
        self.distance = distance
        self.units = units
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: maneuver?.kind.systemImage ?? "arrow.up")
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(Theme.shade)
                .frame(width: tileSize, height: tileSize)
                .background(Theme.onShade,
                            in: RoundedRectangle(cornerRadius: Theme.cornerRadius - ManeuverBanner.contentInset,
                                                 style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let distanceText {
                    Text(verbatim: distanceText)
                        .font(.metricLarge)
                        .foregroundStyle(Theme.onShade)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                instruction
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.onShade)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(ManeuverBanner.contentInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.shade, in: Theme.cardShape)
        .shadow(color: Theme.cardShadow, radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(instruction)
        .accessibilityValue(Text(verbatim: distanceText ?? ""))
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// Grows with the text size, but not so much that it hides the map.
    private var tileSize: CGFloat { min(iconSize, 72) }

    private var instruction: Text {
        if let maneuver {
            return Text(verbatim: maneuver.instruction)
        }
        return Text("Follow the route")
    }

    private var distanceText: String? {
        guard let distance, distance.isFinite, maneuver != nil else { return nil }
        return Formatters.distance(distance, units: units)
    }
}

#if DEBUG
#Preview("Maneuver banner") {
    VStack(spacing: 12) {
        ManeuverBanner(maneuver: Maneuver(kind: .left, streetName: "Linden Avenue", distanceFromStart: 120,
                                          coordinate: PreviewData.downtown),
                       distance: 80)
        ManeuverBanner(maneuver: Maneuver(kind: .takeStairs, streetName: nil, distanceFromStart: 300,
                                          coordinate: PreviewData.downtown),
                       distance: 35)
        ManeuverBanner(maneuver: nil, distance: nil)
    }
    .padding()
    .background(Theme.canvas)
    .previewEnvironment()
}
#endif
