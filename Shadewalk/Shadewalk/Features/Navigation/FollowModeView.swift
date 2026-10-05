import MapKit
import ShadeFeatures
import SwiftUI
import UIKit

/// Live navigation ("follow mode"), presented full screen by the Walk tab after `NavigationModel.start(route:)`.
///
/// The camera follows the walker (heading up); the rest of the route is coloured by shade and sun. A banner shows the
/// next maneuver, a pill the shade situation, and the bottom card the remaining time, distance, arrival and
/// shade / sun split. Navigation events drive haptics (and VoiceOver announcements) through one `.task`. The screen
/// stays awake while open. Dismissing it (End, or Done after arriving) lets the presenter call `NavigationModel.stop()`.
struct FollowModeView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(LocationModel.self) private var location
    @Environment(SettingsStore.self) private var settings
    @Environment(DepartureTimeModel.self) private var departureTime
    @Environment(\.dismiss) private var dismiss

    @Namespace private var mapScope
    @State private var camera: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var isConfirmingEnd = false
    @State private var arrival: FollowArrivalSummary?
    @State private var haptic = FollowHaptic()
    /// Distance walked in this session (all routes, including reroutes), metres.
    @State private var walked = FollowWalkedDistance()

    var body: some View {
        content
            .sensoryFeedback(trigger: haptic) { _, newValue in
                newValue.feedback
            }
            .task {
                await listenForEvents()
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                UIApplication.shared.isIdleTimerDisabled = false
            }
            .onChange(of: navigation.progress) { _, progress in
                walked.record(progress, on: navigation.route)
            }
            .onChange(of: navigation.status, initial: true) { _, status in
                statusChanged(status)
            }
            .confirmationDialog("End this walk?", isPresented: $isConfirmingEnd, titleVisibility: .visible) {
                Button("End walk", role: .destructive) {
                    finish()
                }
                Button("Keep walking", role: .cancel) {}
            }
            .sheet(item: $arrival, onDismiss: { finish() }) { summary in
                FollowArrivalSheet(summary: summary) {
                    arrival = nil
                }
                .presentationDetents([.medium, .large])
            }
    }

    @ViewBuilder
    private var content: some View {
        if let route = navigation.route {
            following(route)
        } else {
            noWalk
        }
    }

    // MARK: - Following

    private func following(_ route: WalkRoute) -> some View {
        let geometry = FollowRouteGeometry(route: route, distanceAlong: navigation.progress?.distanceAlong ?? 0)
        return FollowMapView(camera: $camera, mapScope: mapScope, geometry: geometry, destination: route.destination)
            .overlay(alignment: .topTrailing) {
                mapButtons
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                topStack(route)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                FollowStatsCard(route: route, progress: navigation.progress,
                                remainingSegments: geometry.remainingSegments, units: settings.units,
                                timeZone: departureTime.timeZone) {
                    isConfirmingEnd = true
                }
            }
            .mapScope(mapScope)
    }

    private func topStack(_ route: WalkRoute) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ManeuverBanner(maneuver: currentManeuver(on: route), distance: navigation.progress?.distanceToNextManeuver,
                           units: settings.units)
            routeAlert
            HStack(spacing: 8) {
                ShadeStatusPill(route: route, progress: navigation.progress, units: settings.units)
                Spacer(minLength: 0)
            }
            if navigation.lastFix == nil, navigation.status == .navigating {
                locationHint
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .motionAwareAnimation(value: navigation.status)
    }

    @ViewBuilder
    private var locationHint: some View {
        switch location.authorization {
        case .denied, .restricted:
            WalkMapHint("Location is off. Turn it on in Settings to follow your walk.") {
                Image(systemName: "location.slash.fill")
            }
        case .notDetermined, .authorized:
            WalkMapHint("Waiting for your location…") {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    /// Next maneuver; before the first fix, the first one ("Head out on …").
    private func currentManeuver(on route: WalkRoute) -> Maneuver? {
        guard let progress = navigation.progress else { return route.maneuvers.first }
        return progress.nextManeuver
    }

    @ViewBuilder
    private var routeAlert: some View {
        switch navigation.status {
        case .offRoute:
            FollowAlertBanner(systemImage: "arrow.uturn.backward.circle.fill", tint: Theme.heat,
                              title: "You’ve left the route", message: offRouteMessage)
        case .rerouting:
            FollowAlertBanner(systemImage: "arrow.triangle.branch", tint: Theme.shade,
                              title: "Finding a new shady route…", message: nil, showsProgress: true)
        case .idle, .navigating, .arrived:
            EmptyView()
        }
    }

    private var offRouteMessage: LocalizedStringKey {
        if navigation.rerouteErrorMessage != nil {
            return "Couldn’t find a new route. Head back to the highlighted path."
        }
        return "We’ll look for a new shady way from here."
    }

    private var mapButtons: some View {
        VStack(spacing: 10) {
            if !camera.followsUserLocation {
                FloatingIconButton(systemImage: "location.north.line.fill",
                                   accessibilityLabel: "Follow my position") {
                    camera = .userLocation(followsHeading: true, fallback: .automatic)
                }
            }
            MapCompass(scope: mapScope)
        }
        // Leaves room for the map at large text sizes (the buttons offer the Large Content Viewer).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.trailing, Theme.screenPadding)
        .padding(.top, 10)
    }

    private var noWalk: some View {
        VStack(spacing: 16) {
            EmptyStateView(systemImage: "figure.walk", title: "No walk in progress",
                           message: "Pick a route on the Walk tab and tap Start.")
            Button("Close") {
                dismiss()
            }
            .buttonStyle(.shadewalkSecondary)
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }

    // MARK: - Events

    /// The single consumer of navigation events for this screen (see `NavigationEventRelay`).
    private func listenForEvents() async {
        for await event in NavigationEventRelay.shared(for: navigation).sessionEvents() {
            react(to: event)
        }
    }

    private func react(to event: NavigationEvent) {
        switch event {
        case let .approachingManeuver(maneuver):
            haptic = haptic.next(.maneuver)
            announce(maneuver.instruction)
        case let .enteredSun(lengthAhead):
            haptic = haptic.next(.sun)
            let distance = Formatters.distance(lengthAhead, units: settings.units)
            announce(String(localized: "Sun for \(distance)", comment: "Follow mode: sunny stretch ahead, e.g. “Sun for 120 m”."))
        case .enteredShade:
            haptic = haptic.next(.shade)
            announce(String(localized: "In the shade", comment: "Follow mode: the walker is in the shade."))
        case .offRoute:
            haptic = haptic.next(.offRoute)
            announce(String(localized: "You’ve left the route", comment: "Follow mode: the walker is off the route."))
        case .rerouted:
            haptic = haptic.next(.rerouted)
            announce(String(localized: "New route found", comment: "Follow mode: a new route replaced the old one."))
        case .arrived:
            haptic = haptic.next(.arrived)
        }
    }

    private func announce(_ text: String) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    private func statusChanged(_ status: NavigationStatus) {
        guard status == .arrived, arrival == nil, let route = navigation.route else { return }
        arrival = FollowArrivalSummary(route: route, walked: walked)
    }

    /// Closes follow mode; the Walk screen stops navigation when the cover is dismissed.
    private func finish() {
        isConfirmingEnd = false
        dismiss()
    }
}

// MARK: - Map

/// Follow-mode map: walked part in grey, the rest coloured by shade and sun, destination flag and the user.
struct FollowMapView: View {
    @Binding var camera: MapCameraPosition
    let mapScope: Namespace.ID
    let geometry: FollowRouteGeometry
    let destination: GeoCoordinate?

    init(camera: Binding<MapCameraPosition>, mapScope: Namespace.ID, geometry: FollowRouteGeometry,
         destination: GeoCoordinate?) {
        _camera = camera
        self.mapScope = mapScope
        self.geometry = geometry
        self.destination = destination
    }

    var body: some View {
        Map(position: $camera, scope: mapScope) {
            passedLayer
            remainingLayer
            destinationLayer
            UserAnnotation()
        }
        .mapStyle(Theme.mapStyle)
        .mapControls {
            MapScaleView()
        }
    }

    @MapContentBuilder
    private var passedLayer: some MapContent {
        if geometry.passed.count >= 2 {
            MapPolyline(coordinates: geometry.passed.clCoordinates)
                .stroke(Theme.alternateRouteColor.opacity(0.7), style: WalkMapStyle.passed)
        }
    }

    @MapContentBuilder
    private var remainingLayer: some MapContent {
        if geometry.remaining.count >= 2 {
            MapPolyline(coordinates: geometry.remaining.clCoordinates)
                .stroke(Color.white, style: WalkMapStyle.casing)
        }
        ForEach(runs) { run in
            MapPolyline(coordinates: run.coordinates)
                .stroke(Theme.routeColor(isShaded: run.isShaded), style: Theme.routeStroke(isShaded: run.isShaded))
        }
    }

    @MapContentBuilder
    private var destinationLayer: some MapContent {
        if let destination {
            Marker(String(localized: "Destination", comment: "Map marker at the end of the walk."),
                   systemImage: "flag.fill", coordinate: destination.clCoordinate)
                .tint(Theme.shade)
        }
    }

    private var runs: [WalkMapRun] {
        geometry.runs.map { run in
            WalkMapRun(id: run.id, coordinates: run.coordinates.clCoordinates, isShaded: run.isShaded)
        }
    }
}

// MARK: - Bottom card

/// Remaining time, distance and arrival, the shade / sun split still ahead, and End. The metrics sit in a row, or in
/// a column at accessibility text sizes so no value is cut off.
struct FollowStatsCard: View {
    let route: WalkRoute
    let progress: RouteProgress?
    let remainingSegments: [RouteSegment]
    let units: UnitPreference
    let timeZone: TimeZone
    let onEnd: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(route: WalkRoute, progress: RouteProgress?, remainingSegments: [RouteSegment], units: UnitPreference,
         timeZone: TimeZone, onEnd: @escaping () -> Void) {
        self.route = route
        self.progress = progress
        self.remainingSegments = remainingSegments
        self.units = units
        self.timeZone = timeZone
        self.onEnd = onEnd
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            metrics
            shadeSplit
            Button(role: .destructive, action: onEnd) {
                Label("End walk", systemImage: "xmark")
            }
            .buttonStyle(SecondaryButtonStyle(tint: Theme.heat, labelColor: Theme.heatInk))
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: Theme.sheetCornerRadius, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: Theme.sheetCornerRadius,
                                   style: .continuous)
                .fill(Theme.canvas)
                .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: -2)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var metrics: some View {
        TimelineView(.everyMinute) { context in
            metricsRow(now: context.date)
        }
    }

    private var isStacked: Bool { dynamicTypeSize.isAccessibilitySize }

    private func metricsRow(now: Date) -> some View {
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            MetricView(value: Formatters.duration(remainingDuration), caption: "Remaining", tint: Theme.ink,
                       size: .large)
            if !isStacked {
                Spacer(minLength: 8)
            }
            MetricView(value: Formatters.distance(remainingDistance, units: units), caption: "To go")
            if !isStacked {
                Spacer(minLength: 8)
            }
            MetricView(value: Formatters.clockTime(now.addingTimeInterval(remainingDuration), timeZone: timeZone),
                       caption: "Arrival", alignment: isStacked ? .leading : .trailing)
        }
    }

    private var shadeSplit: some View {
        VStack(alignment: .leading, spacing: 8) {
            if remainingSegments.isEmpty {
                ShadeBar(shadeFraction: remainingShadeFraction)
            } else {
                ShadeBar(segments: remainingSegments)
            }
            HStack(spacing: 16) {
                splitLabel(systemImage: "leaf.fill", tint: Theme.shade,
                           text: Text("\(Formatters.duration(WalkGeometry.walkingTime(remainingShaded, on: route))) in shade"))
                splitLabel(systemImage: "sun.max.fill", tint: Theme.sun,
                           text: Text("\(Formatters.duration(WalkGeometry.walkingTime(remainingSunny, on: route))) in sun"))
                Spacer(minLength: 0)
            }
        }
    }

    private func splitLabel(systemImage: String, tint: Color, text: Text) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            text
                .foregroundStyle(Theme.ink)
        }
        .font(.subheadline.weight(.medium))
        .accessibilityElement(children: .combine)
    }

    private var remainingDuration: TimeInterval { progress?.remainingDuration ?? route.duration }
    private var remainingDistance: Double { progress?.remainingDistance ?? route.distance }
    private var remainingShaded: Double { progress?.remainingShadedDistance ?? route.shadedDistance }
    private var remainingSunny: Double { progress?.remainingSunnyDistance ?? route.sunnyDistance }

    private var remainingShadeFraction: Double {
        let total = remainingShaded + remainingSunny
        return total > 0 ? remainingShaded / total : 1
    }
}

