import Foundation
import XCTest
@testable import ShadeCore

/// Overpass JSON → `OSMAreaParser` → `RoutePlanner` (real shade engine and router) with fake providers.
final class EndToEndTests: XCTestCase {
    typealias F = PlannerFixtures

    // MARK: - Synthetic block

    /// South-west and north-east corners of the synthetic street grid.
    let blockOrigin = GeoCoordinate(latitude: 37.5600, longitude: 126.9900)
    let blockDestination = GeoCoordinate(latitude: 37.5618, longitude: 126.9922)

    func syntheticArea() throws -> AreaData {
        try OSMAreaParser.parse(OSMTestFixtures.data("synthetic_block"), bbox: OSMTestFixtures.syntheticBBox,
                                fetchedAt: F.summerNoon)
    }

    func testSyntheticBlockAtSummerNoon() async throws {
        let area = try syntheticArea()
        XCTAssertFalse(area.graph.isEmpty)
        let provider = PlannerAreaProvider(area: area)
        let elevation = PlannerElevationProvider.northSlope(baseLatitude: blockOrigin.latitude)
        let weather = PlannerWeatherProvider.hourly(from: F.summerNoon.addingTimeInterval(-6 * 3600))
        let planner = RoutePlanner(areaProvider: provider, elevationProvider: elevation, weatherProvider: weather)
        let prefs = RoutingPreferences.default
        let plan = try await planner.plan(RouteRequest(origin: blockOrigin, destination: blockDestination,
                                                       departure: F.summerNoon, preferences: prefs))

        XCTAssertTrue(plan.isSunUp)
        XCTAssertGreaterThan(plan.sun.elevation, 60, "July noon in Seoul")
        XCTAssertGreaterThanOrEqual(plan.routes.count, 1)
        XCTAssertEqual(plan.weather?.time, F.summerNoon)
        XCTAssertFalse(plan.coolSpots.isEmpty)

        let fastest = try XCTUnwrap(plan.routes.first { $0.profiles.contains(.fastest) })
        let shadiest = try XCTUnwrap(plan.routes.first { $0.profiles.contains(.shadiest) })
        XCTAssertGreaterThanOrEqual(shadiest.shadeFraction, fastest.shadeFraction - 1e-9)
        XCTAssertLessThanOrEqual(shadiest.sunnyDistance, fastest.sunnyDistance + 0.5)
        XCTAssertLessThanOrEqual(shadiest.distance, fastest.distance * (1 + prefs.maxDetourFraction) + 1e-6)

        let straight = GeoMath.distance(blockOrigin, blockDestination)
        for route in plan.routes {
            assertConsistent(route, preferences: prefs)
            XCTAssertGreaterThanOrEqual(route.distance, straight - 0.01)
            XCTAssertLessThan(route.distance, straight * 2)
            XCTAssertGreaterThanOrEqual(route.duration, route.distance / prefs.walkingSpeed + 10 * Double(route.crossingCount) - 1e-6)
            if route.stairsCount == 0 {
                XCTAssertEqual(route.duration, route.distance / prefs.walkingSpeed + 10 * Double(route.crossingCount),
                               accuracy: 1e-6)
            }
            XCTAssertLessThan(GeoMath.distance(route.coordinates[0], blockOrigin), 1)
            XCTAssertLessThan(GeoMath.distance(route.coordinates[route.coordinates.count - 1], blockDestination), 1)
            let profile = try XCTUnwrap(route.elevation, "elevation for \(route.id)")
            XCTAssertFalse(profile.bins.isEmpty)
            XCTAssertGreaterThan(profile.ascent, 5, "the route climbs northwards")
            XCTAssertEqual(route.sun, plan.sun)
            let label = route.profiles.map(\.rawValue).joined(separator: "+")
            print("[E2E synthetic] \(label): " + String(format: "%.0f m, %.0f s, %d steps, shade %.0f %%, crossings %d",
                                                       route.distance, route.duration, route.stepCount,
                                                       route.shadeFraction * 100, route.crossingCount))
        }
        XCTAssertEqual(elevation.requests.count, 1)
        XCTAssertLessThanOrEqual(elevation.requests.all[0].count, 100)

        // The overlay over the fixture comes from the same cached area.
        let overlay = try await planner.shadeOverlay(in: OSMTestFixtures.syntheticBBox, at: F.summerNoon)
        XCTAssertFalse(overlay.polygons.isEmpty)
        XCTAssertEqual(provider.callCount, 1)

        // Cool spots come from the cached area too.
        let spots = try await planner.coolSpots(near: blockOrigin, radius: 300)
        XCTAssertFalse(spots.isEmpty)
        XCTAssertEqual(provider.callCount, 1)
    }

