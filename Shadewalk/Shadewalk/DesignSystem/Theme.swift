import MapKit
import ShadeFeatures
import SwiftUI

/// Shadewalk design tokens (SPEC §6): calm, cool, legible in harsh sunlight.
///
/// Colours come from the asset catalog with light / dark appearances.
enum Theme {
    // MARK: - Colour

    /// Deep green accent; shaded route runs. `#0E7A55` / `#3DDC97`.
    static let shade = Color("Shade")
    /// Soft green fill behind shade-tinted content. `#DDF5EA` / `#123528`.
    static let shadeSoft = Color("ShadeSoft")
    /// Orange for sun exposure; sunny route runs. `#FF8A2A` / `#FF9F4D`.
    static let sun = Color("Sun")
    /// Red for heat warnings and errors. `#E5484D`.
    static let heat = Color("Heat")
    /// Primary text. `#0F1A17` / `#F2F7F5`.
    static let ink = Color("Ink")
    /// Secondary text (ink at 60 %).
    static let inkSecondary = Color("InkSecondary")
    /// Cards and sheets. White / `#101615`.
    static let surface = Color("Surface")
    /// Screen background behind cards. `#F3F7F5` / `#070B0A`.
    static let canvas = Color("Canvas")
    /// Text and icons on a `shade` fill (white in light mode, near-black on the mint dark-mode accent). Every tint used
    /// as a solid fill (chips, badges) is dark in light mode and light in dark mode, so this works on all of them.
    static let onShade = Color("Surface")
    /// Hairlines and quiet fills.
    static let hairline = Color("InkSecondary").opacity(0.18)
    /// Soft card shadow.
    static let cardShadow = Color.black.opacity(0.08)

    // MARK: - Readable variants

    /// Sun orange for text and small glyphs on `surface` / `canvas` (`sun` itself is too light to read in light
    /// mode). `#A85200` / `#FF9F4D`.
    static let sunInk = Color("SunInk")
    /// Deep orange fill under white glyphs (e.g. swipe actions), in both appearances. `#A85200` / `#B35A00`.
    static let sunFill = Color("SunFill")
    /// Shade green for labels on a faint `shade` fill (secondary buttons). `#0B5E41` / `#3DDC97`.
    static let shadeInk = Color("ShadeInk")
    /// Heat red for labels on a faint `heat` fill (destructive secondary buttons). `#B4232A` / `#FF6B70`.
    static let heatInk = Color("HeatInk")

    // MARK: - Domain colours

    /// Drinking water and cool spots in general. `#0B7285` / `#4FD1E8`.
    static let water = Color("Water")
    /// Cool indoor places. `#5146D9` / `#A5A0FF`.
    static let indoor = Color("Indoor")
    /// UV index 3–5 ("moderate"). `#A67C00` / `#FFD60A`.
    static let uvModerate = Color("UVModerate")
    /// UV index 11+ ("extreme"). `#7E3FB8` / `#C58AF9`.
    static let uvExtreme = Color("UVExtreme")
    /// "My Location". `#0060D6` / `#5AA3FF`.
    static let locator = Color("Locator")

    // MARK: - Shape & spacing

    /// Cards and sheets (continuous corners).
    static let cornerRadius: CGFloat = 20
    /// Bottom panels docked to the screen edge and large illustration tiles.
    static let sheetCornerRadius: CGFloat = 28
    /// Buttons, fields and inner tiles.
    static let controlCornerRadius: CGFloat = 14
    /// Chips are capsules.
    static let chipCornerRadius: CGFloat = 999
    /// Inner padding of cards.
    static let cardPadding: CGFloat = 16
    /// Horizontal screen margin.
    static let screenPadding: CGFloat = 16
    /// Default vertical spacing between stacked elements.
    static let spacing: CGFloat = 12

    /// Card shape.
    static var cardShape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    /// Control shape.
    static var controlShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: controlCornerRadius, style: .continuous)
    }

    // MARK: - Map

    /// `.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll)`.
    static var mapStyle: MapStyle {
        .standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll)
    }

    /// Fill for shade-overlay polygons: light-mode `ink` at 18 %, black at 40 % in dark mode, so shadows always darken
    /// the map.
    static let shadeOverlayFill = Color("ShadeOverlay")
    /// Stroke width of the selected route.
    static let selectedRouteWidth: CGFloat = 7
    /// Stroke width of alternative routes.
    static let alternateRouteWidth: CGFloat = 5
    /// Colour of alternative routes.
    static var alternateRouteColor: Color { inkSecondary }

    /// Colour of a route run: `shade` when shaded, `sun` when sunny.
    static func routeColor(isShaded: Bool) -> Color {
        isShaded ? shade : sun
    }

    /// Stroke of a route run. Sunny runs of the selected route are dashed so shade vs. sun is never colour-only.
    static func routeStroke(isShaded: Bool, isSelected: Bool = true) -> StrokeStyle {
        let width = isSelected ? selectedRouteWidth : alternateRouteWidth
        if isShaded || !isSelected {
            return StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
        }
        return StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: [width * 1.6, width * 1.1])
    }

    // MARK: - Motion

    /// Sheets and cards.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Small state changes (chips, toggles).
    static let quickSpring = Animation.spring(response: 0.28, dampingFraction: 0.9)
}

// MARK: - Reduce Motion

private struct MotionAwareAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `.animation(_:value:)` that is switched off when Reduce Motion is on.
    func motionAwareAnimation<Value: Equatable>(_ animation: Animation = Theme.spring, value: Value) -> some View {
        modifier(MotionAwareAnimation(animation: animation, value: value))
    }
}

/// `withAnimation` that skips the animation when Reduce Motion is on (read `\.accessibilityReduceMotion` in the view).
@MainActor
func withMotionAwareAnimation<Result>(reduceMotion: Bool, _ animation: Animation = Theme.spring,
                                      _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(reduceMotion ? nil : animation, body)
}

// MARK: - Domain tints

extension RouteProfile {
    var tint: Color {
        switch self {
        case .shadiest: return Theme.shade
        case .balanced: return Theme.shade
        case .fastest: return Theme.ink
        }
    }
}

extension SlopeCategory {
    /// Bar / chip colour by steepness (always paired with a label).
    var tint: Color {
        switch self {
        case .flat: return Theme.shade
        case .gentle: return Theme.shade.opacity(0.65)
        case .moderate: return Theme.sun
        case .steep: return Theme.heat
        }
    }
}

extension CoolSpotKind {
    var tint: Color {
        switch self {
        case .drinkingWater: return Theme.water
        case .indoorCool: return Theme.indoor
        case .shelter: return Theme.inkSecondary
        case .park: return Theme.shade
        }
    }
}

extension PlaceKind {
    var tint: Color {
        switch self {
        case .currentLocation: return Theme.locator
        case .home, .work: return Theme.shade
        case .favorite: return Theme.sun
        case .searchResult, .droppedPin: return Theme.inkSecondary
        case .coolSpot: return Theme.shade
        }
    }
}