// MARK: - Alerts

/// Off-route / rerouting notice under the maneuver banner.
private struct FollowAlertBanner: View {
    let systemImage: String
    let tint: Color
    let title: LocalizedStringKey
    let message: LocalizedStringKey?
    var showsProgress: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsProgress {
                ProgressView()
                    .tint(tint)
            } else {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: Theme.controlShape)
        .overlay {
            Theme.controlShape.strokeBorder(tint.opacity(0.45), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Arrival

/// "You’ve arrived" with the minutes walked in the shade. Scrolls at large text sizes; Done stays pinned below.
private struct FollowArrivalSheet: View {
    let summary: FollowArrivalSummary
    let onDone: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var badgeSize: CGFloat = 84

    init(summary: FollowArrivalSummary, onDone: @escaping () -> Void) {
        self.summary = summary
        self.onDone = onDone
    }

    private var badgeDiameter: CGFloat { min(badgeSize, 120) }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "flag.checkered")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.shade)
                    .frame(width: badgeDiameter, height: badgeDiameter)
                    .background(Theme.shadeSoft, in: Circle())
                    .accessibilityHidden(true)
                VStack(spacing: 8) {
                    Text("You’ve arrived")
                        .font(.title.weight(.bold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    shadeSentence
                        .font(.body)
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ShadeBar(shadeFraction: summary.shadeFraction, height: 12)
                    .frame(maxWidth: 280)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button("Done", action: onDone)
                .buttonStyle(.shadewalkPrimary)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .background(Theme.canvas)
        }
        .background(Theme.canvas)
    }

    private var shadeSentence: Text {
        if summary.shadeMinutes >= 1 {
            return Text("You walked \(summary.shadeMinutes) min in the shade.")
        }
        return Text("Not much shade on this walk — remember to drink some water.")
    }
}

// MARK: - Haptics

/// Changes on every navigation event; `.sensoryFeedback` plays `feedback` for the new value.
struct FollowHaptic: Equatable {
    enum Kind: Equatable {
        case none, maneuver, sun, shade, offRoute, rerouted, arrived
    }

    var count = 0
    var kind: Kind = .none

    func next(_ kind: Kind) -> FollowHaptic {
        FollowHaptic(count: count + 1, kind: kind)
    }

    var feedback: SensoryFeedback? {
        switch kind {
        case .none: return nil
        case .maneuver: return .impact(weight: .heavy, intensity: 1)
        case .sun: return .impact(flexibility: .soft, intensity: 0.9)
        case .shade: return .impact(flexibility: .soft, intensity: 0.5)
        case .offRoute: return .warning
        case .rerouted: return .impact(weight: .medium, intensity: 0.8)
        case .arrived: return .success
        }
    }
}

#if DEBUG
extension AppEnvironment {
    /// Preview environment with a walk along the sample shadiest route in progress.
    static func followModePreview() -> AppEnvironment {
        let environment = AppEnvironment.preview()
        if let route = PreviewData.sampleRoute {
            environment.navigation.start(route: route)
        }
        return environment
    }
}

#Preview("Follow mode") {
    FollowModeView()
        .previewEnvironment(AppEnvironment.followModePreview())
}

#Preview("Follow mode – arrived") {
    Group {
        if let route = PreviewData.sampleRoute {
            FollowArrivalSheet(summary: FollowArrivalSummary(route: route, walked: FollowWalkedDistance())) {}
        }
    }
    .previewEnvironment()
}
#endif