    func testSyntheticBlockAtNightGivesOneFullyShadedRoute() async throws {
        let provider = PlannerAreaProvider(area: try syntheticArea())
        let planner = RoutePlanner(areaProvider: provider, elevationProvider: nil, weatherProvider: nil)
        let plan = try await planner.plan(RouteRequest(origin: blockOrigin, destination: blockDestination,
                                                       departure: F.summerMidnight))
        XCTAssertFalse(plan.isSunUp)
        XCTAssertEqual(plan.routes.count, 1, "every profile collapses to the fastest route")
        let route = try XCTUnwrap(plan.routes.first)
        XCTAssertEqual(Set(route.profiles), Set(RouteProfile.allCases))
        XCTAssertEqual(route.shadeFraction, 1)
        XCTAssertEqual(route.sunnyDistance, 0)
        XCTAssertTrue(route.segments.allSatisfy(\.isShaded))
        assertConsistent(route)

        // Same area later that day: no refetch, a new edge-shade bucket.
        _ = try await planner.plan(RouteRequest(origin: blockOrigin, destination: blockDestination,
                                                departure: F.summerNoon))
        XCTAssertEqual(provider.callCount, 1)
        let overlay = try await planner.shadeOverlay(in: OSMTestFixtures.syntheticBBox, at: F.summerMidnight)
        XCTAssertTrue(overlay.polygons.isEmpty)
    }

