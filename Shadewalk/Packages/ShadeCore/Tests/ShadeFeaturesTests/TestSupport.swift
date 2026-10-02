import Foundation
import XCTest
@testable import ShadeFeatures

// MARK: - Concurrency helpers

/// Lock-protected value shared with fakes running off the main actor.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    @discardableResult
    func mutate<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// Suspends callers until `open()`; lets tests hold a fake's response to create stale in-flight requests.
actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Manually advanced clock.
final class TestClock: @unchecked Sendable {
    private let state: Locked<Date>

    init(_ start: Date = Fixtures.departure) { state = Locked(start) }

    var now: Date { state.current }

    func advance(_ seconds: TimeInterval) {
        state.mutate { $0 = $0.addingTimeInterval(seconds) }
    }

    func set(_ date: Date) {
        state.mutate { $0 = date }
    }
}

/// Records calls and answers them with a replaceable async handler.
final class Recorder<Request, Response>: @unchecked Sendable {
    typealias Handler = @Sendable (Request, Int) async throws -> Response

    private struct State {
        var requests: [Request] = []
        var completed = 0
        var handler: Handler
    }

    private let state: Locked<State>

    init(_ handler: @escaping Handler) { state = Locked(State(handler: handler)) }

    var requests: [Request] { state.current.requests }
    var callCount: Int { state.current.requests.count }
    /// Calls that have returned or thrown.
    var completedCount: Int { state.current.completed }

    func setHandler(_ handler: @escaping Handler) {
        state.mutate { $0.handler = handler }
    }

    func call(_ request: Request) async throws -> Response {
        let (index, handler) = state.mutate { s -> (Int, Handler) in
            s.requests.append(request)
            return (s.requests.count - 1, s.handler)
        }
        defer { state.mutate { $0.completed += 1 } }
        return try await handler(request, index)
    }
}

struct TestError: Error, LocalizedError, Equatable {
    var message = "Something broke"
    var errorDescription: String? { message }
}

/// Polls `condition` (yielding to other tasks) until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
               _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline {
            XCTFail("Timed out waiting for condition", file: file, line: line)
            return
        }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Lets queued tasks run for a short while (to assert that something did *not* happen).
