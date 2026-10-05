import Foundation
import Observation
import ShadeFeatures

/// Composition root: builds the services and view models once and wires them together.
///
/// Inject everything into a view hierarchy with `.shadewalkEnvironment(_:)`; views then read each model with
/// `@Environment(ModelType.self)` (and `@Environment(AppEnvironment.self)` for the helpers below).
///
/// Synchronisation (documented choice: **observation loops**, no manual calls required):
/// * Settings → routing: whenever `SettingsStore.settings` changes, `applySettings()` copies
///   `settings.routingPreferences` into `RoutePlannerModel.preferences` (which replans) and
///   `NavigationModel.preferences` (used for reroutes). `applySettings()` is idempotent; calling it explicitly
///   (e.g. from SettingsView `.onChange`) is harmless but not needed.
/// * Departure slider → routing: `DepartureTimeModel.departure` is mirrored into `RoutePlannerModel.departure`.
/// * Location → sun times: the first location fix seeds `DepartureTimeModel.coordinate` (only while it is nil, so the
///   Walk screen may set it to the route origin without being overridden). The provider only reports a cached system
///   position when it is recent, so an old position from another place never seeds it.
/// * Navigation → location: while a walk is followed, location updates keep running in the background (lock screen);
///   when it ends in the background, updates stop.
/// * `settings.showShadeOverlayByDefault` seeds `ShadeOverlayModel.isEnabled` at launch only; the map toggle owns it
///   afterwards.
@MainActor @Observable
final class AppEnvironment {
    // MARK: - View models

    let settings: SettingsStore
    let location: LocationModel
    let planner: RoutePlannerModel
    let search: SearchModel
    let navigation: NavigationModel
    let coolSpots: CoolSpotsModel
    let seatSide: SeatSideModel
    let weather: WeatherModel
    let shadeOverlay: ShadeOverlayModel
    let departureTime: DepartureTimeModel
    let router: AppRouter

    // MARK: - Platform services

    /// Place search / reverse geocoding (e.g. to name a dropped pin).
    let placeSearch: PlaceSearching
    /// Raw location source (the models above already wrap it).
    let locationProvider: LocationProviding

    /// The scene is in the background.
    @ObservationIgnored private var isInBackground = false

    /// - Parameters:
    ///   - store: persistence for settings and recent places.
    ///   - routePlanning, overlayProvider, coolSpotProvider: usually the same `RoutePlanner` actor.
    ///   - now: clock shared by the models (fixed in previews).
    init(store: KeyValueStore,
         routePlanning: RoutePlanning,
         overlayProvider: ShadeOverlayProviding,
         coolSpotProvider: CoolSpotProviding,
         weatherProvider: WeatherProviding,
         drivingPaths: DrivingPathProviding,
         locationProvider: LocationProviding,
         placeSearch: PlaceSearching,
         now: @escaping () -> Date = { Date() },
         timeZone: TimeZone = .current) {
        let settings = SettingsStore(store: store)
        let preferences = settings.routingPreferences
        self.settings = settings
        self.locationProvider = locationProvider
        self.placeSearch = placeSearch
        location = LocationModel(provider: locationProvider)
        planner = RoutePlannerModel(planner: routePlanning, preferences: preferences, now: now)
        search = SearchModel(search: placeSearch, store: store)
        navigation = NavigationModel(location: locationProvider, planner: routePlanning, preferences: preferences,
                                     now: now)
        coolSpots = CoolSpotsModel(provider: coolSpotProvider)
        seatSide = SeatSideModel(drivingPaths: drivingPaths, weather: weatherProvider, now: now)
        weather = WeatherModel(provider: weatherProvider, now: now)
        shadeOverlay = ShadeOverlayModel(provider: overlayProvider, isEnabled: settings.showShadeOverlayByDefault)
        departureTime = DepartureTimeModel(coordinate: locationProvider.lastFix?.coordinate, timeZone: timeZone,
                                           now: now)
        router = AppRouter()

        syncDeparture()
        observeSettings()
        observeDeparture()
        observeNavigation()
        if departureTime.coordinate == nil { observeFirstLocation() }
    }

