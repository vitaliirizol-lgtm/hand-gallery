import SwiftUI

/// The day's light as a gradient — dawn amber → noon orange-red → dusk violet — for departure-time slider tracks.
enum SunGradient {
    /// Dawn amber `#FFB547`.
    static let dawn = Color(red: 1.0, green: 0.710, blue: 0.278)
    /// Noon orange-red `#FF5A36`.
    static let noon = Color(red: 1.0, green: 0.353, blue: 0.212)
    /// Dusk violet `#7A5CDB`.
    static let dusk = Color(red: 0.478, green: 0.361, blue: 0.859)

    static var gradient: Gradient {
        Gradient(colors: [dawn, noon, dusk])
    }

    /// Left (sunrise) to right (sunset).
    static var horizontal: LinearGradient {
        linear()
    }

    static func linear(startPoint: UnitPoint = .leading, endPoint: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(gradient: gradient, startPoint: startPoint, endPoint: endPoint)
    }
}

/// Capsule filled with the sun gradient (a slider track).
struct SunGradientTrack: View {
    var height: CGFloat = 6

    var body: some View {
        Capsule()
            .fill(SunGradient.horizontal)
            .frame(height: height)
            .accessibilityHidden(true)
    }
}
