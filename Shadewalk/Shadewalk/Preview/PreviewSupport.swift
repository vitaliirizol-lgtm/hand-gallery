#if DEBUG
import Foundation
import ShadeFeatures

// Deterministic fakes and sample data for SwiftUI previews: a generic downtown street grid on a fixed summer
// afternoon. Nothing here touches the network, CoreLocation or MapKit.

// MARK: - Sample data

enum PreviewData {
    /// 15 July 2025, 13:30 in `timeZone` (20:30 UTC).
    static let referenceDate = Date(timeIntervalSince1970: 1_752_611_400)
    static let timeZone = TimeZone(identifier: "America/Los_Angeles") ?? TimeZone.current
    /// Centre of the sample street grid.
    static let downtown = GeoCoordinate(latitude: 37.7880, longitude: -122.4075)

    /// Coordinate `east` / `north` metres from `origin`.
    static func point(_ east: Double, _ north: Double, from origin: GeoCoordinate = downtown) -> GeoCoordinate {
        LocalProjection(origin: origin).unproject(Point2D(x: east, y: north))
    }

    static let originPlace = Place(id: "preview-origin", name: "Linden Plaza", subtitle: "Downtown",
                                   coordinate: downtown, kind: .searchResult)
    static let destinationPlace = Place(id: "preview-destination", name: "Central Library",
                                        subtitle: "Harbor Street", coordinate: point(820, 560), kind: .searchResult)

    /// Places offered by `FakePlaceSearch` (and used as recents).
    static let places: [Place] = [
        destinationPlace,
        Place(id: "preview-park", name: "Harbor Park", subtitle: "Waterfront", coordinate: point(-420, 380)),
        Place(id: "preview-market", name: "Linden Avenue Market", subtitle: "Linden Avenue",
              coordinate: point(260, -310)),
        Place(id: "preview-riverside", name: "Riverside Walk", subtitle: "Old Town", coordinate: point(980, -150)),
        Place(id: "preview-hall", name: "City Hall", subtitle: "Civic Center", coordinate: point(-640, -520)),
        Place(id: "preview-cafe", name: "Elm Street Café", subtitle: "Elm Street", coordinate: point(140, 720)),
    ]

    static var recentPlaces: [Place] { Array(places.prefix(3)) }

    /// Cool spots around `origin` (template offsets in metres).
    static func coolSpots(around origin: GeoCoordinate = downtown) -> [CoolSpot] {
        [
            CoolSpot(id: 9_001, kind: .drinkingWater, name: "Corner fountain", coordinate: point(150, -60, from: origin)),
            CoolSpot(id: 9_002, kind: .park, name: "Linden Pocket Park", coordinate: point(310, 120, from: origin)),
            CoolSpot(id: 9_003, kind: .indoorCool, name: "Central Library", coordinate: point(620, 300, from: origin),
                     openingHours: "Mo-Sa 09:00-20:00"),
            CoolSpot(id: 9_004, kind: .shelter, name: nil, coordinate: point(430, 520, from: origin)),
            CoolSpot(id: 9_005, kind: .indoorCool, name: "Galleria Arcade", coordinate: point(700, 610, from: origin)),
            CoolSpot(id: 9_006, kind: .drinkingWater, name: nil, coordinate: point(-120, 260, from: origin)),
        ]
    }

    static func weatherSnapshot(at time: Date, temperature: Double = 31) -> WeatherSnapshot {
        WeatherSnapshot(time: time, temperature: temperature, apparentTemperature: temperature + 3, uvIndex: 8,
                        cloudCover: 12, isDay: true)
    }

    /// Hot, clear summer day with hourly snapshots for the next 24 hours.
    static func forecast(at time: Date = referenceDate) -> WeatherForecast {
        let hourly = (0..<24).map { hour -> WeatherSnapshot in
            let t = time.addingTimeInterval(Double(hour) * 3_600)
            let temperature = 31 - abs(Double(hour) - 2) * 0.6
            return weatherSnapshot(at: t, temperature: max(18, temperature))
        }
        return WeatherForecast(current: weatherSnapshot(at: time), hourly: hourly)
    }

