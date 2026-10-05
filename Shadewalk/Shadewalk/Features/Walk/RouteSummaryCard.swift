import ShadeFeatures
import SwiftUI

/// Summary of one route alternative: profile, time, distance and steps, the shade bar and metric chips.
/// Tapping it (when `onSelect` is set) selects the route.
struct RouteSummaryCard: View {
    let route: WalkRoute
    var isSelected: Bool = false
    var onSelect: (() -> Void)?

    @Environment(SettingsStore.self) private var settings
    @Environment(DepartureTimeModel.self) private var departureTime

    init(route: WalkRoute, isSelected: Bool = false, onSelect: (() -> Void)? = nil) {
        self.route = route
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    var body: some View {
        if let onSelect {
            Button(action: onSelect) {
                card
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityHint(Text("Shows this route on the map"))
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            metrics
            shadeBar
            RouteMetricChips(route: route)
        }
        .shadewalkCard()
        .overlay {
            if isSelected {
                Theme.cardShape.strokeBorder(route.profile.tint, lineWidth: 2)
            }
        }
        .contentShape(Theme.cardShape)
    }

    /// Profile title, the other profiles this route also satisfies as small tags, and the selection mark. The tags
    /// move under the title when they don't fit beside it.
    private var titleRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 8) {
                profileTitle
                alsoProfileTags
                Spacer(minLength: 8)
                selectionMark
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    profileTitle
                    Spacer(minLength: 8)
                    selectionMark
                }
                if !alsoProfiles.isEmpty {
                    WalkChipFlow(spacing: 6, lineSpacing: 6) {
                        alsoProfileTags
                    }
                }
            }
        }
    }

    private var profileTitle: some View {
        Label {
            Text(verbatim: route.profile.displayName)
        } icon: {
            Image(systemName: route.profile.systemImage)
        }
        .font(.cardTitle)
        .foregroundStyle(route.profile.tint)
    }

    /// One tag per other profile ("Fastest" beside "Shadiest"), read by VoiceOver as "Also the fastest".
    @ViewBuilder
    private var alsoProfileTags: some View {
        ForEach(alsoProfiles, id: \.self) { profile in
            ChipView(verbatim: profile.displayName, systemImage: profile.systemImage, tint: Theme.inkSecondary,
                     style: .outline)
                .accessibilityLabel(Text(verbatim: profile.alsoDescription))
        }
    }

    private var selectionMark: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? route.profile.tint : Theme.hairline)
            .accessibilityHidden(true)
    }

    /// Big walking time with distance, steps and arrival beside it (stacked when that doesn't fit).
    private var metrics: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                durationText
                    .fixedSize()
                details
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                durationText
                    .minimumScaleFactor(0.6)
                details
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var durationText: some View {
        Text(verbatim: Formatters.duration(route.duration))
            .font(.metricHero)
            .foregroundStyle(Theme.ink)
            .monospacedDigit()
            .lineLimit(1)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Formatters.distance(route.distance, units: settings.units)) · \(Formatters.steps(route.stepCount))")
                .foregroundStyle(Theme.ink)
            Text("Arrive \(Formatters.clockTime(route.arrival, timeZone: departureTime.timeZone))")
                .foregroundStyle(Theme.inkSecondary)
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var shadeBar: some View {
        if route.segments.isEmpty {
            ShadeBar(shadeFraction: route.shadeFraction)
        } else {
            ShadeBar(segments: route.segments)
        }
    }

    /// Other profiles this route also satisfies, e.g. `.fastest` for a route that is both shadiest and fastest.
    private var alsoProfiles: [RouteProfile] {
        var seen = Set<RouteProfile>()
        return route.profiles.filter { $0 != route.profile && seen.insert($0).inserted }
    }
}

/// Shade %, slope, time in the sun and cool spots as chips (wrapping onto several lines when needed).
struct RouteMetricChips: View {
    let route: WalkRoute

    private var flow: WalkChipFlow { WalkChipFlow(spacing: 6, lineSpacing: 6) }

    var body: some View {
        flow {
            ChipView(verbatim: shadeText, systemImage: "leaf.fill", tint: Theme.shade)
            if let category = slopeCategory {
                ChipView(verbatim: category.displayName, systemImage: "mountain.2.fill", tint: category.tint)
            }
            ChipView(verbatim: sunText, systemImage: "sun.max.fill", tint: Theme.sun)
            if !route.coolSpotIDs.isEmpty {
                ChipView(verbatim: coolSpotsText, systemImage: "thermometer.snowflake", tint: Theme.water)
            }
        }
    }

    private var shadeText: String {
        String(localized: "Shade \(Formatters.percent(route.shadeFraction))",
               comment: "Chip: share of the route in shade, e.g. “Shade 62%”.")
    }

    private var sunText: String {
        guard route.sunnyDistance >= 1, route.sunnyDuration >= 1 else {
            return String(localized: "No direct sun", comment: "Chip: the route is fully shaded.")
        }
        return String(localized: "Sun \(Formatters.duration(route.sunnyDuration))",
                      comment: "Chip: time spent in direct sun, e.g. “Sun 6 min”.")
    }

    private var coolSpotsText: String {
        String(localized: "\(route.coolSpotIDs.count) cool spots",
               comment: "Chip: number of cool spots (water, shade, cool interiors) along the route.")
    }

    private var slopeCategory: SlopeCategory? {
        guard let elevation = route.elevation, !elevation.bins.isEmpty else { return nil }
        return elevation.overallCategory
    }
}

private extension RouteProfile {
    /// "Also the fastest": a whole phrase per profile, so translations can inflect it.
    var alsoDescription: String {
        switch self {
        case .shadiest:
            return String(localized: "Also the shadiest", comment: "Route card: this route is also the shadiest one.")
        case .balanced:
            return String(localized: "Also balanced", comment: "Route card: this route is also the balanced one.")
        case .fastest:
            return String(localized: "Also the fastest", comment: "Route card: this route is also the fastest one.")
        }
    }
}

#if DEBUG
#Preview("Route summary card") {
    VStack(spacing: 12) {
        if let route = PreviewData.sampleRoute {
            RouteSummaryCard(route: route, isSelected: true, onSelect: {})
        }
        if let fastest = PreviewData.samplePlan.routes.last {
            RouteSummaryCard(route: fastest)
        }
    }
    .padding()
    .background(Theme.canvas)
    .previewEnvironment()
}
#endif
