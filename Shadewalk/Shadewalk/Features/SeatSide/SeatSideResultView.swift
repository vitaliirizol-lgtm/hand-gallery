import ShadeFeatures
import SwiftUI

/// Advice for a computed trip: the headline with its reason and the seat diagram, the sun timeline with trip metrics,
/// and a small map of the road the advice is based on.
struct SeatSideResultView: View {
    let advice: SeatSideAdvice
    let vehicle: VehicleKind
    let path: DrivingPath?
    /// Seconds.
    let tripDuration: TimeInterval
    /// Percent, 0–100; nil when unknown.
    let cloudCover: Double?

    var body: some View {
        VStack(spacing: Theme.spacing + 4) {
            recommendationCard
            if !advice.timeline.isEmpty {
                timelineCard
            }
            if let path, path.coordinates.count >= 2 {
                mapCard(path)
            }
        }
    }

    // MARK: - Recommendation

    private var recommendationCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            chips
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .font(.metricHero)
                    .foregroundStyle(headlineColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: reason)
                    .font(.body)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VehicleDiagramView(vehicle: vehicle, advice: advice)
                .frame(maxWidth: .infinity)
        }
        .shadewalkCard()
    }

    private var chips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                chipContent
            }
            VStack(alignment: .leading, spacing: 8) {
                chipContent
            }
        }
    }

    @ViewBuilder
    private var chipContent: some View {
        ChipView(verbatim: vehicle.displayName, systemImage: vehicle.systemImage)
        if let transition = sunTransition {
            ChipView(transition.title, systemImage: transition.systemImage, tint: Theme.sun)
        }
    }

    private var headline: LocalizedStringKey {
        switch advice.recommendation {
        case .left: return "Sit on the left"
        case .right: return "Sit on the right"
        case .either: return "Either side is fine"
        }
    }

    private var headlineColor: Color {
        switch advice.recommendation {
        case .left, .right: return Theme.shade
        case .either: return Theme.ink
        }
    }

    private var reason: String {
        let left = Formatters.percent(advice.sunOnLeftShare)
        let right = Formatters.percent(advice.sunOnRightShare)
        switch advice.reason {
        case .sunMostlyOnRight:
            return String(localized: "The sun hits the right side for \(right) of the trip.",
                          comment: "Seat-side reason. The value is a percentage, e.g. “78%”.")
        case .sunMostlyOnLeft:
            return String(localized: "The sun hits the left side for \(left) of the trip.",
                          comment: "Seat-side reason. The value is a percentage, e.g. “78%”.")
        case .balanced:
            if hasSideSun {
                return String(localized: "Both sides get about the same sun: \(left) on the left, \(right) on the right.",
                              comment: "Seat-side reason. Values are percentages of the side sunlight.")
            }
            return String(localized: "The sun stays ahead of or behind you, so neither side gets much of it.",
                          comment: "Seat-side reason when the sun is in front of or behind the vehicle.")
        case .sunDown:
            return String(localized: "The sun is down for the whole trip.",
                          comment: "Seat-side reason.")
        case .overcast:
            if let cloudCover {
                let cover = Formatters.percent(cloudCover / 100)
                return String(localized: "It’s overcast (\(cover) cloud cover), so neither side gets direct sun.",
                              comment: "Seat-side reason. The value is the cloud cover, e.g. “90%”.")
            }
            return String(localized: "It’s overcast, so neither side gets direct sun.",
                          comment: "Seat-side reason.")
        }
    }

    private var hasSideSun: Bool {
        advice.sunOnLeftShare + advice.sunOnRightShare > 0
    }

    /// Sunrise or sunset during the trip.
    private var sunTransition: (title: LocalizedStringKey, systemImage: String)? {
        guard advice.reason != .sunDown, let first = advice.timeline.first, let last = advice.timeline.last else {
            return nil
        }
        let startsInSun = first.sunSide != SunSide.none
        let endsInSun = last.sunSide != SunSide.none
        if startsInSun && !endsInSun {
            return (title: "Sun sets on the way", systemImage: "sunset.fill")
        }
        if !startsInSun && endsInSun {
            return (title: "Sun rises on the way", systemImage: "sunrise.fill")
        }
        return nil
    }

    // MARK: - Timeline & metrics

    private var timelineCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Sun along the way", systemImage: "sun.max.fill")
            SeatTimelineView(samples: advice.timeline)
            Divider()
            metrics
        }
        .shadewalkCard()
    }

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .leading)],
                  alignment: .leading, spacing: 14) {
            MetricView(value: Formatters.duration(tripDuration), caption: "Trip", systemImage: "clock")
            if hasSideSun {
                MetricView(value: Formatters.percent(advice.sunOnLeftShare), caption: "Sun on the left",
                           systemImage: "arrow.left", tint: shareTint(isDominant: advice.reason == .sunMostlyOnLeft))
                MetricView(value: Formatters.percent(advice.sunOnRightShare), caption: "Sun on the right",
                           systemImage: "arrow.right", tint: shareTint(isDominant: advice.reason == .sunMostlyOnRight))
            }
            if let cloudCover {
                MetricView(value: Formatters.percent(cloudCover / 100), caption: "Cloud cover",
                           systemImage: "cloud.fill")
            }
        }
    }

    /// The dominant sun side in readable orange (plain `sun` is too light for text in light mode).
    private func shareTint(isDominant: Bool) -> Color {
        isDominant ? Theme.sunInk : Theme.ink
    }

    // MARK: - Map

    private func mapCard(_ path: DrivingPath) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Route", systemImage: "map")
            SeatSideRouteMap(path: path)
                .frame(height: 180)
                .clipShape(Theme.controlShape)
                .overlay {
                    Theme.controlShape.strokeBorder(Theme.hairline, lineWidth: 0.5)
                }
            Text("Based on the road between your stops, so treat it as a guide: rails and bus lanes can differ a little.")
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .shadewalkCard()
    }
}