    /// Plan from `originPlace` to `destinationPlace` at `referenceDate`.
    static var samplePlan: RoutePlan {
        plan(for: RouteRequest(origin: originPlace.coordinate, destination: destinationPlace.coordinate,
                               departure: referenceDate))
    }

    /// Shadiest route of `samplePlan`.
    static var sampleRoute: WalkRoute? { samplePlan.routes.first }

    /// Realistic plan for any request: three grid-like routes (shadiest, balanced, fastest) fitted between the
    /// request's ends, with shade runs, maneuvers, elevation and nearby cool spots.
    static func plan(for request: RouteRequest) -> RoutePlan {
        let origin = request.origin
        let destination = request.destination
        let midpoint = GeoMath.interpolate(origin, destination, fraction: 0.5)
        let sun = SolarCalculator.position(at: request.departure, coordinate: midpoint)
        let weather = weatherSnapshot(at: request.departure)
        let projection = LocalProjection(origin: origin)
        let target = projection.project(destination)
        let transform = PreviewSimilarityTransform(from: PreviewRouteTemplate.end, to: target)
        let spots = coolSpots(around: origin).map { spot -> CoolSpot in
            var moved = spot
            moved.coordinate = projection.unproject(transform.apply(projection.project(spot.coordinate)))
            return moved
        }

        guard GeoMath.distance(origin, destination) >= 5 else {
            let route = trivialRoute(from: origin, to: destination, departure: request.departure, sun: sun,
                                     preferences: request.preferences)
            return RoutePlan(routes: [route], sun: sun, departure: request.departure, weather: weather,
                             coolSpots: spots)
        }

        let routes = PreviewRouteTemplate.all.map { template in
            makeRoute(template, projection: projection, transform: transform, departure: request.departure,
                      sun: sun, preferences: request.preferences)
        }
        return RoutePlan(routes: routes, sun: sun, departure: request.departure, weather: weather, coolSpots: spots)
    }

    // MARK: Route construction

    private static func makeRoute(_ template: PreviewRouteTemplate, projection: LocalProjection,
                                  transform: PreviewSimilarityTransform, departure: Date, sun: SunPosition,
                                  preferences: RoutingPreferences) -> WalkRoute {
        let coordinates = template.waypoints.map { projection.unproject(transform.apply($0)) }
        let distance = GeoMath.length(of: coordinates)
        let segments = makeSegments(coordinates, runs: template.shadeRuns, totalLength: distance)
        let shaded = segments.filter(\.isShaded).reduce(0) { $0 + $1.length }
        let sunny = max(0, distance - shaded)
        let speed = max(preferences.walkingSpeed, 0.1)
        let duration = distance / speed + 10 * Double(template.crossings) + 6 * Double(template.stairs)
        return WalkRoute(id: "preview-\(template.profile.rawValue)",
                         profile: template.profile,
                         profiles: template.profiles,
                         coordinates: coordinates,
                         segments: segments,
                         distance: distance,
                         duration: duration,
                         stepCount: Int(distance / max(preferences.strideLength, 0.1)),
                         shadeFraction: distance > 0 ? shaded / distance : 1,
                         shadedDistance: shaded,
                         sunnyDistance: sunny,
                         shadedDuration: shaded / speed,
                         sunnyDuration: sunny / speed,
                         crossingCount: template.crossings,
                         stairsCount: template.stairs,
                         underpassCount: template.underpasses,
                         maneuvers: makeManeuvers(coordinates, streets: template.streets),
                         coolSpotIDs: template.coolSpotIDs,
                         elevation: makeElevation(template.elevations, totalLength: distance),
                         departure: departure,
                         sun: sun)
    }