    func testShadiestRouteIsShadierAcrossTheDay() async throws {
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: try syntheticArea()), elevationProvider: nil,
                                   weatherProvider: nil)
        for hour in [8.0, 10, 14, 17] {
            let departure = F.summerNoon.addingTimeInterval((hour - 12) * 3600)
            let plan = try await planner.plan(RouteRequest(origin: blockOrigin, destination: blockDestination,
                                                           departure: departure))
            let fastest = try XCTUnwrap(plan.routes.first { $0.profiles.contains(.fastest) })
            let shadiest = try XCTUnwrap(plan.routes.first { $0.profiles.contains(.shadiest) })
            XCTAssertGreaterThanOrEqual(shadiest.shadeFraction, fastest.shadeFraction - 1e-9, "at \(hour) h")
            plan.routes.forEach { assertConsistent($0) }
        }
    }

    // MARK: - Real data (Gwanghwamun, Seoul)

    func testRealSeoulDataEndToEnd() async throws {
        let clock = ContinuousClock()
        let data = try OSMTestFixtures.data("seoul_gwanghwamun")
        var area: AreaData?
        let parseTime = try clock.measure {
            area = try OSMAreaParser.parse(data, bbox: OSMTestFixtures.seoulBBox, fetchedAt: F.summerNoon)
        }
        let parsed = try XCTUnwrap(area)

        var engine: ShadeEngine?
        let engineTime = clock.measure { engine = ShadeEngine(area: parsed) }
        let shadeEngine = try XCTUnwrap(engine)

        let origin = GeoCoordinate(latitude: 37.5700, longitude: 126.9755)
        let destination = GeoCoordinate(latitude: 37.5725, longitude: 126.9790)
        let straight = GeoMath.distance(origin, destination)
        XCTAssertEqual(straight, 400, accuracy: 50)
        let sun = SolarCalculator.position(at: F.summerNoon, coordinate: GeoMath.interpolate(origin, destination, fraction: 0.5))
        // The planner shades edges with the sun at the area centre at the 5-minute bucket (noon is on one).
        let edgeSun = SolarCalculator.position(at: F.summerNoon, coordinate: parsed.bbox.center)

        var edgeShade: [Double] = []
        let edgeShadeTime = clock.measure { edgeShade = shadeEngine.edgeShadeFractions(for: parsed.graph, sun: edgeSun) }
        XCTAssertEqual(edgeShade.count, parsed.graph.edges.count)
        XCTAssertTrue(edgeShade.allSatisfy { (0...1).contains($0) })

        var routes: [WalkRoute] = []
        let routingTime = try clock.measure {
            let router = WalkRouter(graph: parsed.graph, edgeShade: edgeShade, shadeEngine: shadeEngine,
                                    coolSpots: parsed.coolSpots)
            routes = try router.alternatives(from: origin, to: destination, preferences: .default, sun: sun,
                                             departure: F.summerNoon)
        }
        XCTAssertFalse(routes.isEmpty)

        // The same request through the planner (fresh caches).
        let planner = RoutePlanner(areaProvider: PlannerAreaProvider(area: parsed),
                                   elevationProvider: PlannerElevationProvider { $0.map { _ in 40 } },
                                   weatherProvider: nil)
        let request = RouteRequest(origin: origin, destination: destination, departure: F.summerNoon)
        let start = clock.now
        let plan = try await planner.plan(request)
        let planTime = clock.now - start
        let start2 = clock.now
        let replan = try await planner.plan(RouteRequest(origin: origin, destination: destination,
                                                         departure: F.summerNoon.addingTimeInterval(2 * 3600)))
        let replanTime = clock.now - start2

        XCTAssertEqual(plan.routes.map(\.id), routes.map(\.id), "planner and direct routing agree")
        XCTAssertFalse(replan.routes.isEmpty)
        for route in plan.routes + replan.routes {
            assertConsistent(route)
            XCTAssertGreaterThanOrEqual(route.distance, straight * 1.0 - 0.01)
            XCTAssertLessThanOrEqual(route.distance, straight * 2.0)
            XCTAssertTrue((0...1).contains(route.shadeFraction))
            XCTAssertNotNil(route.elevation)
        }
        let fastest = try XCTUnwrap(plan.routes.first { $0.profiles.contains(.fastest) })
        let shadiest = try XCTUnwrap(plan.routes.first { $0.profiles.contains(.shadiest) })
        XCTAssertGreaterThanOrEqual(shadiest.shadeFraction, fastest.shadeFraction - 1e-9)

        let overlay = try await planner.shadeOverlay(in: OSMTestFixtures.seoulBBox, at: F.summerNoon)
        XCTAssertFalse(overlay.polygons.isEmpty)

        // Low sun (08:00, 17:30): long shadows, so shade-seeking can pay off.
        var lowSun: [(hour: Double, plan: RoutePlan)] = []
        for hour in [8.0, 17.5] {
            let low = try await planner.plan(RouteRequest(origin: origin, destination: destination,
                                                          departure: F.summerNoon.addingTimeInterval((hour - 12) * 3600)))
            let lowFastest = try XCTUnwrap(low.routes.first { $0.profiles.contains(.fastest) })
            let lowShadiest = try XCTUnwrap(low.routes.first { $0.profiles.contains(.shadiest) })
            XCTAssertGreaterThanOrEqual(lowShadiest.shadeFraction, lowFastest.shadeFraction - 1e-9)
            XCTAssertLessThanOrEqual(lowShadiest.distance, lowFastest.distance * 1.25 + 1e-6)
            low.routes.forEach { assertConsistent($0) }
            lowSun.append((hour, low))
        }

        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        print(String(format: "[E2E seoul] %d buildings, %d trees, graph %d nodes / %d edges; straight %.0f m",
                     parsed.buildings.count, parsed.trees.count, parsed.graph.nodes.count, parsed.graph.edges.count,
                     straight))
        for route in plan.routes {
            let label = route.profiles.map(\.rawValue).joined(separator: "+")
            print("[E2E seoul] \(label): " + String(format: "%.0f m (%.2fx straight), %.0f s, shade %.0f %%, crossings %d",
                                                   route.distance, route.distance / straight, route.duration,
                                                   route.shadeFraction * 100, route.crossingCount))
        }
        for (hour, low) in lowSun {
            for route in low.routes {
                let label = route.profiles.map(\.rawValue).joined(separator: "+")
                print("[E2E seoul \(hour) h] \(label): " + String(format: "%.0f m, shade %.0f %%, sun elevation %.0f°",
                                                                 route.distance, route.shadeFraction * 100,
                                                                 low.sun.elevation))
            }
        }
        print(String(format: "[E2E seoul timings] parse %.1f ms · engine build %.1f ms · edge shade %.1f ms · ",
                     ms(parseTime), ms(engineTime), ms(edgeShadeTime))
            + String(format: "routing %.1f ms · planner first plan %.1f ms · replan (new time) %.1f ms",
                     ms(routingTime), ms(planTime), ms(replanTime)))
    }
}