// MARK: - Idle explainer

/// Shown before the first computation: a small illustration and three steps.
struct SeatSideExplainerCard: View {
    let vehicle: VehicleKind

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SeatSideExplainerArt(vehicle: vehicle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            Text("How it works")
                .font(.cardTitle)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                step(systemImage: "mappin.and.ellipse", tint: Theme.shade,
                     text: "Choose where you get on and off, and when you leave.")
                step(systemImage: "sun.max.fill", tint: Theme.sun,
                     text: "Shadewalk follows the road and the sun, minute by minute.")
                step(systemImage: "person.fill", tint: Theme.shade,
                     text: "You get the side of the vehicle that stays in the shade.")
            }
        }
        .shadewalkCard()
    }

    private func step(systemImage: String, tint: Color, text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Decorative: shade on one side of the vehicle, sun rays hitting the other.
private struct SeatSideExplainerArt: View {
    let vehicle: VehicleKind

    @ScaledMetric(relativeTo: .largeTitle) private var badgeSize: CGFloat = 84

    init(vehicle: VehicleKind) {
        self.vehicle = vehicle
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 4) {
                Image(systemName: "leaf.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.shade)
                Text("Shade")
                    .font(.captionStrong)
                    .foregroundStyle(Theme.shade)
            }
            Image(systemName: vehicle.systemImage)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(Theme.shade)
                .frame(width: badgeSize, height: badgeSize)
                .background(Theme.shadeSoft, in: Circle())
            HStack(spacing: 2) {
                SeatSideSunRays(pointsTrailing: false)
                    .stroke(Theme.sun, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 4]))
                    .frame(width: 30, height: 44)
                VStack(spacing: 4) {
                    Image(systemName: "sun.max.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.sun)
                    Text("Sun")
                        .font(.captionStrong)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityHidden(true)
    }
}

#if DEBUG
/// Deterministic sample trip for the result previews: east, then north, on the reference afternoon.
private enum SeatSideResultPreviewData {
    static var path: DrivingPath {
        let from = PreviewData.originPlace.coordinate
        let to = PreviewData.point(2_200, 1_600)
        let corner = GeoCoordinate(latitude: from.latitude, longitude: to.longitude)
        let coordinates = GeoMath.resample([from, corner, to], spacing: 50)
        return DrivingPath(coordinates: coordinates, expectedTravelTime: GeoMath.length(of: coordinates) / 8)
    }

    static func advice(vehicle: VehicleKind, cloudCover: Double?) -> SeatSideAdvice {
        SeatSideAdvisor.advise(path: path.coordinates, departure: PreviewData.referenceDate,
                               duration: path.expectedTravelTime * vehicle.travelTimeFactor, cloudCover: cloudCover)
    }
}

#Preview("Result") {
    ScrollView {
        SeatSideResultView(advice: SeatSideResultPreviewData.advice(vehicle: .bus, cloudCover: 12),
                           vehicle: .bus,
                           path: SeatSideResultPreviewData.path,
                           tripDuration: SeatSideResultPreviewData.path.expectedTravelTime * 1.35,
                           cloudCover: 12)
            .padding()
    }
    .background(Theme.canvas)
    .previewEnvironment()
}

#Preview("Result – overcast") {
    ScrollView {
        SeatSideResultView(advice: SeatSideResultPreviewData.advice(vehicle: .train, cloudCover: 92),
                           vehicle: .train,
                           path: nil,
                           tripDuration: SeatSideResultPreviewData.path.expectedTravelTime * 0.9,
                           cloudCover: 92)
            .padding()
    }
    .background(Theme.canvas)
    .previewEnvironment()
}

#Preview("Explainer") {
    SeatSideExplainerCard(vehicle: .bus)
        .padding()
        .background(Theme.canvas)
}
#endif