    private static func trivialRoute(from origin: GeoCoordinate, to destination: GeoCoordinate, departure: Date,
                                     sun: SunPosition, preferences: RoutingPreferences) -> WalkRoute {
        let distance = GeoMath.distance(origin, destination)
        let speed = max(preferences.walkingSpeed, 0.1)
        return WalkRoute(id: "preview-trivial", profile: .shadiest, profiles: RouteProfile.allCases,
                         coordinates: [origin, destination],
                         segments: [RouteSegment(coordinates: [origin, destination], length: distance, isShaded: true)],
                         distance: distance, duration: distance / speed, stepCount: Int(distance / 0.74),
                         shadeFraction: 1, shadedDistance: distance, sunnyDistance: 0,
                         shadedDuration: distance / speed, sunnyDuration: 0, crossingCount: 0, stairsCount: 0,
                         underpassCount: 0,
                         maneuvers: [Maneuver(kind: .depart, streetName: nil, distanceFromStart: 0, coordinate: origin),
                                     Maneuver(kind: .arrive, streetName: nil, distanceFromStart: distance,
                                              coordinate: destination)],
                         departure: departure, sun: sun)
    }

    /// Splits the polyline into runs of the given length fractions.
    private static func makeSegments(_ coordinates: [GeoCoordinate], runs: [PreviewShadeRun],
                                     totalLength: Double) -> [RouteSegment] {
        var remaining = coordinates
        var segments: [RouteSegment] = []
        for (index, run) in runs.enumerated() {
            let piece: [GeoCoordinate]
            if index == runs.count - 1 {
                piece = remaining
            } else {
                let (head, tail) = GeoMath.split(remaining, atDistance: totalLength * run.fraction)
                piece = head
                remaining = tail
            }
            segments.append(RouteSegment(coordinates: piece, length: GeoMath.length(of: piece), isShaded: run.isShaded))
        }
        return segments
    }

    /// Depart, one turn per corner (classified by the turn angle), arrive.
    private static func makeManeuvers(_ coordinates: [GeoCoordinate], streets: [String]) -> [Maneuver] {
        guard let first = coordinates.first, let last = coordinates.last else { return [] }
        var maneuvers = [Maneuver(kind: .depart, streetName: streets.first, distanceFromStart: 0, coordinate: first)]
        var walked = 0.0
        for index in 1..<coordinates.count {
            walked += GeoMath.distance(coordinates[index - 1], coordinates[index])
            guard index < coordinates.count - 1 else { break }
            let incoming = GeoMath.bearing(from: coordinates[index - 1], to: coordinates[index])
            let outgoing = GeoMath.bearing(from: coordinates[index], to: coordinates[index + 1])
            let turn = GeoMath.angleDifference(from: incoming, to: outgoing)
            let street = streets.isEmpty ? nil : streets[index % streets.count]
            maneuvers.append(Maneuver(kind: maneuverKind(forTurn: turn), streetName: street,
                                      distanceFromStart: walked, coordinate: coordinates[index]))
        }
        maneuvers.append(Maneuver(kind: .arrive, streetName: nil, distanceFromStart: walked, coordinate: last))
        return maneuvers
    }

    private static func maneuverKind(forTurn turn: Double) -> ManeuverKind {
        let magnitude = abs(turn)
        let isRight = turn > 0
        if magnitude < 20 { return .continueStraight }
        if magnitude < 45 { return isRight ? .slightRight : .slightLeft }
        if magnitude < 135 { return isRight ? .right : .left }
        if magnitude < 170 { return isRight ? .sharpRight : .sharpLeft }
        return .uTurn
    }

    private static func makeElevation(_ elevations: [Double], totalLength: Double) -> ElevationProfile? {
        guard elevations.count >= 2, totalLength > 0 else { return nil }
        let spacing = totalLength / Double(elevations.count - 1)
        var ascent = 0.0, descent = 0.0
        var bins: [SlopeBin] = []
        for index in 1..<elevations.count {
            let rise = elevations[index] - elevations[index - 1]
            if rise > 0 { ascent += rise } else { descent -= rise }
            bins.append(SlopeBin(grade: rise / spacing))
        }
        let maxGrade = bins.map { abs($0.grade) }.max() ?? 0
        return ElevationProfile(elevations: elevations, sampleSpacing: spacing, ascent: ascent, descent: descent,
                                maxGrade: maxGrade, bins: bins)
    }
}