    /// Production wiring: Overpass + Open-Meteo behind one `RoutePlanner`, MapKit / CoreLocation adapters.
    static func live() -> AppEnvironment {
        let http = URLSessionHTTPClient()
        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let cacheDirectory = cachesRoot?.appendingPathComponent("Shadewalk", isDirectory: true)
        let overpass = OverpassClient(http: http, cacheDirectory: cacheDirectory)
        let openMeteo = OpenMeteoClient(http: http)
        let routePlanner = RoutePlanner(areaProvider: overpass, elevationProvider: openMeteo, weatherProvider: openMeteo)
        let locationProvider = CoreLocationProvider()
        let environment = AppEnvironment(store: UserDefaultsStore(),
                                         routePlanning: routePlanner,
                                         overlayProvider: routePlanner,
                                         coolSpotProvider: routePlanner,
                                         weatherProvider: openMeteo,
                                         drivingPaths: MapKitDrivingPaths(),
                                         locationProvider: locationProvider,
                                         placeSearch: MapKitPlaceSearch())
        locationProvider.onAuthorizationChange = { [weak environment] _ in
            environment?.locationAuthorizationChanged()
        }
        return environment
    }

    // MARK: - Lifecycle (called by RootView)

    /// The scene became active: re-read permission, roll the departure day over if needed, resume location updates
    /// (the provider only powers the GPS once permission is granted).
    func appDidBecomeActive() {
        isInBackground = false
        location.refresh()
        departureTime.refresh()
        location.startUpdates()
    }

    /// The scene went to the background: stop location updates unless a walk is being followed (follow mode keeps
    /// them running behind the lock screen; see `navigationStatusChanged()`).
    func appDidEnterBackground() {
        isInBackground = true
        guard !navigation.isActive else { return }
        location.stopUpdates()
    }

    /// Location permission changed (e.g. the user answered the system prompt).
    func locationAuthorizationChanged() {
        location.refresh()
        if location.isAuthorized { location.startUpdates() }
    }

    // MARK: - Settings

    /// Copies routing preferences from the settings into the planner and navigation models (idempotent).
    func applySettings() {
        let preferences = settings.routingPreferences
        if planner.preferences != preferences { planner.preferences = preferences }
        if navigation.preferences != preferences { navigation.preferences = preferences }
    }

    // MARK: - Observation loops

    private func observeSettings() {
        withObservationTracking {
            _ = settings.settings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applySettings()
                self.observeSettings()
            }
        }
    }

    private func observeDeparture() {
        withObservationTracking {
            _ = departureTime.departure
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncDeparture()
                self.observeDeparture()
            }
        }
    }

    private func syncDeparture() {
        let departure = departureTime.departure
        if planner.departure != departure { planner.departure = departure }
    }

    private func observeNavigation() {
        withObservationTracking {
            _ = navigation.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.navigationStatusChanged()
                self.observeNavigation()
            }
        }
    }

    /// A followed walk keeps location running in the background; once it ends (arrived or stopped) while the app is
    /// in the background, updates stop as they would have when it went there.
    private func navigationStatusChanged() {
        let isActive = navigation.isActive
        (locationProvider as? CoreLocationProvider)?.setBackgroundUpdatesEnabled(isActive)
        if !isActive, isInBackground {
            location.stopUpdates()
        }
    }

    /// Waits for the first location fix and uses it for the slider's sunrise/sunset range.
    private func observeFirstLocation() {
        withObservationTracking {
            _ = location.lastFix
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.departureTime.coordinate == nil else { return }
                if let coordinate = self.location.coordinate {
                    self.departureTime.coordinate = coordinate
                } else {
                    self.observeFirstLocation()
                }
            }
        }
    }
}