@MainActor
func settle() async {
    for _ in 0..<10 {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

// MARK: - Fixtures

enum Fixtures {
    static let origin = GeoCoordinate(latitude: 37.5665, longitude: 126.9780)
    static let departure = Date(timeIntervalSince1970: 1_751_000_000)
    static let sun = SunPosition(azimuth: 135, elevation: 50)

    /// Coordinate `x` metres east and `y` metres north of `origin`.
    static func point(_ x: Double, _ y: Double = 0) -> GeoCoordinate {
        LocalProjection(origin: origin).unproject(Point2D(x: x, y: y))
    }

    static func fix(_ x: Double, _ y: Double = 0, accuracy: Double = 5) -> LocationFix {
        LocationFix(coordinate: point(x, y), horizontalAccuracy: accuracy, timestamp: departure)
    }

    static func place(_ id: String, _ x: Double = 0, _ y: Double = 0, kind: PlaceKind = .searchResult) -> Place {
        Place(id: id, name: id.capitalized, subtitle: nil, coordinate: point(x, y), kind: kind)
    }

    /// Straight route due east from `(startX, startY)`, `length` metres, a vertex every 50 m.
    static func route(id: String = "route", profile: RouteProfile = .shadiest, profiles: [RouteProfile]? = nil,
                      length: Double = 600, startX: Double = 0, startY: Double = 0,
                      segments: [(Double, Bool)] = [], maneuvers: [(ManeuverKind, Double)] = []) -> WalkRoute {
        let coordinates = stride(from: 0, through: length, by: 50).map { point(startX + $0, startY) }
        let shaded = segments.filter(\.1).reduce(0) { $0 + $1.0 }
        let total = max(length, 1)
        return WalkRoute(
            id: id, profile: profile, profiles: profiles ?? [profile], coordinates: coordinates,
            segments: segments.map { RouteSegment(coordinates: [], length: $0.0, isShaded: $0.1) },
            distance: length, duration: length / 1.35, stepCount: Int(length / 0.74), shadeFraction: shaded / total,
            shadedDistance: shaded, sunnyDistance: length - shaded, shadedDuration: shaded / 1.35,
            sunnyDuration: (length - shaded) / 1.35, crossingCount: 0, stairsCount: 0, underpassCount: 0,
            maneuvers: maneuvers.map { kind, at in
                Maneuver(kind: kind, streetName: nil, distanceFromStart: at, coordinate: point(startX + at, startY))
            },
            departure: departure, sun: sun)
    }

    static func plan(_ routes: [WalkRoute], weather: WeatherSnapshot? = nil, coolSpots: [CoolSpot] = [],
                     departure: Date = Fixtures.departure) -> RoutePlan {
        RoutePlan(routes: routes, sun: sun, departure: departure, weather: weather, coolSpots: coolSpots)
    }

    static func snapshot(_ time: Date, temperature: Double = 30, cloudCover: Double? = 20) -> WeatherSnapshot {
        WeatherSnapshot(time: time, temperature: temperature, apparentTemperature: temperature + 2, uvIndex: 7,
                        cloudCover: cloudCover, isDay: true)
    }

    static func forecast(at time: Date = Fixtures.departure, temperature: Double = 30,
                         cloudCover: Double? = 20) -> WeatherForecast {
        let hourly = (0..<6).map { snapshot(time.addingTimeInterval(Double($0) * 3600), temperature: temperature,
                                            cloudCover: cloudCover) }
        return WeatherForecast(current: snapshot(time, temperature: temperature, cloudCover: cloudCover), hourly: hourly)
    }
}

// MARK: - Fakes

final class FakeRoutePlanner: RoutePlanning, @unchecked Sendable {
    let recorder: Recorder<RouteRequest, RoutePlan>

    init(_ handler: @escaping Recorder<RouteRequest, RoutePlan>.Handler) {
        recorder = Recorder(handler)
    }

    convenience init(plan: RoutePlan) {
        self.init { _, _ in plan }
    }

    var requests: [RouteRequest] { recorder.requests }

    func plan(_ request: RouteRequest) async throws -> RoutePlan {
        try await recorder.call(request)
    }
}

final class FakeCoolSpotProvider: CoolSpotProviding, @unchecked Sendable {
    struct Request { var coordinate: GeoCoordinate; var radius: Double }
    let recorder: Recorder<Request, [CoolSpot]>

    init(_ handler: @escaping Recorder<Request, [CoolSpot]>.Handler) { recorder = Recorder(handler) }

    func coolSpots(near coordinate: GeoCoordinate, radius: Double) async throws -> [CoolSpot] {
        try await recorder.call(Request(coordinate: coordinate, radius: radius))
    }
}

final class FakeWeatherProvider: WeatherProviding, @unchecked Sendable {
    let recorder: Recorder<GeoCoordinate, WeatherForecast>

    init(_ handler: @escaping Recorder<GeoCoordinate, WeatherForecast>.Handler) { recorder = Recorder(handler) }

    func forecast(at coordinate: GeoCoordinate) async throws -> WeatherForecast {
        try await recorder.call(coordinate)
    }
}

final class FakeDrivingPathProvider: DrivingPathProviding, @unchecked Sendable {
    struct Request { var from: GeoCoordinate; var to: GeoCoordinate }
    let recorder: Recorder<Request, DrivingPath>

    init(_ handler: @escaping Recorder<Request, DrivingPath>.Handler) { recorder = Recorder(handler) }

    func drivingPath(from: GeoCoordinate, to: GeoCoordinate) async throws -> DrivingPath {
        try await recorder.call(Request(from: from, to: to))
    }
}

final class FakeOverlayProvider: ShadeOverlayProviding, @unchecked Sendable {
    struct Request { var bbox: BoundingBox; var date: Date }
    let recorder: Recorder<Request, ShadeOverlay>

    init(_ handler: @escaping Recorder<Request, ShadeOverlay>.Handler) { recorder = Recorder(handler) }

    /// Answers with one square polygon per call, tagged by the call index (in its size).
    convenience init() {
        self.init { request, index in
            let c = request.bbox.center
            let d = 0.0001 * Double(index + 1)
            let square = [c, GeoCoordinate(latitude: c.latitude + d, longitude: c.longitude),
                          GeoCoordinate(latitude: c.latitude + d, longitude: c.longitude + d)]
            return ShadeOverlay(polygons: [square], sun: Fixtures.sun, date: request.date)
        }
    }

    func shadeOverlay(in bbox: BoundingBox, at date: Date) async throws -> ShadeOverlay {
        try await recorder.call(Request(bbox: bbox, date: date))
    }
}

@MainActor
final class FakePlaceSearch: PlaceSearching {
    var suggestionsHandler: (String, Int) async throws -> [PlaceSuggestion]
    var resolveHandler: (PlaceSuggestion) async throws -> Place
    private(set) var queries: [String] = []
    private(set) var nearCoordinates: [GeoCoordinate?] = []
    private(set) var completedQueries = 0

    init(suggestions: @escaping (String, Int) async throws -> [PlaceSuggestion] = { query, _ in
             [PlaceSuggestion(id: query, title: query.capitalized, subtitle: "Seoul")]
         },
         resolve: @escaping (PlaceSuggestion) async throws -> Place = { suggestion in
             Place(id: suggestion.id, name: suggestion.title, subtitle: suggestion.subtitle,
                   coordinate: Fixtures.point(100, 100))
         }) {
        suggestionsHandler = suggestions
        resolveHandler = resolve
    }

    func suggestions(for query: String, near: GeoCoordinate?) async throws -> [PlaceSuggestion] {
        queries.append(query)
        nearCoordinates.append(near)
        defer { completedQueries += 1 }
        return try await suggestionsHandler(query, queries.count - 1)
    }

    func resolve(_ suggestion: PlaceSuggestion) async throws -> Place {
        try await resolveHandler(suggestion)
    }

    func reverseGeocode(_ coordinate: GeoCoordinate) async -> Place? { nil }
}

@MainActor
final class FakeLocationProvider: LocationProviding {
    var authorization: LocationAuthorization = .notDetermined
    var lastFix: LocationFix?
    var authorizationAfterRequest: LocationAuthorization = .authorized
    private(set) var authorizationRequests = 0
    private(set) var continuations: [AsyncStream<LocationFix>.Continuation] = []
    let terminations = Locked(0)

    var subscriptionCount: Int { continuations.count }
    var terminationCount: Int { terminations.current }

    func requestAuthorization() {
        authorizationRequests += 1
        authorization = authorizationAfterRequest
    }

    func fixes() -> AsyncStream<LocationFix> {
        let (stream, continuation) = AsyncStream.makeStream(of: LocationFix.self)
        continuation.onTermination = { [terminations] _ in terminations.mutate { $0 += 1 } }
        continuations.append(continuation)
        return stream
    }

    /// Delivers a fix to every subscriber.
    func send(_ fix: LocationFix) {
        lastFix = fix
        for continuation in continuations { continuation.yield(fix) }
    }

    func finishAll() {
        for continuation in continuations { continuation.finish() }
    }
}
