import ShadeFeatures
import SwiftUI

/// Everything about one route: headline metrics and chips, crossings / stairs / underpasses, the shade timeline,
/// the slope profile, cool spots on the way and turn-by-turn directions. Presented as a sheet from the Walk screen.
struct RouteDetailView: View {
    let route: WalkRoute
    private let onStart: (() -> Void)?

    @Environment(RoutePlannerModel.self) private var planner
    @Environment(SettingsStore.self) private var settings
    @Environment(DepartureTimeModel.self) private var departureTime
    @Environment(\.dismiss) private var dismiss

    /// - Parameter onStart: shows a Start button that calls this (the presenter dismisses the sheet and starts).
    init(route: WalkRoute, onStart: (() -> Void)? = nil) {
        self.route = route
        self.onStart = onStart
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerCard
                    countersCard
                    shadeCard
                    if let elevation = route.elevation, !elevation.bins.isEmpty {
                        SlopeChartView(profile: elevation, units: settings.units)
                    }
                    coolSpotsCard
                    directionsCard
                }
                .padding(Theme.screenPadding)
            }
            .background(Theme.canvas)
            .navigationTitle(Text("Route details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let onStart {
                    startBar(onStart)
                }
            }
        }
    }

    // MARK: - Header

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                Text(verbatim: route.profile.displayName)
            } icon: {
                Image(systemName: route.profile.systemImage)
            }
            .font(.cardTitle)
            .foregroundStyle(route.profile.tint)
            MetricView(value: Formatters.duration(route.duration), caption: "Walking time", size: .hero)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    secondaryMetrics
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 12) {
                    secondaryMetrics
                }
            }
            shadeBar(height: 12)
            RouteMetricChips(route: route)
        }
        .shadewalkCard()
    }

    @ViewBuilder
    private var secondaryMetrics: some View {
        MetricView(value: Formatters.distance(route.distance, units: settings.units), caption: "Distance",
                   systemImage: "point.topleft.down.curvedto.point.bottomright.up")
        MetricView(value: route.stepCount.formatted(), caption: "Steps", systemImage: "shoeprints.fill")
        MetricView(value: Formatters.clockTime(route.arrival, timeZone: departureTime.timeZone), caption: "Arrival",
                   systemImage: "clock")
    }

    @ViewBuilder
    private func shadeBar(height: CGFloat) -> some View {
        if route.segments.isEmpty {
            ShadeBar(shadeFraction: route.shadeFraction, height: height)
        } else {
            ShadeBar(segments: route.segments, height: height)
        }
    }

    // MARK: - Counters

    private var countersCard: some View {
        HStack(alignment: .top, spacing: 0) {
            counter(route.crossingCount, caption: "Crossings", systemImage: "figure.walk.circle")
            counterDivider
            counter(route.stairsCount, caption: "Stairs", systemImage: "figure.stairs")
            counterDivider
            counter(route.underpassCount, caption: "Underpasses", systemImage: "arrow.down.to.line")
        }
        .shadewalkCard(padding: 12)
    }

    private func counter(_ count: Int, caption: LocalizedStringKey, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Theme.shade)
                .accessibilityHidden(true)
            Text(verbatim: count.formatted())
                .font(.metricMedium)
                .foregroundStyle(Theme.ink)
            Text(caption)
                .font(.metricCaption)
                .foregroundStyle(Theme.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var counterDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1)
            .padding(.vertical, 6)
    }

    // MARK: - Shade timeline

    private var shadeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Shade along the way", systemImage: "leaf.fill")
            shadeBar(height: 18)
            HStack {
                Text("Start")
                Spacer()
                Text("Arrival")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Theme.inkSecondary)
            .accessibilityHidden(true)
            HStack(spacing: 18) {
                legendItem(isShaded: true, text: Text("Shade \(Formatters.duration(route.shadedDuration))"))
                legendItem(isShaded: false, text: Text("Sun \(Formatters.duration(route.sunnyDuration))"))
                Spacer(minLength: 0)
            }
        }
        .shadewalkCard()
    }

    private func legendItem(isShaded: Bool, text: Text) -> some View {
        HStack(spacing: 6) {
            legendSwatch(isShaded: isShaded)
                .accessibilityHidden(true)
            text
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func legendSwatch(isShaded: Bool) -> some View {
        if isShaded {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.shade)
                .frame(width: 16, height: 12)
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.sun)
                .overlay {
                    DiagonalStripes(spacing: 4)
                        .stroke(Color.white.opacity(0.5), lineWidth: 1.2)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .frame(width: 16, height: 12)
        }
    }

    // MARK: - Cool spots

    @ViewBuilder
    private var coolSpotsCard: some View {
        if !route.coolSpotIDs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader("Cool spots on the way", systemImage: "thermometer.snowflake")
                if routeCoolSpots.isEmpty {
                    Text("\(route.coolSpotIDs.count) cool spots within a short walk of this route.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                } else {
                    ForEach(routeCoolSpots) { item in
                        PlaceRow(title: item.spot.displayName, subtitle: item.subtitle,
                                 systemImage: item.spot.kind.systemImage, tint: item.spot.kind.tint,
                                 detail: item.distanceAlong.map { Formatters.distance($0, units: settings.units) })
                    }
                }
            }
            .shadewalkCard()
        }
    }

    /// Cool spots of this route found in the plan, in the order you reach them.
    private var routeCoolSpots: [RouteCoolSpotItem] {
        let ids = Set(route.coolSpotIDs)
        return planner.coolSpots
            .filter { ids.contains($0.id) }
            .map { spot in
                RouteCoolSpotItem(spot: spot, distanceAlong: WalkGeometry.distanceAlong(route, to: spot.coordinate))
            }
            .sorted { ($0.distanceAlong ?? .infinity) < ($1.distanceAlong ?? .infinity) }
    }

    // MARK: - Directions

    @ViewBuilder
    private var directionsCard: some View {
        if !directionItems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader("Directions", systemImage: "signpost.right.fill")
                    .padding(.bottom, 8)
                ForEach(directionItems) { item in
                    directionRow(item)
                    if item.id != directionItems.last?.id {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 1)
                            .padding(.leading, 46)
                    }
                }
            }
            .shadewalkCard()
        }
    }

    private var directionItems: [RouteDirectionItem] {
        let maneuvers = route.maneuvers
        return maneuvers.enumerated().map { index, maneuver in
            let next = index + 1 < maneuvers.count ? maneuvers[index + 1] : nil
            let leg = next.map { max(0, $0.distanceFromStart - maneuver.distanceFromStart) }
            return RouteDirectionItem(id: index, maneuver: maneuver, legLength: leg)
        }
    }

    private func directionRow(_ item: RouteDirectionItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.maneuver.kind.systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.shade)
                .frame(width: 34, height: 34)
                .background(Theme.shadeSoft, in: Circle())
                .accessibilityHidden(true)
            Text(verbatim: item.maneuver.instruction)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let leg = item.legLength, leg >= 1 {
                Text(verbatim: Formatters.distance(leg, units: settings.units))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Start

    private func startBar(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Start", systemImage: "figure.walk")
        }
        .buttonStyle(.shadewalkPrimary)
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Theme.canvas)
    }
}

/// A cool spot near the route and how far along the route it is.
private struct RouteCoolSpotItem: Identifiable {
    let spot: CoolSpot
    /// Metres from the start of the route.
    let distanceAlong: Double?

    var id: Int64 { spot.id }

    /// The kind, unless the spot is unnamed and already shows it as its name.
    var subtitle: String? {
        spot.displayName == spot.kind.displayName ? nil : spot.kind.displayName
    }
}

/// A maneuver and the distance walked until the next one.
private struct RouteDirectionItem: Identifiable {
    let id: Int
    let maneuver: Maneuver
    let legLength: Double?
}

#if DEBUG
#Preview("Route detail") {
    Group {
        if let route = PreviewData.sampleRoute {
            RouteDetailView(route: route, onStart: {})
        }
    }
    .previewEnvironment()
}
#endif