/// Fraction of a route's length that is shaded or sunny.
struct PreviewShadeRun: Hashable, Sendable {
    var fraction: Double
    var isShaded: Bool

    init(_ fraction: Double, shaded: Bool) {
        self.fraction = fraction
        self.isShaded = shaded
    }
}

/// Shape of a sample route in metres (east, north) from (0, 0) to `PreviewRouteTemplate.end`.
struct PreviewRouteTemplate: Sendable {
    static let end = Point2D(x: 820, y: 560)

    var profile: RouteProfile
    var profiles: [RouteProfile]
    var waypoints: [Point2D]
    var shadeRuns: [PreviewShadeRun]
    var streets: [String]
    var crossings: Int
    var stairs: Int
    var underpasses: Int
    var coolSpotIDs: [Int64]
    /// 13 samples → 12 slope bins.
    var elevations: [Double]

    static let all: [PreviewRouteTemplate] = [
        PreviewRouteTemplate(profile: .shadiest, profiles: [.shadiest],
                      waypoints: [Point2D(x: 0, y: 0), Point2D(x: 0, y: -90), Point2D(x: 300, y: -90),
                                  Point2D(x: 300, y: 240), Point2D(x: 640, y: 240), Point2D(x: 640, y: 560),
                                  Point2D(x: 820, y: 560)],
                      shadeRuns: [PreviewShadeRun(0.20, shaded: true), PreviewShadeRun(0.07, shaded: false),
                                  PreviewShadeRun(0.38, shaded: true), PreviewShadeRun(0.06, shaded: false),
                                  PreviewShadeRun(0.29, shaded: true)],
                      streets: ["Linden Avenue", "Elm Walk", "Cedar Lane", "Park Terrace", "Harbor Street"],
                      crossings: 3, stairs: 1, underpasses: 1, coolSpotIDs: [9_001, 9_002, 9_003],
                      elevations: [18, 18.4, 19.1, 20.6, 22.4, 23.0, 22.8, 21.9, 21.0, 20.4, 20.1, 19.8, 19.6]),
        PreviewRouteTemplate(profile: .balanced, profiles: [.balanced],
                      waypoints: [Point2D(x: 0, y: 0), Point2D(x: 180, y: 0), Point2D(x: 180, y: 330),
                                  Point2D(x: 600, y: 330), Point2D(x: 600, y: 600), Point2D(x: 820, y: 600),
                                  Point2D(x: 820, y: 560)],
                      shadeRuns: [PreviewShadeRun(0.28, shaded: true), PreviewShadeRun(0.14, shaded: false),
                                  PreviewShadeRun(0.30, shaded: true), PreviewShadeRun(0.12, shaded: false),
                                  PreviewShadeRun(0.16, shaded: true)],
                      streets: ["Linden Avenue", "Willow Street", "Market Row", "Harbor Street"],
                      crossings: 4, stairs: 0, underpasses: 0, coolSpotIDs: [9_003],
                      elevations: [18, 18.2, 18.9, 19.8, 20.9, 21.5, 21.6, 21.2, 20.7, 20.2, 19.9, 19.7, 19.6]),
        PreviewRouteTemplate(profile: .fastest, profiles: [.fastest],
                      waypoints: [Point2D(x: 0, y: 0), Point2D(x: 420, y: 0), Point2D(x: 420, y: 560),
                                  Point2D(x: 820, y: 560)],
                      shadeRuns: [PreviewShadeRun(0.22, shaded: false), PreviewShadeRun(0.18, shaded: true),
                                  PreviewShadeRun(0.36, shaded: false), PreviewShadeRun(0.24, shaded: true)],
                      streets: ["Linden Avenue", "Market Row", "Harbor Street"],
                      crossings: 5, stairs: 0, underpasses: 0, coolSpotIDs: [],
                      elevations: [18, 18.6, 19.9, 21.8, 23.9, 25.1, 24.6, 23.2, 21.8, 20.9, 20.2, 19.8, 19.6]),
    ]
}

