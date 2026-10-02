import Foundation
import Observation
import ShadeCore

/// Something the app should announce during navigation (haptics, speech).
public enum NavigationEvent: Hashable, Sendable {
    /// The next maneuver is ≤ 40 m ahead (emitted once per maneuver).
    case approachingManeuver(Maneuver)
    /// Left the shade; `lengthAhead` metres of sun follow.
    case enteredSun(lengthAhead: Double)
    case enteredShade
    case offRoute
    /// A new route from the current position replaced the old one.
    case rerouted(WalkRoute)
    case arrived
}

/// Phase of a navigation session.
public enum NavigationStatus: Hashable, Sendable {
    case idle
    case navigating
    case offRoute
    /// Off route and a new route is being planned.
    case rerouting
    case arrived
}

/// Live navigation ("follow mode"): consumes location fixes, tracks progress along the route, emits
/// `NavigationEvent`s and reroutes when the user leaves the route.
@MainActor @Observable
public final class NavigationModel {
    /// Route being followed (replaced on reroute).
    public private(set) var route: WalkRoute?
    /// Progress along `route` after the latest fix.
    public private(set) var progress: RouteProgress?
    /// Phase of the current session.
    public private(set) var status: NavigationStatus = .idle
    /// Latest fix fed to the tracker.
    public private(set) var lastFix: LocationFix?
    /// Most recent event (also delivered through `events`).
    public private(set) var lastEvent: NavigationEvent?
    /// Successful reroutes in this session.
    public private(set) var rerouteCount = 0
    /// Message of the last failed reroute attempt; cleared on success.
    public private(set) var rerouteErrorMessage: String?
    /// Preferences used for reroutes.
    public var preferences: RoutingPreferences

    /// Navigation events, in order, for the lifetime of the model. Buffered; meant for a single consumer.
    public let events: AsyncStream<NavigationEvent>

    @ObservationIgnored private let eventContinuation: AsyncStream<NavigationEvent>.Continuation
    @ObservationIgnored private let location: LocationProviding
    @ObservationIgnored private let planner: RoutePlanning
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let rerouteInterval: TimeInterval
    @ObservationIgnored private let approachDistance: Double
    @ObservationIgnored private let trackerConfiguration: RouteProgressTracker.Configuration

    @ObservationIgnored private var tracker: RouteProgressTracker?
    @ObservationIgnored var fixTask: Task<Void, Never>?
    @ObservationIgnored var rerouteTask: Task<Void, Never>?
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var rerouteToken = 0
    @ObservationIgnored private var lastRerouteAttempt: Date?
    @ObservationIgnored private var announcedManeuvers = Set<Maneuver>()
    @ObservationIgnored private var lastShadeState: Bool?
    @ObservationIgnored private var wasOffRoute = false
    /// Every emitted event (bounded), for diagnostics and tests.
    @ObservationIgnored private(set) var eventLog: [NavigationEvent] = []

