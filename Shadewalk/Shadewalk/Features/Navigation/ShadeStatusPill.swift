import ShadeFeatures
import SwiftUI

/// "In the shade" / "Sun for 120 m" / "Shade for the rest of the way", always with an icon (never colour alone).
struct ShadeStatusPill: View {
    private let status: FollowShadeStatus
    private let units: UnitPreference

    init(route: WalkRoute, progress: RouteProgress?, units: UnitPreference = .system) {
        self.status = FollowShadeStatus(route: route, progress: progress)
        self.units = units
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                title
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                if let detail {
                    detail
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var title: Text {
        switch status {
        case .sunDown:
            return Text("The sun is down — all shade")
        case .shadeToTheEnd:
            return Text("Shade for the rest of the way")
        case .inShade:
            return Text("In the shade")
        case let .inSun(length):
            return Text("Sun for \(Formatters.distance(length, units: units))")
        }
    }

    private var detail: Text? {
        switch status {
        case let .inShade(sunAhead):
            guard let meters = sunAhead, meters >= 1 else { return nil }
            return Text("Sun in \(Formatters.distance(meters, units: units))")
        case .sunDown, .shadeToTheEnd, .inSun:
            return nil
        }
    }

    private var systemImage: String {
        switch status {
        case .sunDown: return "moon.stars.fill"
        case .shadeToTheEnd, .inShade: return "leaf.fill"
        case .inSun: return "sun.max.fill"
        }
    }

    private var tint: Color {
        switch status {
        case .sunDown: return Theme.inkSecondary
        case .shadeToTheEnd, .inShade: return Theme.shade
        case .inSun: return Theme.sun
        }
    }
}

#if DEBUG
#Preview("Shade status") {
    VStack(alignment: .leading, spacing: 12) {
        if let route = PreviewData.sampleRoute {
            ShadeStatusPill(route: route, progress: nil)
        }
        if let fastest = PreviewData.samplePlan.routes.last {
            ShadeStatusPill(route: fastest, progress: nil)
        }
    }
    .padding()
    .background(Theme.canvas)
    .previewEnvironment()
}
#endif