/// Rotation + uniform scale mapping the template's (0, 0) → `from` vector onto (0, 0) → `to`.
struct PreviewSimilarityTransform: Sendable {
    private let cosine: Double
    private let sine: Double

    init(from: Point2D, to: Point2D) {
        let fromLength = max(from.length, 1e-9)
        let scale = to.length / fromLength
        let angle = atan2(to.y, to.x) - atan2(from.y, from.x)
        cosine = scale * cos(angle)
        sine = scale * sin(angle)
    }

    func apply(_ p: Point2D) -> Point2D {
        Point2D(x: p.x * cosine - p.y * sine, y: p.x * sine + p.y * cosine)
    }
}

// MARK: - Fakes

/// Plans `PreviewData.plan(for:)` after a short, realistic delay.
struct FakeRoutePlanner: RoutePlanning {
    var latency: TimeInterval = 0.6

    func plan(_ request: RouteRequest) async throws -> RoutePlan {
        try await Task.sleep(nanoseconds: UInt64(max(0, latency) * 1_000_000_000))
        return PreviewData.plan(for: request)
    }
}

/// Always a hot, clear afternoon.
struct FakeWeather: WeatherProviding {
    func forecast(at coordinate: GeoCoordinate) async throws -> WeatherForecast {
        PreviewData.forecast()
    }
}

/// Cool spots from `PreviewData` within `radius`.
struct FakeCoolSpots: CoolSpotProviding {
    func coolSpots(near coordinate: GeoCoordinate, radius: Double) async throws -> [CoolSpot] {
        PreviewData.coolSpots(around: coordinate).filter { GeoMath.distance($0.coordinate, coordinate) <= radius }
    }
}

/// L-shaped road between the two points (≈ 8 m/s).
struct FakeDrivingPaths: DrivingPathProviding {
    func drivingPath(from: GeoCoordinate, to: GeoCoordinate) async throws -> DrivingPath {
        let corner = GeoCoordinate(latitude: from.latitude, longitude: to.longitude)
        let path = GeoMath.resample([from, corner, to], spacing: 50)
        let length = GeoMath.length(of: path)
        guard length > 0 else { throw ShadeError.noRouteFound }
        return DrivingPath(coordinates: path, expectedTravelTime: length / 8)
    }
}

/// Building shadows as convex hulls of a few block footprints swept along the shadow direction.
struct FakeOverlayProvider: ShadeOverlayProviding {
    func shadeOverlay(in bbox: BoundingBox, at date: Date) async throws -> ShadeOverlay {
        let center = bbox.center
        let sun = SolarCalculator.position(at: date, coordinate: center)
        guard sun.isUp else { return ShadeOverlay(polygons: [], sun: sun, date: date) }
        let projection = LocalProjection(origin: center)
        let direction = sun.shadowDirection
        var polygons: [[GeoCoordinate]] = []
        for column in -2...2 {
            for row in -2...2 {
                let height = 12 + Double((column + 2) * 7 + (row + 2) * 5).truncatingRemainder(dividingBy: 30)
                let length = min(sun.shadowLength(forHeight: height), 80)
                let x = Double(column) * 110, y = Double(row) * 90
                let footprint = [Point2D(x: x - 30, y: y - 22), Point2D(x: x + 30, y: y - 22),
                                 Point2D(x: x + 30, y: y + 22), Point2D(x: x - 30, y: y + 22)]
                let swept = footprint + footprint.map { $0 + direction * length }
                polygons.append(projection.unproject(PreviewConvexHull.of(swept)))
            }
        }
        return ShadeOverlay(polygons: polygons, sun: sun, date: date)
    }
}

