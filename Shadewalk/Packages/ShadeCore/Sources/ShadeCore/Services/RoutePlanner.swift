import Foundation

/// Orchestrates area fetch → shade → routing → elevation; caches area data so departure-time changes only
/// recompute shade and routes. See SPEC §4.
///
/// Caches (in memory, per planner):
/// - up to `maxCachedAreas` areas, least recently used dropped first. Any cached area whose bbox contains the
///   needed box is reused, and a request whose box lies inside an in-flight fetch waits for that fetch.
/// - one `ShadeEngine` per area, built on first use.
/// - per area, edge shade fractions for up to `maxShadeTimesPerArea` departure times rounded to `shadeTimeStep`
///   (computed with the sun at the area centre at the rounded time), plus the router for the latest one.
/// - the last weather forecast, reused for `weatherReuseInterval` within `weatherReuseDistance`.
///
/// Origin and destination closer than `samePlaceDistance` give a trivial plan (no routing, so no network
/// snapping): one straight route merged across all three profiles, still with shade, cool spots, elevation
/// and weather.
///
/// Cancellation is checked between expensive steps and throws `ShadeError.cancelled`. A cancelled caller stops
/// waiting for an area fetch at once, but the fetch itself runs on and is cached for the next request.
public actor RoutePlanner: RoutePlanning, ShadeOverlayProviding, CoolSpotProviding {
    /// Straight-line limit for walking routes, metres.
    public static let maxStraightLineDistance: Double = 5_000
    /// Origin and destination closer than this get a trivial plan, metres.
    public static let samePlaceDistance: Double = 5
    /// Margin added around origin and destination when fetching an area, metres.
    public static let areaPadding: Double = 300
    /// Minimum side of a fetched area, metres.
    public static let minimumAreaSide: Double = 800
    /// Areas kept in memory.
    public static let maxCachedAreas = 3
    /// Departure times are rounded to this step for the edge shade cache, seconds.
    public static let shadeTimeStep: TimeInterval = 300
    /// Edge shade arrays kept per area (one per rounded departure time).
    public static let maxShadeTimesPerArea = 12
    /// Overlay requests with a longer side return no polygons, metres.
    public static let maxOverlaySide: Double = 3_000
    /// Margin fetched around an overlay box so shadows cast from just outside it are included, metres.
    public static let overlayPadding: Double = 100
    /// Largest single elevation request, coordinates.
    public static let maxElevationCoordinates = 100
    /// A forecast younger than this is reused, seconds.
    public static let weatherReuseInterval: TimeInterval = 15 * 60
    /// A forecast fetched within this distance is reused, metres.
    public static let weatherReuseDistance: Double = 2_000

    private let areaProvider: AreaDataProviding
    private let elevationProvider: ElevationProviding?
    private let weatherProvider: WeatherProviding?
    private let now: @Sendable () -> Date

    /// A fetched area and everything derived from it. Only touched on the actor.
    private final class CachedArea {
        let id: Int
        /// Box the area was fetched for (what it is known to cover).
        let bbox: BoundingBox
        let data: AreaData
        var engine: ShadeEngine?
        /// Edge shade by rounded departure bucket.
        var edgeShade: [Int64: [Double]] = [:]
        /// Buckets in `edgeShade`, least recently used first.
        var shadeOrder: [Int64] = []
        /// Router for the most recently used bucket.
        var router: (bucket: Int64, router: WalkRouter)?
        var lastUsed = 0

        init(id: Int, bbox: BoundingBox, data: AreaData) {
            self.id = id
            self.bbox = bbox
            self.data = data
        }

        var handle: AreaHandle { AreaHandle(id: id, bbox: bbox, data: data) }
    }

    /// Sendable reference to a cached area, handed to waiting callers.
    private struct AreaHandle: Sendable {
        let id: Int
        let bbox: BoundingBox
        let data: AreaData
    }

    private struct PendingFetch {
        /// Id the fetched area will get.
        let id: Int
        let bbox: BoundingBox
        var waiters: [Int: CheckedContinuation<AreaHandle, Error>] = [:]
    }

    private var areas: [CachedArea] = []
    private var pending: [Int: PendingFetch] = [:]
    private var nextID = 0
    private var useTick = 0
    private var lastForecast: (coordinate: GeoCoordinate, fetchedAt: Date, forecast: WeatherForecast)?

    // Diagnostics (tests prove caching with these).
    private(set) var engineBuildCount = 0
    private(set) var edgeShadeComputationCount = 0
    private(set) var routerBuildCount = 0
    var cachedAreaBoxes: [BoundingBox] { areas.map(\.bbox) }
    var pendingWaiterCount: Int { pending.values.reduce(0) { $0 + $1.waiters.count } }

    public init(areaProvider: AreaDataProviding, elevationProvider: ElevationProviding?, weatherProvider: WeatherProviding?) {
        self.init(areaProvider: areaProvider, elevationProvider: elevationProvider, weatherProvider: weatherProvider,
                  now: { Date() })
    }

    /// - Parameter now: clock for the weather cache, injectable for tests.
    public init(areaProvider: AreaDataProviding, elevationProvider: ElevationProviding?, weatherProvider: WeatherProviding?,
                now: @escaping @Sendable () -> Date) {
        self.areaProvider = areaProvider
        self.elevationProvider = elevationProvider
        self.weatherProvider = weatherProvider
        self.now = now
    }

    // MARK: - RoutePlanning

    /// Routes for `request`, ordered shadiest → balanced → fastest (identical routes merged).
    ///
    /// - Throws: `ShadeError.originTooFarFromNetwork` / `.destinationTooFarFromNetwork` (also for invalid
    ///   coordinates), `.tooFar`, `.noWalkableNetwork`, `.noRouteFound`, `.cancelled`, or the area provider's
    ///   error. Elevation and weather failures are not fatal (the fields stay nil).
    public func plan(_ request: RouteRequest) async throws -> RoutePlan {
        let origin = request.origin, destination = request.destination
        guard origin.isValid else { throw ShadeError.originTooFarFromNetwork }
        guard destination.isValid else { throw ShadeError.destinationTooFarFromNetwork }
        let straight = GeoMath.distance(origin, destination)
        guard straight <= Self.maxStraightLineDistance else {
            throw ShadeError.tooFar(distance: straight, limit: Self.maxStraightLineDistance)
        }
        try Self.checkCancellation()

        let midpoint = GeoMath.interpolate(origin, destination, fraction: 0.5)
        let sun = SolarCalculator.position(at: request.departure, coordinate: midpoint)
        let bbox = Self.planningBox(origin, destination)
        let area = try await self.area(covering: bbox, fetching: bbox)
        try Self.checkCancellation()

        var routes: [WalkRoute]
        if straight < Self.samePlaceDistance {
            routes = [samePlaceRoute(from: origin, to: destination, area: area, request: request, sun: sun)]
        } else {
            guard !area.data.graph.isEmpty else { throw ShadeError.noWalkableNetwork }
            let router = self.router(for: area, departure: request.departure)
            try Self.checkCancellation()
            routes = try router.alternatives(from: origin, to: destination, preferences: request.preferences, sun: sun,
                                             departure: request.departure)
        }
        try Self.checkCancellation()

        let elevationProvider = self.elevationProvider
        let routesForElevation = routes
        async let profiles = Self.elevationProfiles(for: routesForElevation, provider: elevationProvider)
        async let weather = weatherSnapshot(near: midpoint, at: request.departure)
        let (elevations, snapshot) = await (profiles, weather)
        try Self.checkCancellation()
        for i in routes.indices where i < elevations.count {
            routes[i].elevation = elevations[i]
        }

        let spots = area.data.coolSpots.filter { bbox.contains($0.coordinate) }
        return RoutePlan(routes: routes, sun: sun, departure: request.departure, weather: snapshot, coolSpots: spots)
    }

    // MARK: - ShadeOverlayProviding

    /// Shadow polygons inside `bbox` at `date`. Empty, without fetching anything, when the sun is down, the box
    /// is invalid, or its longer side exceeds `maxOverlaySide`.
    public func shadeOverlay(in bbox: BoundingBox, at date: Date) async throws -> ShadeOverlay {
        let sun = SolarCalculator.position(at: date, coordinate: bbox.center)
        let side = max(bbox.widthMeters, bbox.heightMeters)
        guard Self.isValid(bbox), side <= Self.maxOverlaySide, sun.isUp else {
            return ShadeOverlay(polygons: [], sun: sun, date: date)
        }
        try Self.checkCancellation()
        let fetchBox = bbox.expanded(byMeters: Self.overlayPadding).ensuringMinimumSize(meters: Self.minimumAreaSide)
        let area = try await self.area(covering: bbox, fetching: fetchBox)
        try Self.checkCancellation()
        let polygons = engine(for: area).shadowPolygons(sun: sun, within: bbox)
        return ShadeOverlay(polygons: polygons, sun: sun, date: date)
    }

    // MARK: - CoolSpotProviding

    /// Cool spots within `radius` metres of `coordinate`, nearest first.
    ///
    /// Served from a cached area covering the circle; otherwise from the area provider when it is also a
    /// `CoolSpotProviding` (e.g. `OverpassClient`); otherwise from an area fetch, whose radius is capped at
    /// half of `maxOverlaySide`. An invalid coordinate or a non-positive radius gives `[]`.
    public func coolSpots(near coordinate: GeoCoordinate, radius: Double) async throws -> [CoolSpot] {
        guard coordinate.isValid, radius.isFinite, radius > 0 else { return [] }
        var r = radius
        let spots: [CoolSpot]
        if let hit = cachedArea(covering: Self.box(around: coordinate, radius: r)) {
            touch(hit)
            spots = hit.data.coolSpots
        } else if let provider = areaProvider as? CoolSpotProviding {
            spots = try await provider.coolSpots(near: coordinate, radius: r)
        } else {
            r = min(r, Self.maxOverlaySide / 2)
            let circle = Self.box(around: coordinate, radius: r)
            let area = try await self.area(covering: circle,
                                           fetching: circle.ensuringMinimumSize(meters: Self.minimumAreaSide))
            spots = area.data.coolSpots
        }
        try Self.checkCancellation()
        return Self.nearest(spots, to: coordinate, within: r).map(\.spot)
    }

    // MARK: - Area cache

    /// A cached area covering `needed`, else the result of an in-flight fetch covering it, else a new fetch of
    /// `fetchBox`. The caller stops waiting (throwing `.cancelled`) when cancelled; the fetch keeps going.
    private func area(covering needed: BoundingBox, fetching fetchBox: BoundingBox) async throws -> CachedArea {
        if let hit = cachedArea(covering: needed) {
            touch(hit)
            return hit
        }
        nextID += 1
        let waiterID = nextID
        let handle = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<AreaHandle, Error>) in
                // Runs synchronously on the actor, so nothing can finish between these checks and registration.
                if Task.isCancelled {
                    cont.resume(throwing: ShadeError.cancelled)
                } else if let hit = cachedArea(covering: needed) {
                    cont.resume(returning: hit.handle)
                } else {
                    let fetchID = pendingFetchID(covering: needed) ?? startFetch(fetchBox)
                    if pending[fetchID] != nil {
                        pending[fetchID]?.waiters[waiterID] = cont
                    } else {
                        cont.resume(throwing: ShadeError.networkUnavailable)
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        // Normally still cached; re-added if a burst of other fetches evicted it meanwhile.
        let area = areas.first { $0.id == handle.id } ?? insert(CachedArea(id: handle.id, bbox: handle.bbox, data: handle.data))
        touch(area)
        return area
    }

    private func cachedArea(covering box: BoundingBox) -> CachedArea? {
        areas.filter { $0.bbox.contains(box) }.max { $0.lastUsed < $1.lastUsed }
    }

    private func pendingFetchID(covering box: BoundingBox) -> Int? {
        pending.filter { $0.value.bbox.contains(box) }.keys.min()
    }

    private func startFetch(_ bbox: BoundingBox) -> Int {
        nextID += 1
        let id = nextID
        pending[id] = PendingFetch(id: id, bbox: bbox)
        let provider = areaProvider
        Task {
            let result: Result<AreaData, Error>
            do {
                result = .success(try await provider.areaData(for: bbox))
            } catch {
                result = .failure(error)
            }
            // The task inherits the actor's isolation.
            self.finishFetch(id, bbox: bbox, result: result)
        }
        return id
    }

    private func finishFetch(_ id: Int, bbox: BoundingBox, result: Result<AreaData, Error>) {
        guard let fetch = pending.removeValue(forKey: id) else { return }
        switch result {
        case let .success(data):
            let handle = insert(CachedArea(id: fetch.id, bbox: bbox, data: data)).handle
            for cont in fetch.waiters.values { cont.resume(returning: handle) }
        case let .failure(error):
            let mapped: Error = error is CancellationError ? ShadeError.cancelled : error
            for cont in fetch.waiters.values { cont.resume(throwing: mapped) }
        }
    }

    private func cancelWaiter(_ waiterID: Int) {
        for (id, fetch) in pending {
            guard let cont = fetch.waiters[waiterID] else { continue }
            pending[id]?.waiters.removeValue(forKey: waiterID)
            cont.resume(throwing: ShadeError.cancelled)
            return
        }
    }

    /// Adds `area`, dropping cached areas it covers and then the least recently used beyond the limit.
    private func insert(_ area: CachedArea) -> CachedArea {
        areas.removeAll { area.bbox.contains($0.bbox) }
        touch(area)
        areas.append(area)
        while areas.count > Self.maxCachedAreas,
              let oldest = areas.indices.min(by: { areas[$0].lastUsed < areas[$1].lastUsed }) {
            areas.remove(at: oldest)
        }
        return area
    }

    private func touch(_ area: CachedArea) {
        useTick += 1
        area.lastUsed = useTick
    }

    // MARK: - Shade and routing

    private func engine(for area: CachedArea) -> ShadeEngine {
        if let engine = area.engine { return engine }
        let engine = ShadeEngine(area: area.data)
        engineBuildCount += 1
        area.engine = engine
        return engine
    }

    /// Router over the area's graph with edge shade for `departure` rounded to `shadeTimeStep`.
    private func router(for area: CachedArea, departure: Date) -> WalkRouter {
        let bucket = Self.shadeBucket(departure)
        if let cached = area.router, cached.bucket == bucket {
            markShadeUsed(bucket, in: area)
            return cached.router
        }
        let shade: [Double]
        if let cached = area.edgeShade[bucket] {
            shade = cached
        } else {
            let time = Date(timeIntervalSince1970: Double(bucket) * Self.shadeTimeStep)
            let sun = SolarCalculator.position(at: time, coordinate: area.data.bbox.center)
            shade = engine(for: area).edgeShadeFractions(for: area.data.graph, sun: sun)
            edgeShadeComputationCount += 1
            area.edgeShade[bucket] = shade
        }
        markShadeUsed(bucket, in: area)
        let router = WalkRouter(graph: area.data.graph, edgeShade: shade, shadeEngine: engine(for: area),
                                coolSpots: area.data.coolSpots)
        routerBuildCount += 1
        area.router = (bucket, router)
        return router
    }

    private func markShadeUsed(_ bucket: Int64, in area: CachedArea) {
        area.shadeOrder.removeAll { $0 == bucket }
        area.shadeOrder.append(bucket)
        while area.shadeOrder.count > Self.maxShadeTimesPerArea {
            area.edgeShade.removeValue(forKey: area.shadeOrder.removeFirst())
        }
    }

    /// One straight route for origin/destination less than `samePlaceDistance` apart.
    private func samePlaceRoute(from origin: GeoCoordinate, to destination: GeoCoordinate, area: CachedArea,
                                request: RouteRequest, sun: SunPosition) -> WalkRoute {
        let distance = GeoMath.distance(origin, destination)
        let coords = distance > 0 ? [origin, destination] : [origin]
        let segments = engine(for: area).shadeRuns(along: coords, sun: sun)
        let shaded = segments.filter(\.isShaded).reduce(0) { $0 + $1.length }
        let sunny = segments.filter { !$0.isShaded }.reduce(0) { $0 + $1.length }
        let fraction = shaded + sunny > 0 ? shaded / (shaded + sunny) : ((segments.first?.isShaded ?? !sun.isUp) ? 1 : 0)
        let prefs = request.preferences
        let speed = prefs.walkingSpeed.isFinite && prefs.walkingSpeed > 0
            ? prefs.walkingSpeed : RoutingPreferences.default.walkingSpeed
        let stride = prefs.strideLength.isFinite && prefs.strideLength > 0
            ? prefs.strideLength : RoutingPreferences.default.strideLength
        let duration = distance / speed
        let nearby = Self.nearest(area.data.coolSpots, to: origin, within: Self.samePlaceCoolSpotRadius).map(\.spot.id)
        let key = String(format: "%.7f,%.7f>%.7f,%.7f", origin.latitude, origin.longitude,
                         destination.latitude, destination.longitude)
        return WalkRoute(id: "\(RouteProfile.shadiest.rawValue)-\(StableHash.hexDigest(key))",
                         profile: .shadiest,
                         profiles: RouteProfile.allCases,
                         coordinates: coords,
                         segments: segments,
                         distance: distance,
                         duration: duration,
                         stepCount: Int((distance / stride).rounded()),
                         shadeFraction: fraction,
                         shadedDistance: shaded,
                         sunnyDistance: sunny,
                         shadedDuration: duration * fraction,
                         sunnyDuration: duration * (1 - fraction),
                         crossingCount: 0,
                         stairsCount: 0,
                         underpassCount: 0,
                         maneuvers: [
                             Maneuver(kind: .depart, streetName: nil, distanceFromStart: 0, coordinate: origin),
                             Maneuver(kind: .arrive, streetName: nil, distanceFromStart: distance,
                                      coordinate: coords[coords.count - 1]),
                         ],
                         coolSpotIDs: nearby,
                         departure: request.departure,
                         sun: sun)
    }

    // MARK: - Elevation and weather

    /// Elevation profile per route (nil where it could not be fetched). All samples go in one request when they
    /// fit in `maxElevationCoordinates`, else one request per route. Failures are swallowed.
    static func elevationProfiles(for routes: [WalkRoute], provider: ElevationProviding?) async -> [ElevationProfile?] {
        var out = [ElevationProfile?](repeating: nil, count: routes.count)
        guard let provider, !routes.isEmpty else { return out }
        let maxSamples = max(10, min(60, maxElevationCoordinates / routes.count))
        let samples = routes.map { route -> [GeoCoordinate] in
            let points = ElevationProfileBuilder.samplePoints(along: route.coordinates, maxSamples: maxSamples)
            return points.count >= 2 ? points : []
        }
        let total = samples.reduce(0) { $0 + $1.count }
        guard total > 0 else { return out }

        var elevations = [[Double]?](repeating: nil, count: routes.count)
        if total <= maxElevationCoordinates {
            if let all = try? await provider.elevations(for: samples.flatMap { $0 }), all.count == total {
                var offset = 0
                for (i, s) in samples.enumerated() {
                    elevations[i] = Array(all[offset..<(offset + s.count)])
                    offset += s.count
                }
            }
        } else {
            for (i, s) in samples.enumerated() where !s.isEmpty {
                if let e = try? await provider.elevations(for: s), e.count == s.count { elevations[i] = e }
            }
        }
        for i in routes.indices {
            guard let e = elevations[i], !e.isEmpty else { continue }
            out[i] = ElevationProfileBuilder.profile(elevations: e, totalDistance: routes[i].distance)
        }
        return out
    }

    /// Forecast snapshot for `date` near `coordinate` (cached forecast when recent and close); nil on failure.
    private func weatherSnapshot(near coordinate: GeoCoordinate, at date: Date) async -> WeatherSnapshot? {
        guard let provider = weatherProvider else { return nil }
        let t = now()
        if let last = lastForecast,
           t >= last.fetchedAt, t.timeIntervalSince(last.fetchedAt) < Self.weatherReuseInterval,
           GeoMath.distance(last.coordinate, coordinate) <= Self.weatherReuseDistance {
            return last.forecast.snapshot(at: date)
        }
        guard let forecast = try? await provider.forecast(at: coordinate) else { return nil }
        lastForecast = (coordinate, t, forecast)
        return forecast.snapshot(at: date)
    }

    // MARK: - Helpers

    /// `box(origin, destination)` grown by `areaPadding`, at least `minimumAreaSide` on each side.
    static func planningBox(_ origin: GeoCoordinate, _ destination: GeoCoordinate) -> BoundingBox {
        BoundingBox(minLatitude: min(origin.latitude, destination.latitude),
                    minLongitude: min(origin.longitude, destination.longitude),
                    maxLatitude: max(origin.latitude, destination.latitude),
                    maxLongitude: max(origin.longitude, destination.longitude))
            .expanded(byMeters: areaPadding)
            .ensuringMinimumSize(meters: minimumAreaSide)
    }

    /// Departure rounded to `shadeTimeStep`, as a step count since 1970.
    static func shadeBucket(_ date: Date) -> Int64 {
        let steps = (date.timeIntervalSince1970 / shadeTimeStep).rounded()
        guard steps.isFinite else { return 0 }
        return Int64(max(-1e15, min(1e15, steps)))
    }

    /// Cool spots listed on a same-place route, metres (matches the router's 40 m).
    private static let samePlaceCoolSpotRadius = 40.0

    /// `spots` within `radius` metres of `c`, nearest first (ties by id).
    private static func nearest(_ spots: [CoolSpot], to c: GeoCoordinate,
                                within radius: Double) -> [(spot: CoolSpot, distance: Double)] {
        var out: [(spot: CoolSpot, distance: Double)] = []
        for spot in spots {
            let d = GeoMath.distance(c, spot.coordinate)
            if d <= radius { out.append((spot, d)) }
        }
        out.sort { a, b in a.distance != b.distance ? a.distance < b.distance : a.spot.id < b.spot.id }
        return out
    }

    private static func box(around c: GeoCoordinate, radius: Double) -> BoundingBox {
        BoundingBox(minLatitude: c.latitude, minLongitude: c.longitude, maxLatitude: c.latitude, maxLongitude: c.longitude)
            .expanded(byMeters: radius)
    }

    private static func isValid(_ b: BoundingBox) -> Bool {
        b.minLatitude.isFinite && b.maxLatitude.isFinite && b.minLongitude.isFinite && b.maxLongitude.isFinite &&
            b.minLatitude <= b.maxLatitude && b.minLongitude <= b.maxLongitude
    }

    private static func checkCancellation() throws {
        if Task.isCancelled { throw ShadeError.cancelled }
    }
}
