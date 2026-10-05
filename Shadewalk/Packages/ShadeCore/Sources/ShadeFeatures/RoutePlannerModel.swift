import Foundation
import Observation
import ShadeCore

/// Origin / destination / departure → shade-aware route alternatives.
///
/// Replans automatically (debounced) whenever the origin, destination, departure or preferences change while both
/// ends are set. A newer request cancels the in-flight one; results of stale requests are dropped.
@MainActor @Observable
public final class RoutePlannerModel {
    /// Start of the walk. Changing it clears the plan and replans (debounced) when both ends are set.
    public var origin: Place? {
        didSet { if origin != oldValue { inputsChanged(endpoints: true) } }
    }

    /// End of the walk. Changing it clears the plan and replans (debounced) when both ends are set.
    public var destination: Place? {
        didSet { if destination != oldValue { inputsChanged(endpoints: true) } }
    }

    /// Departure time; changing it replans, keeping the current plan visible meanwhile.
    public var departure: DepartureOption = .now {
        didSet { if departure != oldValue { inputsChanged(endpoints: false) } }
    }

    /// Routing preferences (usually `SettingsStore.routingPreferences`); changing them replans.
    public var preferences: RoutingPreferences {
        didSet { if preferences != oldValue { inputsChanged(endpoints: false) } }
    }

    /// State of the latest planning request.
    public private(set) var state: LoadState<RoutePlan> = .idle
    /// Last successful plan for the current origin/destination. Kept while a new departure time or new preferences
    /// are being planned; cleared when an endpoint changes or planning fails.
    public private(set) var plan: RoutePlan?
    /// Selected route; falls back to the first route when nil or unknown.
    public var selectedRouteID: String?

    @ObservationIgnored private let planner: RoutePlanning
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let debounceInterval: TimeInterval
    @ObservationIgnored var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var suppressReplan = false

    /// - Parameters:
    ///   - planner: route planning service.
    ///   - debounceInterval: delay before an automatic replan, seconds (0 in tests).
    ///   - now: clock used to resolve `.now` departures.
    public init(planner: RoutePlanning, preferences: RoutingPreferences = .default, debounceInterval: TimeInterval = 0.4,
                now: @escaping () -> Date = { Date() }) {
        self.planner = planner
        self.preferences = preferences
        self.debounceInterval = max(0, debounceInterval)
        self.now = now
    }

    /// Routes of the current plan, shadiest first.
    public var routes: [WalkRoute] { plan?.routes ?? [] }

    /// The selected route, or the first one.
    public var selectedRoute: WalkRoute? {
        let routes = self.routes
        if let id = selectedRouteID, let route = routes.first(where: { $0.id == id }) { return route }
        return routes.first
    }

    /// Sun position at departure for the current plan.
    public var sun: SunPosition? { plan?.sun }

    /// Weather at departure for the current plan.
    public var weather: WeatherSnapshot? { plan?.weather }

    /// Cool spots in the planned area.
    public var coolSpots: [CoolSpot] { plan?.coolSpots ?? [] }

    /// Both ends are set.
    public var canPlan: Bool { origin != nil && destination != nil }

    /// Departure date with `.now` resolved against the clock.
    public var departureDate: Date { departure.date(now: now()) }

    /// Selects a route by id.
    public func select(_ route: WalkRoute) {
        selectedRouteID = route.id
    }

    /// Swaps origin and destination (one replan).
    public func swap() {
        suppressReplan = true
        (origin, destination) = (destination, origin)
        suppressReplan = false
        inputsChanged(endpoints: true)
    }

    /// Plans again immediately (e.g. after a failure).
    public func retry() {
        guard canPlan else { return }
        schedule(after: 0)
    }

    /// Clears both ends, the plan and any in-flight request.
    public func clear() {
        suppressReplan = true
        origin = nil
        destination = nil
        suppressReplan = false
        cancelPending()
        plan = nil
        selectedRouteID = nil
        state = .idle
    }

    /// Plans immediately and returns when done (or superseded).
    public func planNow() async {
        guard canPlan else {
            cancelPending()
            state = .idle
            return
        }
        schedule(after: 0)
        await pendingTask?.value
    }

    // MARK: - Private

    private func inputsChanged(endpoints: Bool) {
        guard !suppressReplan else { return }
        if endpoints {
            plan = nil
        }
        guard canPlan else {
            cancelPending()
            plan = nil
            state = .idle
            return
        }
        schedule(after: debounceInterval)
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
    }

    private func schedule(after delay: TimeInterval) {
        cancelPending()
        let token = generation
        state = .loading
        pendingTask = Task { [weak self] in
            do {
                try await Debounce.wait(delay)
            } catch {
                return
            }
            await self?.perform(token)
        }
    }

    private func perform(_ token: Int) async {
        guard token == generation, let origin, let destination else { return }
        let request = RouteRequest(origin: origin.coordinate, destination: destination.coordinate,
                                   departure: departure.date(now: now()), preferences: preferences)
        do {
            let result = try await planner.plan(request)
            guard token == generation, !Task.isCancelled else { return }
            apply(result)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            plan = nil
            state = .failure(error)
        }
        if token == generation { pendingTask = nil }
    }

    /// Installs a plan, keeping the selection by id, else by profile, else selecting the first route.
    private func apply(_ result: RoutePlan) {
        let previousID = selectedRouteID
        let previousProfile = selectedRoute?.profile
        plan = result
        state = .loaded(result)
        let routes = result.routes
        if let id = previousID, routes.contains(where: { $0.id == id }) {
            selectedRouteID = id
        } else if let profile = previousProfile, let match = routes.first(where: { $0.profiles.contains(profile) }) {
            selectedRouteID = match.id
        } else {
            selectedRouteID = routes.first?.id
        }
    }
}