    /// - Parameters:
    ///   - location: source of location fixes.
    ///   - planner: used to reroute from the current position to the destination.
    ///   - now: clock for reroute throttling and reroute departure times.
    ///   - rerouteInterval: minimum time between reroute attempts, seconds (default 10).
    ///   - approachDistance: distance at which `.approachingManeuver` fires, metres (default 40).
    public init(location: LocationProviding, planner: RoutePlanning, preferences: RoutingPreferences = .default,
                now: @escaping () -> Date = { Date() }, rerouteInterval: TimeInterval = 10, approachDistance: Double = 40,
                trackerConfiguration: RouteProgressTracker.Configuration = .default) {
        self.location = location
        self.planner = planner
        self.preferences = preferences
        self.now = now
        self.rerouteInterval = max(0, rerouteInterval)
        self.approachDistance = approachDistance
        self.trackerConfiguration = trackerConfiguration
        let (stream, continuation) = AsyncStream.makeStream(of: NavigationEvent.self)
        events = stream
        eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    /// A session is running (navigating, off route or rerouting).
    public var isActive: Bool {
        switch status {
        case .navigating, .offRoute, .rerouting: return true
        case .idle, .arrived: return false
        }
    }

    /// Starts following `route`, replacing any running session, and subscribes to location fixes.
    public func start(route: WalkRoute) {
        stop()
        install(route)
        rerouteCount = 0
        rerouteErrorMessage = nil
        lastRerouteAttempt = nil
        lastFix = nil
        status = .navigating
        let stream = location.fixes()
        let current = session
        fixTask = Task { [weak self] in
            for await fix in stream {
                guard let self, self.session == current, !Task.isCancelled else { break }
                self.handle(fix)
            }
        }
    }

    /// Ends the session: cancels the location subscription and any reroute.
    public func stop() {
        session += 1
        fixTask?.cancel()
        fixTask = nil
        cancelReroute()
        tracker = nil
        route = nil
        progress = nil
        status = .idle
    }

    /// Feeds one location fix (normally called by the location subscription; also useful for simulation).
    public func handle(_ fix: LocationFix) {
        guard isActive, var tracker else { return }
        lastFix = fix
        let update = tracker.update(with: fix)
        self.tracker = tracker
        progress = update

        if update.hasArrived {
            status = .arrived
            session += 1
            fixTask?.cancel()
            fixTask = nil
            cancelReroute()
            emit(.arrived)
            return
        }

        if update.isOffRoute {
            if !wasOffRoute {
                wasOffRoute = true
                emit(.offRoute)
            }
            if status == .navigating { status = .offRoute }
            rerouteIfAllowed(from: fix)
            return
        }

        if wasOffRoute {
            // Back on the route: an in-flight reroute is no longer needed.
            wasOffRoute = false
            cancelReroute()
            status = .navigating
        }

        // Drifting away (not yet off route): the snapped position says little about where the user is.
        guard update.distanceFromRoute <= trackerConfiguration.offRouteDistance else { return }

        if let maneuver = update.nextManeuver, let distance = update.distanceToNextManeuver,
           distance <= approachDistance, !announcedManeuvers.contains(maneuver) {
            announcedManeuvers.insert(maneuver)
            emit(.approachingManeuver(maneuver))
        }

        if let wasInShade = lastShadeState, wasInShade != update.isInShade {
            emit(update.isInShade ? .enteredShade : .enteredSun(lengthAhead: update.nextSunLength ?? 0))
        }
        lastShadeState = update.isInShade
    }

    // MARK: - Private

    private func install(_ route: WalkRoute) {
        self.route = route
        tracker = RouteProgressTracker(route: route, configuration: trackerConfiguration)
        progress = nil
        announcedManeuvers = []
        lastShadeState = nil
        wasOffRoute = false
    }

    private func emit(_ event: NavigationEvent) {
        lastEvent = event
        eventLog.append(event)
        if eventLog.count > 500 { eventLog.removeFirst(eventLog.count - 500) }
        eventContinuation.yield(event)
    }

    private func cancelReroute() {
        rerouteTask?.cancel()
        rerouteTask = nil
        rerouteToken += 1
        if status == .rerouting { status = .offRoute }
    }

    private func rerouteIfAllowed(from fix: LocationFix) {
        // Only reroute from a position good enough to plan from.
        guard rerouteTask == nil, let route, let destination = route.destination, fix.coordinate.isValid,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= trackerConfiguration.maxDecisionAccuracy
        else { return }
        let time = now()
        if let last = lastRerouteAttempt, time.timeIntervalSince(last) < rerouteInterval { return }
        lastRerouteAttempt = time
        rerouteToken += 1
        let token = rerouteToken
        let profile = route.profile
        let request = RouteRequest(origin: fix.coordinate, destination: destination, departure: time,
                                   preferences: preferences)
        let planner = self.planner
        status = .rerouting
        rerouteTask = Task { [weak self] in
            let result: Result<RoutePlan, Error>
            do {
                result = .success(try await planner.plan(request))
            } catch {
                result = .failure(error)
            }
            self?.finishReroute(result, profile: profile, token: token)
        }
    }

    private func finishReroute(_ result: Result<RoutePlan, Error>, profile: RouteProfile, token: Int) {
        guard token == rerouteToken, status == .rerouting else { return }
        rerouteTask = nil
        switch result {
        case let .success(plan):
            guard let newRoute = plan.routes.first(where: { $0.profiles.contains(profile) }) ?? plan.routes.first else {
                rerouteErrorMessage = ErrorMessages.message(for: ShadeError.noRouteFound)
                status = .offRoute
                return
            }
            install(newRoute)
            rerouteCount += 1
            rerouteErrorMessage = nil
            status = .navigating
            emit(.rerouted(newRoute))
            if let fix = lastFix { handle(fix) }
        case let .failure(error):
            rerouteErrorMessage = ErrorMessages.message(for: error)
            status = .offRoute
        }
    }
}
