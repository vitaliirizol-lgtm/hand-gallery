import Foundation
import XCTest
@testable import ShadeCore

// Fakes and fixtures shared by RoutePlannerTests and EndToEndTests. None of them touch the network.

/// Thread-safe call log.
final class PlannerCallLog<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ v: Value) {
        lock.lock(); defer { lock.unlock() }
        values.append(v)
    }

    var all: [Value] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    var count: Int { all.count }
}

/// One-shot latch: `wait()` suspends until `open()`.
actor PlannerGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

/// Polls `condition` every 2 ms for up to `timeout` seconds; false on timeout.
func plannerEventually(timeout: TimeInterval = 2, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return await condition()
}

/// Mutable clock for the planner's weather cache.
final class PlannerClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

/// `AreaDataProviding` driven by a handler; records each requested bbox.
final class PlannerAreaProvider: AreaDataProviding, @unchecked Sendable {
    typealias Handler = @Sendable (BoundingBox) async throws -> AreaData
    let requests = PlannerCallLog<BoundingBox>()
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    convenience init(area: AreaData) { self.init { _ in area } }

    var callCount: Int { requests.count }

    func areaData(for bbox: BoundingBox) async throws -> AreaData {
        requests.append(bbox)
        return try await handler(bbox)
    }
}

/// Area provider that also answers cool-spot queries directly (like `OverpassClient`).
final class PlannerCoolSpotAreaProvider: AreaDataProviding, CoolSpotProviding, @unchecked Sendable {
    let areaRequests = PlannerCallLog<BoundingBox>()
    let coolSpotRequests = PlannerCallLog<Double>()
    private let area: AreaData
    private let spots: [CoolSpot]

    init(area: AreaData, spots: [CoolSpot]) {
        self.area = area
        self.spots = spots
    }

    func areaData(for bbox: BoundingBox) async throws -> AreaData {
        areaRequests.append(bbox)
        return area
    }

    func coolSpots(near coordinate: GeoCoordinate, radius: Double) async throws -> [CoolSpot] {
        coolSpotRequests.append(radius)
        return spots
    }
}

/// `ElevationProviding` driven by a handler; records each request's coordinates.
final class PlannerElevationProvider: ElevationProviding, @unchecked Sendable {
    typealias Handler = @Sendable ([GeoCoordinate]) async throws -> [Double]
    let requests = PlannerCallLog<[GeoCoordinate]>()
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    /// Terrain rising 5 m per 100 m northwards from `baseLatitude`.
    static func northSlope(baseLatitude: Double) -> PlannerElevationProvider {
        PlannerElevationProvider { coords in
            coords.map { 20 + ($0.latitude - baseLatitude) * GeoMath.metersPerDegreeLatitude * 0.05 }
        }
    }

    func elevations(for coordinates: [GeoCoordinate]) async throws -> [Double] {
        requests.append(coordinates)
        return try await handler(coordinates)
    }
}

/// `WeatherProviding` driven by a handler; records each requested coordinate.
final class PlannerWeatherProvider: WeatherProviding, @unchecked Sendable {
    typealias Handler = @Sendable (GeoCoordinate) async throws -> WeatherForecast
    let requests = PlannerCallLog<GeoCoordinate>()
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    /// Hourly forecast from `start` for 48 h; temperature = 20 + hour index.
    static func hourly(from start: Date) -> PlannerWeatherProvider {
        PlannerWeatherProvider { _ in PlannerFixtures.forecast(from: start) }
    }

    func forecast(at coordinate: GeoCoordinate) async throws -> WeatherForecast {
        requests.append(coordinate)
        return try await handler(coordinate)
    }
}

enum PlannerFixtures {
    /// Central Seoul.
    static let center = GeoCoordinate(latitude: 37.5665, longitude: 126.9780)
    static let projection = LocalProjection(origin: center)
    /// 2026-07-15 12:00 KST (UTC+9): sun high in the south.
    static let summerNoon = Date(timeIntervalSince1970: 1_784_084_400)
    /// 2026-07-15 00:00 KST: sun down.
    static let summerMidnight = summerNoon.addingTimeInterval(-12 * 3600)

    /// Coordinate `x` m east and `y` m north of `origin`.
    static func pt(_ x: Double, _ y: Double, origin: GeoCoordinate = center) -> GeoCoordinate {
        LocalProjection(origin: origin).unproject(Point2D(x: x, y: y))
    }

    static func forecast(from start: Date) -> WeatherForecast {
        let hourly = (0..<48).map { h in
            WeatherSnapshot(time: start.addingTimeInterval(Double(h) * 3600), temperature: 20 + Double(h),
                            apparentTemperature: 21 + Double(h), uvIndex: 5, cloudCover: 10, isDay: true)
        }
        return WeatherForecast(current: hourly[0], hourly: hourly)
    }

