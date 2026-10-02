import Foundation
import XCTest
@testable import ShadeCore

final class RoutePlannerTests: XCTestCase {
    typealias F = PlannerFixtures

    /// Opposite corners of the default 4 × 4 grid (150 m from its centre on each axis).
    let origin = F.pt(-150, -150)
    let destination = F.pt(150, 150)

    func request(at date: Date = F.summerNoon, from o: GeoCoordinate? = nil, to d: GeoCoordinate? = nil,
                 preferences: RoutingPreferences = .default) -> RouteRequest {
        RouteRequest(origin: o ?? origin, destination: d ?? destination, departure: date, preferences: preferences)
    }

    func assertThrows<T>(_ expected: ShadeError, file: StaticString = #filePath, line: UInt = #line,
                         _ body: () async throws -> T) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ShadeError, expected, file: file, line: line)
        }
    }

    // MARK: - Planning

    func testPlanReturnsOrderedConsistentRoutes() async throws {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let plan = try await planner.plan(request())

        XCTAssertFalse(plan.routes.isEmpty)
        XCTAssertLessThanOrEqual(plan.routes.count, 3)
        XCTAssertEqual(plan.departure, F.summerNoon)
        XCTAssertTrue(plan.isSunUp)
        let expectedSun = SolarCalculator.position(at: F.summerNoon,
                                                   coordinate: GeoMath.interpolate(origin, destination, fraction: 0.5))
        XCTAssertEqual(plan.sun, expectedSun)
        XCTAssertNil(plan.weather)

        let allProfiles = plan.routes.flatMap(\.profiles)
        XCTAssertTrue(allProfiles.contains(.shadiest))
        XCTAssertTrue(allProfiles.contains(.fastest))
        XCTAssertEqual(allProfiles.count, Set(allProfiles).count, "each profile appears once")
        // Display order: shadiest → balanced → fastest.
        let order: [RouteProfile] = [.shadiest, .balanced, .fastest]
        let primaries = plan.routes.map { order.firstIndex(of: $0.profile) ?? 0 }
        XCTAssertEqual(primaries, primaries.sorted())

        let straight = GeoMath.distance(origin, destination)
        for route in plan.routes {
            assertConsistent(route)
            XCTAssertEqual(route.departure, F.summerNoon)
            XCTAssertEqual(route.sun, plan.sun)
            XCTAssertGreaterThanOrEqual(route.distance, straight - 0.01)
            XCTAssertLessThan(GeoMath.distance(route.coordinates[0], origin), 0.5)
            XCTAssertLessThan(GeoMath.distance(route.coordinates[route.coordinates.count - 1], destination), 0.5)
            XCTAssertNil(route.elevation)
        }
        let fastest = try XCTUnwrap(plan.routes.first { $0.profiles.contains(.fastest) })
        let shadiest = try XCTUnwrap(plan.routes.first { $0.profiles.contains(.shadiest) })
        XCTAssertGreaterThanOrEqual(shadiest.shadeFraction, fastest.shadeFraction - 1e-9)
        XCTAssertLessThanOrEqual(shadiest.distance, fastest.distance * 1.25 + 1e-6)
    }

    func testPlanCoolSpotsAreThoseInsideThePlanningBox() async throws {
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: F.gridArea()), elevationProvider: nil,
                                   weatherProvider: nil)
        let plan = try await planner.plan(request())
        XCTAssertEqual(Set(plan.coolSpots.map(\.id)), [1, 2], "the far library (3 km away) is outside the box")
    }

    func testPlanningBoxPadsAndEnforcesMinimumSize() {
        let box = RoutePlanner.planningBox(origin, destination)
        XCTAssertTrue(box.contains(origin) && box.contains(destination))
        // 300 m of padding on each side of a 300 m span → ≈ 900 m.
        XCTAssertEqual(box.widthMeters, 900, accuracy: 2)
        XCTAssertEqual(box.heightMeters, 900, accuracy: 2)
        let tiny = RoutePlanner.planningBox(origin, F.pt(-140, -150))
        XCTAssertGreaterThanOrEqual(tiny.widthMeters, 800 - 0.01)
        XCTAssertGreaterThanOrEqual(tiny.heightMeters, 800 - 0.01)
        XCTAssertTrue(tiny.contains(origin))
    }

    func testRequestedAreaIsThePlanningBox() async throws {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        _ = try await planner.plan(request())
        XCTAssertEqual(area.requests.all, [RoutePlanner.planningBox(origin, destination)])
    }

    // MARK: - Caching

    func testDepartureChangeReusesAreaAndEngine() async throws {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let first = try await planner.plan(request(at: F.summerNoon))
        let later = try await planner.plan(request(at: F.summerNoon.addingTimeInterval(3 * 3600)))

        XCTAssertEqual(area.callCount, 1, "area data is fetched once")
        let engines = await planner.engineBuildCount
        let shades = await planner.edgeShadeComputationCount
        XCTAssertEqual(engines, 1, "one shade engine per area")
        XCTAssertEqual(shades, 2, "edge shade per departure bucket")
        XCTAssertNotEqual(first.sun, later.sun)
        XCTAssertEqual(later.departure, F.summerNoon.addingTimeInterval(3 * 3600))
    }

    func testDeparturesInTheSameFiveMinuteBucketShareEdgeShade() async throws {
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: F.gridArea()), elevationProvider: nil,
                                   weatherProvider: nil)
        let base = F.summerNoon
        _ = try await planner.plan(request(at: base))
        _ = try await planner.plan(request(at: base.addingTimeInterval(60)))
        _ = try await planner.plan(request(at: base.addingTimeInterval(-120)))
        var shades = await planner.edgeShadeComputationCount
        var routers = await planner.routerBuildCount
        XCTAssertEqual(shades, 1)
        XCTAssertEqual(routers, 1, "the router for the current bucket is reused")

        _ = try await planner.plan(request(at: base.addingTimeInterval(3600)))
        _ = try await planner.plan(request(at: base))
        shades = await planner.edgeShadeComputationCount
        routers = await planner.routerBuildCount
        XCTAssertEqual(shades, 2, "returning to an earlier bucket reuses its edge shade")
        XCTAssertEqual(routers, 3, "the router is rebuilt on the cached edge shade")
    }

    func testShadeBucketRoundsToFiveMinutes() {
        let t = Date(timeIntervalSince1970: 300 * 3_333_333)  // on a bucket boundary
        XCTAssertEqual(RoutePlanner.shadeBucket(t), RoutePlanner.shadeBucket(t.addingTimeInterval(149)))
        XCTAssertNotEqual(RoutePlanner.shadeBucket(t), RoutePlanner.shadeBucket(t.addingTimeInterval(151)))
        XCTAssertEqual(RoutePlanner.shadeBucket(Date(timeIntervalSince1970: .nan)), 0)
    }

    func testRequestInsideCachedAreaDoesNotRefetch() async throws {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        _ = try await planner.plan(request())
        // A shorter trip inside the first planning box.
        _ = try await planner.plan(request(from: F.pt(-50, -150), to: F.pt(50, 50)))
        XCTAssertEqual(area.callCount, 1)
    }

    func testAtMostThreeAreasAreCachedLeastRecentlyUsedFirst() async throws {
        // Each fetch returns a grid around the requested box, so planning works anywhere.
        let area = PlannerAreaProvider { bbox in F.gridArea(origin: bbox.center, bbox: bbox) }
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let centers = (0..<4).map { F.pt(Double($0) * 3000, 0) }
        func plan(_ i: Int) async throws {
            let c = centers[i]
            let o = F.pt(-150, -150, origin: c), d = F.pt(150, 150, origin: c)
            _ = try await planner.plan(RouteRequest(origin: o, destination: d, departure: F.summerNoon))
        }
        try await plan(0)
        try await plan(1)
        try await plan(2)
        try await plan(0)      // cache hit; area 1 becomes the least recently used
        XCTAssertEqual(area.callCount, 3)
        try await plan(3)      // evicts area 1
        var boxes = await planner.cachedAreaBoxes
        XCTAssertEqual(boxes.count, 3)
        XCTAssertEqual(area.callCount, 4)
        try await plan(0)
        try await plan(2)
        XCTAssertEqual(area.callCount, 4, "areas 0 and 2 survived")
        try await plan(1)
        XCTAssertEqual(area.callCount, 5, "area 1 was evicted")
        boxes = await planner.cachedAreaBoxes
        XCTAssertEqual(boxes.count, 3)
    }

    func testLargerAreaReplacesTheAreasItCovers() async throws {
        let area = PlannerAreaProvider { bbox in F.gridArea(origin: bbox.center, bbox: bbox) }
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        _ = try await planner.coolSpots(near: F.center, radius: 100)
        _ = try await planner.shadeOverlay(in: RoutePlanner.planningBox(F.pt(-1000, -1000), F.pt(1000, 1000)),
                                           at: F.summerNoon)
        let boxes = await planner.cachedAreaBoxes
        XCTAssertEqual(boxes.count, 1, "the small area is covered by the large one")
        XCTAssertEqual(area.callCount, 2)
    }

    // MARK: - Validation and errors

    func testTooFarThrowsBeforeFetching() async {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let far = F.pt(6000, 0)
        let distance = GeoMath.distance(F.center, far)
        await assertThrows(.tooFar(distance: distance, limit: RoutePlanner.maxStraightLineDistance)) {
            try await planner.plan(request(from: F.center, to: far))
        }
        XCTAssertEqual(area.callCount, 0)
    }

    func testJustUnderTheLimitIsAccepted() async throws {
        // 4.9 km straight line: allowed (fails later only because the fake grid is small).
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        await assertThrows(.destinationTooFarFromNetwork) {
            try await planner.plan(request(from: F.center, to: F.pt(4900, 0)))
        }
        XCTAssertEqual(area.callCount, 1)
    }

    func testInvalidCoordinatesThrowWithoutFetching() async {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let bad = GeoCoordinate(latitude: .nan, longitude: 0)
        await assertThrows(.originTooFarFromNetwork) { try await planner.plan(request(from: bad)) }
        await assertThrows(.destinationTooFarFromNetwork) {
            try await planner.plan(request(to: GeoCoordinate(latitude: 95, longitude: 0)))
        }
        XCTAssertEqual(area.callCount, 0)
    }

    func testEmptyGraphThrowsNoWalkableNetwork() async {
        let area = PlannerAreaProvider { bbox in F.emptyArea(bbox: bbox) }
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        await assertThrows(.noWalkableNetwork) { try await planner.plan(request()) }
        let engines = await planner.engineBuildCount
        XCTAssertEqual(engines, 0, "no shade work for an empty network")
    }

    func testRouterErrorsPassThrough() async {
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: F.gridArea()), elevationProvider: nil,
                                   weatherProvider: nil)
        await assertThrows(.originTooFarFromNetwork) {
            try await planner.plan(request(from: F.pt(-700, 0), to: F.pt(0, 0)))
        }
    }

    func testAreaFetchErrorPropagatesAndIsNotCached() async throws {
        let attempts = PlannerCallLog<Int>()
        let grid = F.gridArea()
        let area = PlannerAreaProvider { _ in
            attempts.append(1)
            if attempts.count == 1 { throw ShadeError.networkUnavailable }
            return grid
        }
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        await assertThrows(.networkUnavailable) { try await planner.plan(request()) }
        let plan = try await planner.plan(request())
        XCTAssertFalse(plan.routes.isEmpty)
        XCTAssertEqual(area.callCount, 2)
    }

    func testProviderCancellationErrorMapsToShadeErrorCancelled() async {
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider { _ in throw CancellationError() },
                                   elevationProvider: nil, weatherProvider: nil)
        await assertThrows(.cancelled) { try await planner.plan(request()) }
    }

    // MARK: - Same place

    func testSamePlaceGivesTrivialPlan() async throws {
        let area = PlannerAreaProvider(area: F.gridArea())
        let weather = PlannerWeatherProvider.hourly(from: F.summerNoon.addingTimeInterval(-3600))
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: weather)
        let o = F.pt(-150, -140), d = F.pt(-148, -140)
        let plan = try await planner.plan(request(from: o, to: d))

        XCTAssertEqual(plan.routes.count, 1)
        let route = try XCTUnwrap(plan.routes.first)
        assertConsistent(route)
        XCTAssertEqual(route.profiles, RouteProfile.allCases)
        XCTAssertEqual(route.distance, GeoMath.distance(o, d), accuracy: 1e-9)
        XCTAssertEqual(route.maneuvers.map(\.kind), [.depart, .arrive])
        XCTAssertEqual(route.coolSpotIDs, [1], "the fountain is within 40 m")
        XCTAssertEqual(route.crossingCount + route.stairsCount + route.underpassCount, 0)
        XCTAssertNotNil(plan.weather)
        XCTAssertFalse(plan.coolSpots.isEmpty)

        let again = try await planner.plan(request(from: o, to: d))
        XCTAssertEqual(again.routes.first?.id, route.id, "ids are stable")
    }

    func testSamePlaceDoesNotNeedAWalkNetwork() async throws {
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider { F.emptyArea(bbox: $0) }, elevationProvider: nil,
                                   weatherProvider: nil)
        let plan = try await planner.plan(request(from: F.center, to: F.center))
        XCTAssertEqual(plan.routes.count, 1)
        XCTAssertEqual(plan.routes.first?.distance, 0)
        XCTAssertEqual(plan.routes.first?.coordinates, [F.center])
        XCTAssertEqual(plan.routes.first?.shadeFraction, 0, "open sky at noon")
    }

    // MARK: - Elevation

    func testElevationFetchedInOneCallAndAttachedToEveryRoute() async throws {
        let elevation = PlannerElevationProvider.northSlope(baseLatitude: origin.latitude)
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: F.gridArea()), elevationProvider: elevation,
                                   weatherProvider: nil)
        let plan = try await planner.plan(request())

        XCTAssertEqual(elevation.requests.count, 1)
        let sent = try XCTUnwrap(elevation.requests.all.first)
        XCTAssertLessThanOrEqual(sent.count, RoutePlanner.maxElevationCoordinates)
        let perRoute = max(10, min(60, 100 / plan.routes.count))
        var expected = 0
        for route in plan.routes {
            let profile = try XCTUnwrap(route.elevation)
            let samples = ElevationProfileBuilder.samplePoints(along: route.coordinates, maxSamples: perRoute)
            expected += samples.count
            XCTAssertEqual(profile.elevations.count, samples.count)
            XCTAssertEqual(profile.bins.count, min(12, samples.count - 1))
            // 300 m north at 5 % → about 15 m of climb.
            XCTAssertEqual(profile.ascent - profile.descent, 15, accuracy: 1.5)
            XCTAssertEqual(profile.sampleSpacing * Double(samples.count - 1), route.distance, accuracy: 1e-6)
        }
        XCTAssertEqual(sent.count, expected)
    }

    func testElevationFailureIsNonFatal() async throws {
        let elevation = PlannerElevationProvider { _ in throw ShadeError.networkUnavailable }
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: F.gridArea()), elevationProvider: elevation,
                                   weatherProvider: nil)
        let plan = try await planner.plan(request())
        XCTAssertFalse(plan.routes.isEmpty)
        XCTAssertTrue(plan.routes.allSatisfy { $0.elevation == nil })
        XCTAssertEqual(elevation.requests.count, 1)
    }

    func testElevationCountMismatchIsIgnored() async throws {
        let elevation = PlannerElevationProvider { coords in Array(repeating: 10, count: max(0, coords.count - 1)) }
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: F.gridArea()), elevationProvider: elevation,
                                   weatherProvider: nil)
        let plan = try await planner.plan(request())
        XCTAssertTrue(plan.routes.allSatisfy { $0.elevation == nil })
    }

    func testElevationProfilesSplitRequestsWhenTooManySamples() async {
        // 11 long routes × 10 samples = 110 > 100 → one request per route.
        let line = [F.pt(0, 0), F.pt(0, 500)]
        let route = WalkRoute(id: "r", profile: .fastest, profiles: [.fastest], coordinates: line, segments: [],
                              distance: GeoMath.length(of: line), duration: 400, stepCount: 0, shadeFraction: 0,
                              shadedDistance: 0, sunnyDistance: 0, shadedDuration: 0, sunnyDuration: 0, crossingCount: 0,
                              stairsCount: 0, underpassCount: 0, maneuvers: [], departure: F.summerNoon,
                              sun: SunPosition(azimuth: 180, elevation: 60))
        let elevation = PlannerElevationProvider { coords in coords.map { _ in 5 } }
        let profiles = await RoutePlanner.elevationProfiles(for: Array(repeating: route, count: 11), provider: elevation)
        XCTAssertEqual(profiles.count, 11)
        XCTAssertTrue(profiles.allSatisfy { $0?.elevations.count == 10 })
        XCTAssertEqual(elevation.requests.count, 11)
        XCTAssertTrue(elevation.requests.all.allSatisfy { $0.count == 10 })

        let none = await RoutePlanner.elevationProfiles(for: [route], provider: nil)
        XCTAssertEqual(none.count, 1)
        XCTAssertNil(none[0])
        let empty = await RoutePlanner.elevationProfiles(for: [], provider: elevation)
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - Weather

    func testWeatherSnapshotIsForTheDeparture() async throws {
        let start = F.summerNoon.addingTimeInterval(-5 * 3600)
        let weather = PlannerWeatherProvider.hourly(from: start)
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: F.gridArea()), elevationProvider: nil,
                                   weatherProvider: weather)
        let plan = try await planner.plan(request(at: F.summerNoon.addingTimeInterval(20 * 60)))
        XCTAssertEqual(plan.weather?.time, F.summerNoon)
        XCTAssertEqual(plan.weather?.temperature, 25)
        let asked = try XCTUnwrap(weather.requests.all.first)
        XCTAssertLessThan(GeoMath.distance(asked, GeoMath.interpolate(origin, destination, fraction: 0.5)), 0.01)
    }

    func testWeatherFailureIsNonFatal() async throws {
        let weather = PlannerWeatherProvider { _ in throw ShadeError.badResponse(status: 500) }
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: F.gridArea()), elevationProvider: nil,
                                   weatherProvider: weather)
        let plan = try await planner.plan(request())
        XCTAssertNil(plan.weather)
        XCTAssertFalse(plan.routes.isEmpty)
    }

    func testForecastIsReusedBrieflyNearby() async throws {
        let clock = PlannerClock(F.summerNoon)
        let weather = PlannerWeatherProvider.hourly(from: F.summerNoon.addingTimeInterval(-3600))
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: F.gridArea()), elevationProvider: nil,
                                   weatherProvider: weather, now: { clock.now })
        _ = try await planner.plan(request())
        clock.advance(10 * 60)
        let second = try await planner.plan(request(at: F.summerNoon.addingTimeInterval(3600)))
        XCTAssertEqual(weather.requests.count, 1)
        XCTAssertEqual(second.weather?.time, F.summerNoon.addingTimeInterval(3600), "snapshot follows the departure")
        clock.advance(6 * 60)
        _ = try await planner.plan(request())
        XCTAssertEqual(weather.requests.count, 2, "stale after 15 minutes")
    }

    func testElevationAndWeatherRunConcurrently() async throws {
        let elevationStarted = PlannerCallLog<Int>(), weatherStarted = PlannerCallLog<Int>()
        let sawWeather = PlannerCallLog<Bool>(), sawElevation = PlannerCallLog<Bool>()
        let elevation = PlannerElevationProvider { coords in
            elevationStarted.append(1)
            sawWeather.append(await plannerEventually { weatherStarted.count > 0 })
            return coords.map { _ in 1 }
        }
        let weather = PlannerWeatherProvider { _ in
            weatherStarted.append(1)
            sawElevation.append(await plannerEventually { elevationStarted.count > 0 })
            return F.forecast(from: F.summerNoon)
        }
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: F.gridArea()), elevationProvider: elevation,
                                   weatherProvider: weather)
        let plan = try await planner.plan(request())
        XCTAssertEqual(sawWeather.all, [true])
        XCTAssertEqual(sawElevation.all, [true])
        XCTAssertNotNil(plan.weather)
        XCTAssertTrue(plan.routes.allSatisfy { $0.elevation != nil })
    }

    // MARK: - Cancellation and sharing

    func testCancelledCallerStopsWaitingButFetchIsCached() async throws {
        let gate = PlannerGate()
        let grid = F.gridArea()
        let area = PlannerAreaProvider { _ in
            await gate.wait()
            return grid
        }
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let req = request()
        let task = Task { try await planner.plan(req) }
        let started = await plannerEventually { area.callCount == 1 }
        XCTAssertTrue(started)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? ShadeError, .cancelled)
        }

        // The fetch is still blocked; release it and plan again without refetching.
        await gate.open()
        let plan = try await planner.plan(req)
        XCTAssertFalse(plan.routes.isEmpty)
        XCTAssertEqual(area.callCount, 1)
    }

    func testAlreadyCancelledTaskThrowsBeforeFetching() async {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let req = request()
        let task = Task { () async throws -> RoutePlan in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await planner.plan(req)
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? ShadeError, .cancelled)
        }
        XCTAssertEqual(area.callCount, 0)
    }

    func testCancellationDuringElevationThrowsCancelled() async throws {
        // The task is cancelled after routing, while elevation is being fetched.
        let gate = PlannerGate()
        let grid = F.gridArea()
        let area = PlannerAreaProvider { _ in
            await gate.wait()
            return grid
        }
        let handle = PlannerCallLog<Task<RoutePlan, Error>>()
        let elevation = PlannerElevationProvider { coords in
            handle.all.first?.cancel()
            return coords.map { _ in 0 }
        }
        let planner = RoutePlanner(areaProvider: area, elevationProvider: elevation, weatherProvider: nil)
        let req = request()
        let task = Task { try await planner.plan(req) }
        handle.append(task)
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? ShadeError, .cancelled)
        }
        XCTAssertEqual(elevation.requests.count, 1)
        // The area stays cached for the next request.
        let plan = try await planner.plan(req)
        XCTAssertFalse(plan.routes.isEmpty)
        XCTAssertEqual(area.callCount, 1)
    }

    func testConcurrentRequestsShareOneFetch() async throws {
        let gate = PlannerGate()
        let grid = F.gridArea()
        let area = PlannerAreaProvider { _ in
            await gate.wait()
            return grid
        }
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let a = request(at: F.summerNoon)
        let b = request(at: F.summerNoon.addingTimeInterval(1800), from: F.pt(-50, -50), to: F.pt(50, 50))
        let first = Task { try await planner.plan(a) }
        _ = await plannerEventually { area.callCount == 1 }
        let second = Task { try await planner.plan(b) }
        let joined = await plannerEventually { await planner.pendingWaiterCount == 2 }
        XCTAssertTrue(joined, "the second request waits on the first fetch")
        await gate.open()
        let planA = try await first.value
        let planB = try await second.value
        XCTAssertFalse(planA.routes.isEmpty)
        XCTAssertFalse(planB.routes.isEmpty)
        XCTAssertEqual(area.callCount, 1)
    }

    func testFailedSharedFetchFailsEveryWaiter() async {
        let gate = PlannerGate()
        let area = PlannerAreaProvider { _ in
            await gate.wait()
            throw ShadeError.badResponse(status: 504)
        }
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let req = request()
        let tasks = (0..<3).map { _ in Task { try await planner.plan(req) } }
        let joined = await plannerEventually { await planner.pendingWaiterCount == 3 }
        XCTAssertTrue(joined)
        await gate.open()
        for task in tasks {
            do {
                _ = try await task.value
                XCTFail("expected failure")
            } catch {
                XCTAssertEqual(error as? ShadeError, .badResponse(status: 504))
            }
        }
        XCTAssertEqual(area.callCount, 1)
    }

    // MARK: - Shade overlay

    func testOverlayReusesPlannedArea() async throws {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        _ = try await planner.plan(request())
        let visible = BoundingBox(coordinates: [F.pt(-200, -200), F.pt(200, 200)])!
        let overlay = try await planner.shadeOverlay(in: visible, at: F.summerNoon)
        XCTAssertEqual(area.callCount, 1)
        XCTAssertFalse(overlay.polygons.isEmpty)
        XCTAssertEqual(overlay.date, F.summerNoon)
        XCTAssertEqual(overlay.sun, SolarCalculator.position(at: F.summerNoon, coordinate: visible.center))
        XCTAssertTrue(overlay.polygons.allSatisfy { $0.count >= 3 })
        let engines = await planner.engineBuildCount
        XCTAssertEqual(engines, 1, "plan and overlay share the engine")
    }

    func testOverlayFetchesAPaddedAreaWhenNotCached() async throws {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let visible = BoundingBox(coordinates: [F.pt(-100, -100), F.pt(100, 100)])!
        let overlay = try await planner.shadeOverlay(in: visible, at: F.summerNoon)
        XCTAssertFalse(overlay.polygons.isEmpty)
        let fetched = try XCTUnwrap(area.requests.all.first)
        XCTAssertTrue(fetched.contains(visible.expanded(byMeters: RoutePlanner.overlayPadding - 1)))
        XCTAssertGreaterThanOrEqual(fetched.widthMeters, RoutePlanner.minimumAreaSide - 0.01)
        // A smaller box inside it is served from the cache.
        _ = try await planner.shadeOverlay(in: BoundingBox(coordinates: [F.pt(-50, -50), F.pt(50, 50)])!,
                                           at: F.summerNoon.addingTimeInterval(3600))
        XCTAssertEqual(area.callCount, 1)
    }

    func testOverlayIsEmptyWithoutFetchingWhenTooLargeOrSunDownOrInvalid() async throws {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let large = BoundingBox(coordinates: [F.pt(-1600, -100), F.pt(1600, 100)])!
        XCTAssertGreaterThan(large.widthMeters, RoutePlanner.maxOverlaySide)
        let tooLarge = try await planner.shadeOverlay(in: large, at: F.summerNoon)
        XCTAssertTrue(tooLarge.polygons.isEmpty)
        XCTAssertTrue(tooLarge.sun.isUp)

        let small = BoundingBox(coordinates: [F.pt(-100, -100), F.pt(100, 100)])!
        let night = try await planner.shadeOverlay(in: small, at: F.summerMidnight)
        XCTAssertTrue(night.polygons.isEmpty)
        XCTAssertFalse(night.sun.isUp)

        let inverted = BoundingBox(minLatitude: small.maxLatitude, minLongitude: small.minLongitude,
                                   maxLatitude: small.minLatitude, maxLongitude: small.maxLongitude)
        let invalid = try await planner.shadeOverlay(in: inverted, at: F.summerNoon)
        XCTAssertTrue(invalid.polygons.isEmpty)
        XCTAssertEqual(area.callCount, 0)
    }

    // MARK: - Cool spots

    func testCoolSpotsFromCachedAreaAreFilteredAndSorted() async throws {
        let coolOnly = PlannerCoolSpotAreaProvider(area: F.gridArea(), spots: [])
        let planner = RoutePlanner(areaProvider: coolOnly, elevationProvider: nil, weatherProvider: nil)
        _ = try await planner.plan(request())
        let spots = try await planner.coolSpots(near: F.pt(-150, -150), radius: 250)
        XCTAssertEqual(spots.map(\.id), [1, 2], "nearest first; the far library is excluded")
        XCTAssertEqual(coolOnly.coolSpotRequests.count, 0, "served from the cached area")
        XCTAssertEqual(coolOnly.areaRequests.count, 1)
        let none = try await planner.coolSpots(near: F.pt(-150, -150), radius: 5)
        XCTAssertTrue(none.isEmpty)
    }

    func testCoolSpotsUseTheProviderWhenNoAreaCoversTheCircle() async throws {
        let near = CoolSpot(id: 7, kind: .shelter, name: nil, coordinate: F.pt(0, 30))
        let nearer = CoolSpot(id: 8, kind: .park, name: nil, coordinate: F.pt(0, 10))
        let outside = CoolSpot(id: 9, kind: .park, name: nil, coordinate: F.pt(0, 900))
        let provider = PlannerCoolSpotAreaProvider(area: F.gridArea(), spots: [near, outside, nearer])
        let planner = RoutePlanner(areaProvider: provider, elevationProvider: nil, weatherProvider: nil)
        let spots = try await planner.coolSpots(near: F.center, radius: 500)
        XCTAssertEqual(spots.map(\.id), [8, 7])
        XCTAssertEqual(provider.coolSpotRequests.all, [500])
        XCTAssertEqual(provider.areaRequests.count, 0)
    }

    func testCoolSpotsFallBackToAnAreaFetch() async throws {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let spots = try await planner.coolSpots(near: F.center, radius: 300)
        XCTAssertEqual(spots.map(\.id), [2, 1])
        XCTAssertEqual(area.callCount, 1)
        // Huge radii are capped for the area fetch.
        let capped = try await planner.coolSpots(near: F.pt(10_000, 0), radius: 50_000)
        XCTAssertTrue(capped.allSatisfy { GeoMath.distance($0.coordinate, F.pt(10_000, 0)) <= RoutePlanner.maxOverlaySide / 2 })
        let fetched = try XCTUnwrap(area.requests.all.last)
        XCTAssertLessThanOrEqual(fetched.widthMeters, RoutePlanner.maxOverlaySide + 1)
    }

    func testCoolSpotsWithInvalidInputAreEmpty() async throws {
        let area = PlannerAreaProvider(area: F.gridArea())
        let planner = RoutePlanner(areaProvider: area, elevationProvider: nil, weatherProvider: nil)
        let zero = try await planner.coolSpots(near: F.center, radius: 0)
        let nan = try await planner.coolSpots(near: F.center, radius: .nan)
        let bad = try await planner.coolSpots(near: GeoCoordinate(latitude: .infinity, longitude: 0), radius: 100)
        XCTAssertTrue(zero.isEmpty && nan.isEmpty && bad.isEmpty)
        XCTAssertEqual(area.callCount, 0)
    }
}