/// Monotone-chain convex hull (counter-clockwise, open ring).
enum PreviewConvexHull {
    static func of(_ points: [Point2D]) -> [Point2D] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count > 2 else { return sorted }
        var lower: [Point2D] = []
        for p in sorted {
            while lower.count >= 2, (lower[lower.count - 1] - lower[lower.count - 2]).cross(p - lower[lower.count - 2]) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [Point2D] = []
        for p in sorted.reversed() {
            while upper.count >= 2, (upper[upper.count - 1] - upper[upper.count - 2]).cross(p - upper[upper.count - 2]) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }
}

/// Authorized, standing at `PreviewData.downtown`. `send(_:)` pushes a fix to every open stream.
@MainActor
final class FakeLocationProvider: LocationProviding {
    var authorization: LocationAuthorization
    var lastFix: LocationFix?
    private var continuations: [UUID: AsyncStream<LocationFix>.Continuation] = [:]

    init(authorization: LocationAuthorization = .authorized,
         coordinate: GeoCoordinate? = PreviewData.downtown) {
        self.authorization = authorization
        // Stamped with the real clock: screens only treat a recent fix as the user's current position.
        lastFix = coordinate.map {
            LocationFix(coordinate: $0, horizontalAccuracy: 5, course: 45, heading: 45, speed: 1.3,
                        timestamp: Date())
        }
    }

    func requestAuthorization() {
        authorization = .authorized
    }

    func fixes() -> AsyncStream<LocationFix> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: LocationFix.self, bufferingPolicy: .bufferingNewest(8))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.continuations[id] = nil
            }
        }
        continuations[id] = continuation
        if let lastFix { continuation.yield(lastFix) }
        return stream
    }

    func send(_ fix: LocationFix) {
        lastFix = fix
        for continuation in continuations.values {
            continuation.yield(fix)
        }
    }
}

/// Filters `PreviewData.places` by the query.
@MainActor
final class FakePlaceSearch: PlaceSearching {
    func suggestions(for query: String, near: GeoCoordinate?) async throws -> [PlaceSuggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return PreviewData.places
            .filter { place in
                place.name.localizedCaseInsensitiveContains(text)
                    || (place.subtitle?.localizedCaseInsensitiveContains(text) ?? false)
            }
            .map { PlaceSuggestion(id: $0.id, title: $0.name, subtitle: $0.subtitle ?? "") }
    }

    func resolve(_ suggestion: PlaceSuggestion) async throws -> Place {
        guard let place = PreviewData.places.first(where: { $0.id == suggestion.id }) else {
            throw ShadeError.noRouteFound
        }
        return place
    }

    func reverseGeocode(_ coordinate: GeoCoordinate) async -> Place? {
        Place(id: String(format: "pin:%.5f,%.5f", coordinate.latitude, coordinate.longitude),
              name: PlaceKind.droppedPin.displayName, subtitle: nil, coordinate: coordinate, kind: .droppedPin)
    }
}

// MARK: - Preview environment

extension AppEnvironment {
    /// Environment wired to the fakes above with a fixed clock (`PreviewData.referenceDate`).
    ///
    /// - Parameters:
    ///   - onboarded: start past onboarding.
    ///   - planned: preset origin → destination so the Walk screen plans the sample routes.
    static func preview(onboarded: Bool = true, planned: Bool = true) -> AppEnvironment {
        let store = InMemoryKeyValueStore()
        if let settings = try? JSONEncoder().encode(AppSettings(hasCompletedOnboarding: onboarded)) {
            store.set(settings, forKey: ShadeFeaturesStorageKeys.settings)
        }
        if let recents = try? JSONEncoder().encode(PreviewData.recentPlaces) {
            store.set(recents, forKey: ShadeFeaturesStorageKeys.recentPlaces)
        }
        let environment = AppEnvironment(store: store,
                                         routePlanning: FakeRoutePlanner(),
                                         overlayProvider: FakeOverlayProvider(),
                                         coolSpotProvider: FakeCoolSpots(),
                                         weatherProvider: FakeWeather(),
                                         drivingPaths: FakeDrivingPaths(),
                                         locationProvider: FakeLocationProvider(),
                                         placeSearch: FakePlaceSearch(),
                                         now: { PreviewData.referenceDate },
                                         timeZone: PreviewData.timeZone)
        if planned {
            environment.planner.origin = PreviewData.originPlace
            environment.planner.destination = PreviewData.destinationPlace
        }
        return environment
    }
}
#endif