    /// `n × n` street grid (`spacing` m) centred on `origin`, a 20 m building in every block, a row of trees
    /// along the southern street and three cool spots (one far outside the grid).
    static func gridArea(origin: GeoCoordinate = center, n: Int = 4, spacing: Double = 100,
                         bbox: BoundingBox? = nil, fetchedAt: Date = summerNoon) -> AreaData {
        let half = Double(n - 1) * spacing / 2
        func p(_ i: Int, _ j: Int) -> GeoCoordinate { pt(Double(i) * spacing - half, Double(j) * spacing - half, origin: origin) }
        var nodes: [GraphNode] = []
        for j in 0..<n {
            for i in 0..<n {
                nodes.append(GraphNode(id: j * n + i, osmID: Int64(j * n + i + 1), coordinate: p(i, j)))
            }
        }
        var edges: [GraphEdge] = []
        func addEdge(_ a: Int, _ b: Int, name: String) {
            let geometry = [nodes[a].coordinate, nodes[b].coordinate]
            edges.append(GraphEdge(id: edges.count, from: a, to: b, geometry: geometry,
                                   length: GeoMath.length(of: geometry), wayClass: .footway, name: name,
                                   wayID: Int64(100 + edges.count)))
        }
        for j in 0..<n {
            for i in 0..<n {
                if i + 1 < n { addEdge(j * n + i, j * n + i + 1, name: "Street \(j)") }
                if j + 1 < n { addEdge(j * n + i, (j + 1) * n + i, name: "Avenue \(i)") }
            }
        }
        var buildings: [Building] = []
        for j in 0..<(n - 1) {
            for i in 0..<(n - 1) {
                let cx = (Double(i) + 0.5) * spacing - half, cy = (Double(j) + 0.5) * spacing - half
                let r = spacing * 0.3
                buildings.append(Building(id: Int64(1000 + j * n + i),
                                          footprint: [pt(cx - r, cy - r, origin: origin), pt(cx + r, cy - r, origin: origin),
                                                      pt(cx + r, cy + r, origin: origin), pt(cx - r, cy + r, origin: origin)],
                                          height: 20))
            }
        }
        let trees = (0..<n).map { i in
            Tree(id: Int64(5000 + i), coordinate: pt(Double(i) * spacing - half, -half + 4, origin: origin))
        }
        let spots = [
            CoolSpot(id: 1, kind: .drinkingWater, name: "Fountain", coordinate: pt(-half, -half + 10, origin: origin)),
            CoolSpot(id: 2, kind: .park, name: "Pocket Park", coordinate: pt(10, 10, origin: origin)),
            CoolSpot(id: 3, kind: .indoorCool, name: "Far Library", coordinate: pt(3000, 3000, origin: origin)),
        ]
        let box = bbox ?? BoundingBox(coordinates: nodes.map(\.coordinate))?.expanded(byMeters: 200)
            ?? BoundingBox(minLatitude: 0, minLongitude: 0, maxLatitude: 0, maxLongitude: 0)
        return AreaData(bbox: box, buildings: buildings, trees: trees, canopies: [],
                        graph: WalkGraph(nodes: nodes, edges: edges), coolSpots: spots, fetchedAt: fetchedAt)
    }

    static func emptyArea(bbox: BoundingBox) -> AreaData {
        AreaData(bbox: bbox, buildings: [], trees: [], canopies: [], graph: .empty, coolSpots: [], fetchedAt: summerNoon)
    }
}

/// Asserts route-level invariants that every planned route must satisfy.
func assertConsistent(_ route: WalkRoute, preferences: RoutingPreferences = .default,
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertGreaterThanOrEqual(route.coordinates.count, 1, file: file, line: line)
    XCTAssertEqual(route.distance, GeoMath.length(of: route.coordinates), accuracy: 0.01, file: file, line: line)
    // Shade runs measure in the engine's projection; allow 0.1 % against great-circle lengths.
    let tolerance = max(0.05, route.distance * 1e-3)
    XCTAssertEqual(route.shadedDistance + route.sunnyDistance, route.distance, accuracy: tolerance, file: file, line: line)
    XCTAssertEqual(route.segments.reduce(0) { $0 + $1.length }, route.shadedDistance + route.sunnyDistance,
                   accuracy: tolerance, file: file, line: line)
    XCTAssertTrue((0...1).contains(route.shadeFraction), "shadeFraction \(route.shadeFraction)", file: file, line: line)
    XCTAssertGreaterThanOrEqual(route.duration, route.distance / preferences.walkingSpeed - 1e-6, file: file, line: line)
    XCTAssertEqual(route.shadedDuration + route.sunnyDuration, route.duration, accuracy: 1e-6, file: file, line: line)
    XCTAssertEqual(route.stepCount, Int((route.distance / preferences.strideLength).rounded()), file: file, line: line)
    XCTAssertEqual(route.maneuvers.first?.kind, .depart, file: file, line: line)
    XCTAssertEqual(route.maneuvers.last?.kind, .arrive, file: file, line: line)
    XCTAssertFalse(route.profiles.isEmpty, file: file, line: line)
    XCTAssertEqual(route.profiles.first, route.profile, file: file, line: line)
}
