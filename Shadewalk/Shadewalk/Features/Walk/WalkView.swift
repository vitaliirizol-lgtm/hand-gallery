import MapKit
import ShadeFeatures
import SwiftData
import SwiftUI
import UIKit

/// The Walk tab: full-bleed map with the shade overlay and cool spots, "Where to?" search and weather, the departure
/// time slider, shade-aware route alternatives, route details, and the way into follow mode.
///
/// Location fixes and camera moves arrive often (about once a second while walking), so they stay out of this body:
/// `WalkLocationWatcher` reacts to fixes and loads the weather, the settled map area lives in a non-observed
/// `WalkMapArea`, and the overlay is converted to map polygons once per overlay.
struct WalkView: View {
    @Environment(RoutePlannerModel.self) private var planner
    @Environment(LocationModel.self) private var location
    @Environment(NavigationModel.self) private var navigation
    @Environment(CoolSpotsModel.self) private var coolSpots
    @Environment(ShadeOverlayModel.self) private var shadeOverlay
    @Environment(DepartureTimeModel.self) private var departureTime
    @Environment(SettingsStore.self) private var settings
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Query private var savedPlaces: [SavedPlace]

    @Namespace private var mapScope
    @AppStorage("shadewalk.walk.showsCoolSpots") private var showsCoolSpots = false

    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @State private var activeSheet: WalkSheet?
    @State private var isFollowing = false
    /// Route to start once the detail sheet has finished dismissing.
    @State private var pendingStartRoute: WalkRoute?
    /// A destination was chosen without a current fix; the next fix becomes the start.
    @State private var isAwaitingOriginFix = false
    /// Last settled map area. Not observed: camera moves don't redraw the screen.
    @State private var mapArea = WalkMapArea()
    /// Centre of a local map area, rounded to about a kilometre: where the weather is for without a fix.
    @State private var mapWeatherCenter: GeoCoordinate?
    /// The map shows a larger area than cool spots are looked up for.
    @State private var isTooZoomedOutForCoolSpots = false
    /// The shade overlay as map polygons (rebuilt once per overlay).
    @State private var overlayPolygons: [WalkMapPolygon] = []
    @State private var coolSpotsLoadCenter: GeoCoordinate?
    @State private var selectedCoolSpotID: Int64?
    /// Endpoints the camera was last fitted to (fit once per origin / destination pair, not on every replan).
    @State private var fittedEndpoints: String?
    @State private var saveFeedback = 0
    /// Height of the screen between the status bar and the tab bar.
    @State private var containerHeight: CGFloat = 0

    /// Cool spots are looked up for visible areas up to this size, metres.
    private static let coolSpotsMaxSide: Double = 6_000
    /// The map centre stands in for the user's position (weather, search) only for areas up to this size, metres.
    private static let localAreaMaxSide: Double = 20_000
    /// While leaving "now", the shade overlay follows the sun this often, seconds.
    private static let overlayClockInterval: UInt64 = 300

    var body: some View {
        observingChanges(presentingSheets(mapWithChrome))
    }

    // MARK: - Layout

    private var mapWithChrome: some View {
        WalkMapView(camera: $camera, mapScope: mapScope, overlayPolygons: overlayPolygons,
                    showsCoolSpots: showsCoolSpots, selectedCoolSpotID: $selectedCoolSpotID,
                    onCameraSettled: { region in cameraSettled(region) },
                    onPlanToCoolSpot: { spot in planWalk(to: spot) })
            .overlay(alignment: .top) {
                mapHints
                    .frame(maxWidth: 240)
                    .padding(.top, 10)
            }
            .overlay(alignment: .topTrailing) {
                floatingControls
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomPanel
            }
            .mapScope(mapScope)
            .background {
                WalkLocationWatcher(weatherFallback: mapWeatherCenter,
                                    onFix: { useFixForWaitingOrigin() },
                                    onAuthorizationChange: { authorization in authorizationChanged(authorization) })
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { containerHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in
                            containerHeight = height
                        }
                }
            }
    }

    // MARK: Top bar

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let destination = planner.destination {
                RouteHeaderCard(origin: planner.origin, destination: destination,
                                isLocating: isLocatingOrigin,
                                onEditOrigin: { activeSheet = .origin },
                                onEditDestination: { activeSheet = .changeDestination },
                                onSwap: { planner.swap() },
                                onClose: { closePlan() })
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                WalkSearchCapsule {
                    activeSheet = .destination
                }
                .transition(.opacity)
                WeatherPill()
            }
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .motionAwareAnimation(value: planner.destination != nil)
    }

    // MARK: Floating controls

    private var floatingControls: some View {
        VStack(spacing: 10) {
            layersMenu
            FloatingIconButton(systemImage: followsUser ? "location.fill" : "location",
                               accessibilityLabel: "Show my location", isActive: followsUser) {
                recenterOnUser()
            }
            if showsCoolSpots {
                FloatingIconButton(systemImage: "list.bullet", accessibilityLabel: "Cool spots nearby") {
                    activeSheet = .coolSpots
                }
            }
            MapCompass(scope: mapScope)
        }
        // The column must leave room for the map at large text sizes (the buttons offer the Large Content Viewer).
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.trailing, Theme.screenPadding)
        .padding(.top, 10)
    }

    private var layersMenu: some View {
        @Bindable var overlay = shadeOverlay
        return Menu {
            Toggle(isOn: $overlay.isEnabled) {
                Label("Shade overlay", systemImage: "building.2.fill")
            }
            Toggle(isOn: $showsCoolSpots) {
                Label("Cool spots", systemImage: "thermometer.snowflake")
            }
            if showsCoolSpots {
                Button {
                    activeSheet = .coolSpots
                } label: {
                    Label("Cool spots nearby", systemImage: "list.bullet")
                }
            }
        } label: {
            WalkFloatingIconLabel(systemImage: "square.3.layers.3d", isActive: shadeOverlay.isEnabled || showsCoolSpots)
        }
        .accessibilityLabel(Text("Map layers"))
        .accessibilityValue(layersAccessibilityValue)
        .accessibilityShowsLargeContentViewer {
            Label("Map layers", systemImage: "square.3.layers.3d")
        }
    }

    /// Which layers are on (the filled button says it visually).
    private var layersAccessibilityValue: Text {
        switch (shadeOverlay.isEnabled, showsCoolSpots) {
        case (true, true): return Text("Shade overlay and cool spots on")
        case (true, false): return Text("Shade overlay on")
        case (false, true): return Text("Cool spots on")
        case (false, false): return Text("All layers off")
        }
    }

    // MARK: Map hints

    private var mapHints: some View {
        VStack(spacing: 6) {
            shadeOverlayHint
            coolSpotsHint
        }
    }

    @ViewBuilder
    private var shadeOverlayHint: some View {
        if shadeOverlay.isEnabled {
            switch shadeOverlay.state {
            case .tooZoomedOut:
                if showsCoolSpotsZoomHint {
                    WalkMapHint("Zoom in to see the shade and cool spots") {
                        Image(systemName: "plus.magnifyingglass")
                    }
                } else {
                    WalkMapHint("Zoom in to see the shade") {
                        Image(systemName: "plus.magnifyingglass")
                    }
                }
            case .loading:
                if shadeOverlay.overlay == nil {
                    WalkMapHint("Casting shadows…") {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            case .failed:
                Button {
                    shadeOverlay.retry()
                } label: {
                    WalkMapHint("Shade unavailable. Tap to try again.") {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
            case .ready:
                if let overlay = shadeOverlay.overlay, !overlay.sun.isUp {
                    WalkMapHint("The sun is down — no shadows to show") {
                        Image(systemName: "moon.stars.fill")
                    }
                }
            case .idle:
                EmptyView()
            }
        }
    }

    /// Shown on its own unless the shade hint already asks to zoom in for both.
    @ViewBuilder
    private var coolSpotsHint: some View {
        if showsCoolSpotsZoomHint, !(shadeOverlay.isEnabled && shadeOverlay.state == .tooZoomedOut) {
            WalkMapHint("Zoom in to see cool spots") {
                Image(systemName: "plus.magnifyingglass")
            }
        }
    }

    private var showsCoolSpotsZoomHint: Bool {
        showsCoolSpots && isTooZoomedOutForCoolSpots
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(spacing: 12) {
            DepartureTimeSlider()
                .padding(.horizontal, Theme.screenPadding)
            if hasPlanContent {
                // Scrolls once it would take more than about a third of the screen, so the map stays usable on
                // small phones and at large text sizes; Start stays pinned below it.
                WalkHeightLimit(maxHeight: planMaxHeight) {
                    ScrollView(.vertical) {
                        VStack(spacing: 12) {
                            planSection
                        }
                        // Room for the cards' shadows inside the scroll view's clip; the negative padding below
                        // keeps the panel's spacing unchanged.
                        .padding(.vertical, 8)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .padding(.vertical, -8)
            }
            if let route = planner.selectedRoute {
                actionRow(route)
                    .padding(.horizontal, Theme.screenPadding)
            }
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background {
            WalkPanelBackground()
        }
        .motionAwareAnimation(value: panelPhase)
    }

    /// `planSection` has something to show.
    private var hasPlanContent: Bool {
        locationCardReason != nil || !planner.routes.isEmpty || planner.state.isLoading || planner.state.isFailed
    }

    /// Tallest the scrolling part of the bottom panel gets (about one route card on the smallest phones).
    private var planMaxHeight: CGFloat {
        guard containerHeight > 0 else { return .infinity }
        return max(170, containerHeight * 0.34)
    }

    @ViewBuilder
    private var planSection: some View {
        if let reason = locationCardReason {
            WalkLocationCard(reason: reason, onAllow: { requestLocation() }, onOpenSettings: { openSettings() })
                .padding(.horizontal, Theme.screenPadding)
        }
        if !planner.routes.isEmpty {
            if let plan = planner.plan, !plan.isSunUp {
                WalkInfoBanner(systemImage: "moon.stars.fill",
                               message: "The sun is down — every route is in the shade.")
                    .padding(.horizontal, Theme.screenPadding)
            }
            RouteCardsCarousel(routes: planner.routes, selectedRouteID: planner.selectedRoute?.id,
                               isUpdating: planner.state.isLoading) { route in
                planner.select(route)
            }
        } else if planner.state.isLoading {
            RouteSkeletonCard()
                .padding(.horizontal, Theme.screenPadding)
        } else if planner.state.isFailed {
            ErrorCard(message: planErrorMessage, systemImage: planErrorSymbol, retry: planRetryAction)
                .padding(.horizontal, Theme.screenPadding)
        }
    }

    private func actionRow(_ route: WalkRoute) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                detailsButton(route)
                    .fixedSize(horizontal: true, vertical: false)
                saveButton
                    .fixedSize(horizontal: true, vertical: false)
                startButton(route)
            }
            VStack(spacing: 10) {
                startButton(route)
                HStack(spacing: 10) {
                    detailsButton(route)
                    saveButton
                }
            }
        }
    }

    private func detailsButton(_ route: WalkRoute) -> some View {
        Button {
            activeSheet = .routeDetail(route)
        } label: {
            Label("Details", systemImage: "list.bullet")
        }
        .buttonStyle(.shadewalkSecondary)
    }

    private var saveButton: some View {
        Button {
            toggleSavedDestination()
        } label: {
            Image(systemName: isDestinationSaved ? "bookmark.fill" : "bookmark")
        }
        .buttonStyle(.shadewalkSecondary)
        .disabled(!canToggleSave)
        .accessibilityLabel(isDestinationSaved ? Text("Remove destination from saved places")
                                               : Text("Save destination"))
        .accessibilityAddTraits(isDestinationSaved ? [.isButton, .isSelected] : [.isButton])
    }

    private func startButton(_ route: WalkRoute) -> some View {
        Button {
            startWalk(route)
        } label: {
            Label("Start", systemImage: "figure.walk")
        }
        .buttonStyle(.shadewalkPrimary)
        .accessibilityHint(Text("Starts step-by-step guidance along the selected route"))
    }

    // MARK: - Sheets & observation

    private func presentingSheets<Content: View>(_ content: Content) -> some View {
        content
            .sheet(item: $activeSheet, onDismiss: { sheetDismissed() }) { sheet in
                sheetContent(sheet)
            }
            .fullScreenCover(isPresented: $isFollowing, onDismiss: { followModeDismissed() }) {
                FollowModeView()
            }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: WalkSheet) -> some View {
        switch sheet {
        case .destination:
            PlaceSearchView(title: "Where to?", allowsCurrentLocation: false, searchCenter: searchCenter) { place in
                setDestination(place, resetOrigin: true)
            }
        case .changeDestination:
            PlaceSearchView(title: "Change destination", allowsCurrentLocation: false,
                            searchCenter: searchCenter) { place in
                setDestination(place, resetOrigin: false)
            }
        case .origin:
            PlaceSearchView(title: "Start from", prompt: "Search for a starting point",
                            searchCenter: searchCenter) { place in
                setOrigin(place)
            }
        case .coolSpots:
            CoolSpotsSheet(center: mapArea.center(ifAtMost: WalkView.coolSpotsMaxSide)) { spot in
                planWalk(to: spot)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        case let .routeDetail(route):
            RouteDetailView(route: route, onStart: { startFromDetail(route) })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private func observingChanges<Content: View>(_ content: Content) -> some View {
        content
            .sensoryFeedback(.success, trigger: saveFeedback)
            .onChange(of: router.pendingDestination, initial: true) { _, _ in
                consumePendingDestination()
            }
            .onChange(of: endpointsKey) { _, _ in
                endpointsChanged()
            }
            .onChange(of: routeIDs) { _, _ in
                routesChanged()
            }
            .onChange(of: departureTime.departure) { _, _ in
                refreshShadeOverlay()
            }
            .onChange(of: showsCoolSpots) { _, isOn in
                coolSpotsLayerChanged(isOn)
            }
            .onChange(of: overlayIdentity, initial: true) { _, _ in
                rebuildOverlayPolygons()
            }
            .task(id: departureTime.departure.isNow) {
                await followTheSunWhileLeavingNow()
            }
    }

    // MARK: - Derived state

    private var followsUser: Bool { camera.followsUserLocation }

    private var routeIDs: [String] { planner.routes.map(\.id) }

    /// Identifies the current origin / destination pair.
    private var endpointsKey: String {
        let origin = planner.origin.map { "\($0.coordinate)" } ?? "-"
        let destination = planner.destination.map { "\($0.coordinate)" } ?? "-"
        return "\(origin)|\(destination)"
    }

    /// What the bottom panel shows; animating on its changes keeps transitions smooth.
    private var panelPhase: [Int] {
        [planner.routes.count, planner.state.isLoading ? 1 : 0, planner.state.isFailed ? 1 : 0,
         locationCardReason == nil ? 0 : 1]
    }

    /// Changes only with a new overlay (or when the overlay is switched on or off).
    private var overlayIdentity: WalkOverlayIdentity {
        let overlay = shadeOverlay.overlay
        return WalkOverlayIdentity(isEnabled: shadeOverlay.isEnabled, date: overlay?.date,
                                   count: overlay?.polygons.count ?? 0,
                                   firstVertex: overlay?.polygons.first?.first,
                                   lastVertex: overlay?.polygons.last?.last)
    }

    /// Biases place search towards the visible area (when it is local).
    private var searchCenter: GeoCoordinate? {
        mapArea.center(ifAtMost: WalkView.localAreaMaxSide)
    }

    /// Waiting for a first fix to start from (only while that can still happen).
    private var isLocatingOrigin: Bool {
        guard isAwaitingOriginFix, planner.origin == nil else { return false }
        switch location.authorization {
        case .authorized, .notDetermined: return true
        case .denied, .restricted: return false
        }
    }

    private var locationCardReason: WalkLocationCard.Reason? {
        guard planner.origin == nil else { return nil }
        switch location.authorization {
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return planner.destination == nil ? nil : .notDetermined
        case .authorized:
            return nil
        }
    }

    private var planErrorMessage: String {
        if let error = planner.state.shadeError {
            return error.localizedMessage(units: settings.units)
        }
        return planner.state.localizedErrorMessage
            ?? ErrorText.message(for: ShadeError.noRouteFound, units: settings.units)
    }

    private var planErrorSymbol: String {
        planner.state.shadeError?.systemImage ?? "exclamationmark.triangle.fill"
    }

    private var planRetryAction: (() -> Void)? {
        guard planner.state.isRetryableFailure else { return nil }
        return { planner.retry() }
    }

    // MARK: Saved destination

    private var destinationRecord: SavedPlace? {
        guard let place = planner.destination else { return nil }
        let favoriteID = SavedPlace.identifier(for: place, kind: .favorite)
        return savedPlaces.first { $0.id == place.id || $0.id == favoriteID }
    }

    private var isDestinationSaved: Bool { destinationRecord != nil }

    /// Favorites can be saved and removed here; Home and Work are managed in the Saved tab.
    private var canToggleSave: Bool {
        guard let place = planner.destination, place.kind != .currentLocation else { return false }
        guard let record = destinationRecord else { return true }
        return record.kind == .favorite
    }

    private func toggleSavedDestination() {
        guard canToggleSave, let place = planner.destination else { return }
        if let record = destinationRecord {
            modelContext.delete(record)
        } else {
            modelContext.insert(SavedPlace(place: place, kind: .favorite))
        }
        try? modelContext.save()
        saveFeedback += 1
    }

    // MARK: - Planning

    private func setDestination(_ place: Place, resetOrigin: Bool) {
        selectedCoolSpotID = nil
        planner.destination = place
        if resetOrigin || planner.origin == nil {
            useCurrentLocationAsOrigin()
        }
    }

    private func setOrigin(_ place: Place) {
        isAwaitingOriginFix = false
        planner.origin = place
    }

    private func planWalk(to spot: CoolSpot) {
        setDestination(spot.walkPlace, resetOrigin: false)
    }

    /// Starts from "My Location". Without a current fix (none yet, or only an old one), asks for permission when
    /// needed and waits for the next fix.
    private func useCurrentLocationAsOrigin() {
        if let here = location.currentCoordinate() {
            isAwaitingOriginFix = false
            planner.origin = Place.localizedCurrentLocation(here)
            return
        }
        planner.origin = nil
        isAwaitingOriginFix = true
        switch location.authorization {
        case .denied, .restricted:
            // Only Settings can change this; the location card explains it and the start can be picked by hand.
            // If permission comes back, `authorizationChanged` starts from the user's position.
            return
        case .notDetermined:
            location.requestAuthorization()
        case .authorized:
            break
        }
        location.startUpdates()
    }

    /// A new fix arrived (from `WalkLocationWatcher`): use it if a start is waiting for one.
    private func useFixForWaitingOrigin() {
        guard isAwaitingOriginFix, planner.origin == nil, planner.destination != nil,
              let here = location.currentCoordinate() else { return }
        isAwaitingOriginFix = false
        planner.origin = Place.localizedCurrentLocation(here)
    }

    /// Permission was granted (e.g. back from Settings) while a destination waits for a start: start from here.
    private func authorizationChanged(_ authorization: LocationAuthorization) {
        guard authorization == .authorized, planner.destination != nil, planner.origin == nil else { return }
        useCurrentLocationAsOrigin()
    }

    private func consumePendingDestination() {
        guard router.pendingDestination != nil, let place = router.takePendingDestination() else { return }
        setDestination(place, resetOrigin: true)
    }

    private func closePlan() {
        planner.clear()
        isAwaitingOriginFix = false
        fittedEndpoints = nil
        selectedCoolSpotID = nil
        withMotionAwareAnimation(reduceMotion: reduceMotion) {
            camera = .userLocation(fallback: .automatic)
        }
    }

    private func endpointsChanged() {
        if let origin = planner.origin {
            departureTime.coordinate = origin.coordinate
        }
        guard planner.destination != nil else {
            fittedEndpoints = nil
            return
        }
        if planner.plan == nil {
            fitCamera(to: [planner.origin?.coordinate, planner.destination?.coordinate].compactMap { $0 })
        }
    }

    private func routesChanged() {
        guard !planner.routes.isEmpty, endpointsKey != fittedEndpoints else { return }
        fittedEndpoints = endpointsKey
        fitCamera(to: planner.routes.flatMap(\.coordinates))
    }

    private func fitCamera(to coordinates: [GeoCoordinate]) {
        guard let position = MapCameraPosition.fitting(coordinates, paddingFactor: 1.3, minimumSpanMeters: 400) else {
            return
        }
        withMotionAwareAnimation(reduceMotion: reduceMotion) {
            camera = position
        }
    }

    // MARK: - Map

    private func cameraSettled(_ region: MKCoordinateRegion) {
        let box = BoundingBox(region: region)
        mapArea.box = box
        updateAreaState(for: box)
        // Follow mode covers this map while its camera keeps following the walker: no overlay or cool-spot loads.
        guard !isFollowing else { return }
        shadeOverlay.update(visible: box, date: departureTime.resolvedDate)
        refreshCoolSpots()
    }

    /// Updates the state that depends on the visible area, only when it actually changes.
    private func updateAreaState(for box: BoundingBox) {
        let side = max(box.widthMeters, box.heightMeters)
        let isTooZoomedOut = !(side <= WalkView.coolSpotsMaxSide)
        if isTooZoomedOutForCoolSpots != isTooZoomedOut {
            isTooZoomedOutForCoolSpots = isTooZoomedOut
        }
        let weatherCenter = side <= WalkView.localAreaMaxSide ? WalkView.weatherCell(box.center) : nil
        if mapWeatherCenter != weatherCenter {
            mapWeatherCenter = weatherCenter
        }
    }

    /// `coordinate` rounded to 0.01° (about a kilometre), so small pans don't move the weather location.
    private static func weatherCell(_ coordinate: GeoCoordinate) -> GeoCoordinate {
        GeoCoordinate(latitude: (coordinate.latitude * 100).rounded() / 100,
                      longitude: (coordinate.longitude * 100).rounded() / 100)
    }

    private func refreshShadeOverlay() {
        guard !isFollowing, let box = mapArea.box else { return }
        shadeOverlay.update(visible: box, date: departureTime.resolvedDate)
    }

    private func rebuildOverlayPolygons() {
        overlayPolygons = shadeOverlay.isEnabled ? WalkMapPolygon.polygons(from: shadeOverlay.polygons) : []
    }

    /// While leaving "now", moves the shade overlay along with the sun every few minutes.
    private func followTheSunWhileLeavingNow() async {
        guard departureTime.departure.isNow else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: WalkView.overlayClockInterval * 1_000_000_000)
            guard !Task.isCancelled else { return }
            refreshShadeOverlay()
        }
    }

    private func recenterOnUser() {
        if location.canRequestAuthorization {
            location.requestAuthorization()
        }
        withMotionAwareAnimation(reduceMotion: reduceMotion) {
            camera = .userLocation(fallback: .automatic)
        }
    }

    private func coolSpotsLayerChanged(_ isOn: Bool) {
        if isOn {
            coolSpotsLoadCenter = nil
            refreshCoolSpots()
        } else {
            selectedCoolSpotID = nil
        }
    }

    /// Loads cool spots around the visible area when the layer is on and the map moved far enough.
    private func refreshCoolSpots() {
        guard showsCoolSpots, !isFollowing else { return }
        let box = mapArea.box
        guard let center = box?.center ?? location.currentCoordinate() else { return }
        let side = mapArea.side ?? 1_500
        guard side <= WalkView.coolSpotsMaxSide else { return }
        if let last = coolSpotsLoadCenter, GeoMath.distance(last, center) < 400, !coolSpots.state.isFailed {
            return
        }
        coolSpotsLoadCenter = center
        let radius = min(2_000, max(800, side * 0.75))
        Task {
            await coolSpots.load(near: center, radius: radius)
            // Re-measure from the user only when this load is the one on screen: a superseded load returns early,
            // and re-measuring then would empty the list of the newer, still loading one.
            guard coolSpots.state.value != nil, coolSpots.reference == center,
                  let here = location.currentCoordinate() else { return }
            coolSpots.updateReference(here)
        }
    }

    // MARK: - Location

    private func requestLocation() {
        location.requestAuthorization()
        if planner.destination != nil, planner.origin == nil {
            isAwaitingOriginFix = true
        }
        location.startUpdates()
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        // Coming back with permission finishes the plan from the user's position.
        if planner.destination != nil, planner.origin == nil {
            isAwaitingOriginFix = true
        }
        openURL(url)
    }

    // MARK: - Follow mode

    private func startWalk(_ route: WalkRoute) {
        NavigationEventRelay.shared(for: navigation).beginSession()
        navigation.start(route: route)
        isFollowing = true
    }

    private func startFromDetail(_ route: WalkRoute) {
        pendingStartRoute = route
        activeSheet = nil
    }

    private func sheetDismissed() {
        guard let route = pendingStartRoute else { return }
        pendingStartRoute = nil
        // The plan may have been refreshed while the sheet was open: prefer its copy of the route.
        startWalk(planner.routes.first { $0.id == route.id } ?? route)
    }

    private func followModeDismissed() {
        navigation.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        // Catch up on what was skipped while follow mode covered the map.
        refreshShadeOverlay()
        refreshCoolSpots()
    }
}

/// Sheets presented by the Walk screen.
enum WalkSheet: Identifiable, Hashable {
    case destination
    case changeDestination
    case origin
    case coolSpots
    case routeDetail(WalkRoute)

    var id: String {
        switch self {
        case .destination: return "destination"
        case .changeDestination: return "change-destination"
        case .origin: return "origin"
        case .coolSpots: return "cool-spots"
        case let .routeDetail(route): return "route-\(route.id)"
        }
    }
}

// MARK: - Helpers

/// Canvas sheet behind the bottom panel, with rounded top corners, running under the tab bar.
private struct WalkPanelBackground: View {
    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: Theme.sheetCornerRadius, bottomLeadingRadius: 0,
                               bottomTrailingRadius: 0, topTrailingRadius: Theme.sheetCornerRadius,
                               style: .continuous)
            .fill(Theme.canvas)
            .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: -2)
            .ignoresSafeArea(edges: .bottom)
    }
}

/// The last settled visible map area. A plain reference kept in `@State`: updating it doesn't redraw the Walk screen.
private final class WalkMapArea {
    var box: BoundingBox?

    /// Longest side of `box`, metres.
    var side: Double? {
        box.map { max($0.widthMeters, $0.heightMeters) }
    }

    /// Centre of the visible area when it is at most `maxSide` metres across (a local area, not a country).
    func center(ifAtMost maxSide: Double) -> GeoCoordinate? {
        guard let box, let side, side <= maxSide else { return nil }
        return box.center
    }
}

/// Cheap identity of the shown shade overlay (on / off, time, size, first and last vertex): the map polygons are
/// rebuilt only for a new overlay, not on every loading state change.
private struct WalkOverlayIdentity: Equatable {
    var isEnabled: Bool
    var date: Date?
    var count: Int
    var firstVertex: GeoCoordinate?
    var lastVertex: GeoCoordinate?
}

/// Shows its single subview at its natural height, but no taller than `maxHeight` (the subview, a scroll view,
/// scrolls beyond that).
private struct WalkHeightLimit: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? natural.width, height: min(natural.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        content.place(at: bounds.origin, anchor: .topLeading,
                      proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// Invisible helper behind the Walk map that owns its location-driven work, so a new fix (about once a second while
/// walking) re-renders only this view: it reports fixes and permission changes to the screen and loads the weather
/// for the user's position, or for the visible area without a current fix.
private struct WalkLocationWatcher: View {
    let weatherFallback: GeoCoordinate?
    let onFix: () -> Void
    let onAuthorizationChange: (LocationAuthorization) -> Void

    @Environment(LocationModel.self) private var location
    @Environment(WeatherModel.self) private var weather

    init(weatherFallback: GeoCoordinate?, onFix: @escaping () -> Void,
         onAuthorizationChange: @escaping (LocationAuthorization) -> Void) {
        self.weatherFallback = weatherFallback
        self.onFix = onFix
        self.onAuthorizationChange = onAuthorizationChange
    }

    var body: some View {
        Color.clear
            .accessibilityHidden(true)
            .onChange(of: location.lastFix) { _, _ in
                onFix()
            }
            .onChange(of: location.authorization) { _, authorization in
                onAuthorizationChange(authorization)
            }
            .task(id: weatherKey) {
                await loadWeather()
            }
    }

    private var weatherCoordinate: GeoCoordinate? {
        location.currentCoordinate() ?? weatherFallback
    }

    /// Changes only when the weather location moves by about a kilometre.
    private var weatherKey: String {
        guard let coordinate = weatherCoordinate else { return "none" }
        return String(format: "%.2f,%.2f", coordinate.latitude, coordinate.longitude)
    }

    private func loadWeather() async {
        guard let coordinate = weatherCoordinate else { return }
        await weather.load(at: coordinate)
    }
}

#if DEBUG
#Preview("Walk – planned") {
    WalkView()
        .previewEnvironment()
}

#Preview("Walk – search") {
    WalkView()
        .previewEnvironment(AppEnvironment.preview(planned: false))
}
#endif
