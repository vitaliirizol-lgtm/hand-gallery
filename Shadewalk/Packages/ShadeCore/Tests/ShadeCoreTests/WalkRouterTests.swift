import XCTest
@testable import ShadeCore

/// Synthetic walk graph laid out in local metres (x east, y north) around a fixed origin.
struct RoutingTestGraph {
    static let origin = GeoCoordinate(latitude: 37.5665, longitude: 126.9780)
    static let sun = SunPosition(azimuth: 180, elevation: 50)
    static let departure = Date(timeIntervalSince1970: 1_780_000_000)

    let projection = LocalProjection(origin: RoutingTestGraph.origin)
    var nodes: [GraphNode] = []
    var edges: [GraphEdge] = []
    var shade: [Double] = []

    func at(_ x: Double, _ y: Double) -> GeoCoordinate { projection.unproject(Point2D(x: x, y: y)) }

    func xy(_ c: GeoCoordinate) -> Point2D { projection.project(c) }

    @discardableResult
    mutating func node(_ x: Double, _ y: Double, crossing: Bool = false) -> Int {
        let id = nodes.count
        nodes.append(GraphNode(id: id, osmID: Int64(1000 + id), coordinate: at(x, y), isCrossing: crossing))
        return id
    }

    @discardableResult
    mutating func edge(_ a: Int, _ b: Int, via: [(Double, Double)] = [], wayClass: WayClass = .footway,
                       name: String? = nil, shade s: Double = 0, crossing: Bool = false,
                       underpass: Bool = false) -> Int {
        let geometry = [nodes[a].coordinate] + via.map { at($0.0, $0.1) } + [nodes[b].coordinate]
        let id = edges.count
        edges.append(GraphEdge(id: id, from: a, to: b, geometry: geometry, length: GeoMath.length(of: geometry),
                               wayClass: wayClass, name: name, wayID: Int64(id), isUnderpass: underpass,
                               isCrossing: crossing))
        shade.append(s)
        return id
    }

    var graph: WalkGraph { WalkGraph(nodes: nodes, edges: edges) }

    func router(coolSpots: [CoolSpot] = []) -> WalkRouter {
        WalkRouter(graph: graph, edgeShade: shade, shadeEngine: nil, coolSpots: coolSpots)
    }

    func route(_ router: WalkRouter, from a: (Double, Double), to b: (Double, Double), profile: RouteProfile = .fastest,
               preferences: RoutingPreferences = .default, sun: SunPosition = RoutingTestGraph.sun) throws -> WalkRoute {
        try router.route(from: at(a.0, a.1), to: at(b.0, b.1), profile: profile, preferences: preferences, sun: sun,
                         departure: Self.departure)
    }

    func alternatives(_ router: WalkRouter, from a: (Double, Double), to b: (Double, Double),
                      preferences: RoutingPreferences = .default) throws -> [WalkRoute] {
        try router.alternatives(from: at(a.0, a.1), to: at(b.0, b.1), preferences: preferences,
                                sun: Self.sun, departure: Self.departure)
    }

    /// True if some route vertex lies within `tolerance` metres of `(x, y)`.
    func passes(_ route: WalkRoute, near x: Double, _ y: Double, tolerance: Double = 0.5) -> Bool {
        let p = Point2D(x: x, y: y)
        return route.coordinates.contains { xy($0).distance(to: p) <= tolerance }
    }

    /// `y` offset that makes the two-segment path (0,0) → (50, y) → (100, 0) exactly `length` metres long.
    static func bulge(forLength length: Double) -> Double {
        ((length / 2) * (length / 2) - 2500).squareRoot()
    }
}

final class WalkRouterTests: XCTestCase {
    // MARK: - Profiles

    /// Short sunny street vs. a 20 % longer fully shaded lane.
    private func parallelGraph(shadedLength: Double) -> RoutingTestGraph {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(100, 0)
        t.edge(a, b, name: "Sunny St", shade: 0)
        t.edge(a, b, via: [(50, RoutingTestGraph.bulge(forLength: shadedLength))], name: "Shady Ln", shade: 1)
        return t
    }

    func testShadiestTakesShadedParallelPathAndFastestTakesShortSunnyOne() throws {
        let t = parallelGraph(shadedLength: 120)
        let router = t.router()
        let routes = try t.alternatives(router, from: (0, 0), to: (100, 0))
        XCTAssertEqual(routes.count, 2)

        let shady = routes[0]
        XCTAssertEqual(shady.profile, .shadiest)
        XCTAssertEqual(shady.profiles, [.shadiest, .balanced])
        XCTAssertEqual(shady.distance, 120, accuracy: 0.5)
        XCTAssertEqual(shady.shadeFraction, 1, accuracy: 1e-9)
        XCTAssertEqual(shady.sunnyDistance, 0, accuracy: 1e-9)
        XCTAssertEqual(shady.shadedDistance, shady.distance, accuracy: 1e-6)
        XCTAssertTrue(shady.id.hasPrefix("shadiest-"))
        XCTAssertEqual(shady.maneuvers.first?.streetName, "Shady Ln")

        let fast = routes[1]
        XCTAssertEqual(fast.profile, .fastest)
        XCTAssertEqual(fast.profiles, [.fastest])
        XCTAssertEqual(fast.distance, 100, accuracy: 0.5)
        XCTAssertEqual(fast.shadeFraction, 0, accuracy: 1e-9)
        XCTAssertEqual(fast.sunnyDuration, fast.duration, accuracy: 1e-9)
        XCTAssertNotEqual(shady.id, fast.id)

        XCTAssertEqual(try t.route(router, from: (0, 0), to: (100, 0), profile: .fastest).distance, 100, accuracy: 0.5)
        XCTAssertEqual(try t.route(router, from: (0, 0), to: (100, 0), profile: .balanced).distance, 120, accuracy: 0.5)
        let single = try t.route(router, from: (0, 0), to: (100, 0), profile: .shadiest)
        XCTAssertEqual(single.distance, 120, accuracy: 0.5)
        XCTAssertEqual(single.profile, .shadiest)
        XCTAssertEqual(single.profiles, [.shadiest])
    }

    func testDetourCapFallsBackToFastestAndMergesAllProfiles() throws {
        let t = parallelGraph(shadedLength: 220) // +120 %: beyond the default 25 % cap
        let router = t.router()
        let routes = try t.alternatives(router, from: (0, 0), to: (100, 0))
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].profile, .shadiest)
        XCTAssertEqual(routes[0].profiles, [.shadiest, .balanced, .fastest])
        XCTAssertEqual(routes[0].distance, 100, accuracy: 0.5)
        XCTAssertTrue(routes[0].id.hasPrefix("shadiest-"))

        let shadiest = try t.route(router, from: (0, 0), to: (100, 0), profile: .shadiest)
        XCTAssertEqual(shadiest.distance, 100, accuracy: 0.5)
        XCTAssertEqual(shadiest.coordinates, routes[0].coordinates)
    }

    func testLargerDetourAllowanceAcceptsLongShadyRoute() throws {
        let t = parallelGraph(shadedLength: 220)
        let prefs = RoutingPreferences(maxDetourFraction: 1.5)
        let routes = try t.alternatives(t.router(), from: (0, 0), to: (100, 0), preferences: prefs)
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0].profiles, [.shadiest])
        XCTAssertEqual(routes[0].distance, 220, accuracy: 0.5)
        // k = 1: 100 m × 2 = 200 < 220 → the sunny street is both balanced and fastest.
        XCTAssertEqual(routes[1].profile, .balanced)
        XCTAssertEqual(routes[1].profiles, [.balanced, .fastest])
        XCTAssertEqual(routes[1].distance, 100, accuracy: 0.5)
    }

    func testBalancedOmittedWhenBeyondCapWhileShadiestUsesLowerPenalty() throws {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(100, 0)
        t.edge(a, b, name: "Direct", shade: 0) // 100 m sunny
        t.edge(a, b, via: [(50, RoutingTestGraph.bulge(forLength: 115))], name: "Half", shade: 0.6) // 115 m
        t.edge(a, b, via: [(50, -RoutingTestGraph.bulge(forLength: 140))], name: "Full", shade: 1) // 140 m
        let router = t.router()
        let routes = try t.alternatives(router, from: (0, 0), to: (100, 0))
        XCTAssertEqual(routes.map(\.profiles), [[.shadiest], [.fastest]])
        XCTAssertEqual(routes[0].distance, 115, accuracy: 0.5)
        XCTAssertEqual(routes[1].distance, 100, accuracy: 0.5)
        // route(profile: .balanced) falls back to the fastest route.
        let balanced = try t.route(router, from: (0, 0), to: (100, 0), profile: .balanced)
        XCTAssertEqual(balanced.distance, 100, accuracy: 0.5)
        XCTAssertEqual(balanced.profile, .balanced)
        // With a generous cap the k = 1 route (fully shaded) is offered and is the shadiest.
        let wide = try t.alternatives(router, from: (0, 0), to: (100, 0), preferences: RoutingPreferences(maxDetourFraction: 0.5))
        XCTAssertEqual(wide.map(\.profiles), [[.shadiest, .balanced], [.fastest]])
        XCTAssertEqual(wide[0].distance, 140, accuracy: 0.5)
    }

    func testRouteIDIsStableAndHexHashed() throws {
        let t = parallelGraph(shadedLength: 120)
        let router = t.router()
        let a = try t.route(router, from: (0, 0), to: (100, 0), profile: .fastest)
        let b = try t.route(router, from: (0, 0), to: (100, 0), profile: .fastest)
        XCTAssertEqual(a.id, b.id)
        XCTAssertTrue(a.id.hasPrefix("fastest-"))
        let hash = a.id.dropFirst("fastest-".count)
        XCTAssertEqual(hash.count, 16)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
        let reversed = try t.route(router, from: (100, 0), to: (0, 0), profile: .fastest)
        XCTAssertNotEqual(reversed.id, a.id)
    }

    // MARK: - Cost model

    func testAvoidStairs() throws {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), s1 = t.node(40, 0), s2 = t.node(50, 0), b = t.node(100, 0)
        t.edge(a, s1)
        t.edge(s1, s2, wayClass: .steps)
        t.edge(s2, b)
        t.edge(a, b, via: [(50, RoutingTestGraph.bulge(forLength: 115))], name: "Ramp")
        let router = t.router()

        // Stairs cost 10 m × 1.4 → 104 m-equivalent < 115 m.
        let normal = try t.route(router, from: (0, 0), to: (100, 0))
        XCTAssertEqual(normal.distance, 100, accuracy: 0.5)
        XCTAssertEqual(normal.stairsCount, 1)
        XCTAssertTrue(normal.maneuvers.contains { $0.kind == .takeStairs })
        let expected = 100 / 1.35 + 10 / 1.35 * (1 / 0.6 - 1)
        XCTAssertEqual(normal.duration, expected, accuracy: 0.05)

        // Avoiding stairs: 10 m × 6 → 150 > 115.
        let avoid = try t.route(router, from: (0, 0), to: (100, 0), preferences: RoutingPreferences(avoidStairs: true))
        XCTAssertEqual(avoid.distance, 115, accuracy: 0.5)
        XCTAssertEqual(avoid.stairsCount, 0)
        XCTAssertFalse(avoid.maneuvers.contains { $0.kind == .takeStairs })
        XCTAssertEqual(avoid.duration, avoid.distance / 1.35, accuracy: 1e-6)
    }

    func testStairsAndUnderpassRunsAreCounted() throws {
        var t = RoutingTestGraph()
        let n = (0...6).map { t.node(Double($0) * 20, 0) }
        t.edge(n[0], n[1], wayClass: .steps)
        t.edge(n[1], n[2], wayClass: .steps) // same flight
        t.edge(n[2], n[3], underpass: true)
        t.edge(n[3], n[4], underpass: true) // same underpass
        t.edge(n[4], n[5])
        t.edge(n[5], n[6], wayClass: .steps, underpass: true)
        let r = try t.route(t.router(), from: (0, 0), to: (120, 0))
        XCTAssertEqual(r.stairsCount, 2)
        XCTAssertEqual(r.underpassCount, 2)
        XCTAssertEqual(r.maneuvers.filter { $0.kind == .takeStairs }.count, 1) // the first flight is the departure
        XCTAssertEqual(r.maneuvers.filter { $0.kind == .enterUnderpass }.count, 1)
        let stairsLength = 60.0
        XCTAssertEqual(r.duration, 120 / 1.35 + stairsLength / 1.35 * (1 / 0.6 - 1), accuracy: 0.05)
    }

    func testCrossingNodePenaltyPrefersSlightlyLongerPath() throws {
        func build(alternativeLength: Double) -> RoutingTestGraph {
            var t = RoutingTestGraph()
            let a = t.node(0, 0), x = t.node(50, 0, crossing: true), b = t.node(100, 0)
            t.edge(a, x)
            t.edge(x, b)
            t.edge(a, b, via: [(50, RoutingTestGraph.bulge(forLength: alternativeLength))])
            return t
        }
        // 100 m + 12 m penalty = 112 > 108 → detour without crossing.
        let t1 = build(alternativeLength: 108)
        let r1 = try t1.route(t1.router(), from: (0, 0), to: (100, 0))
        XCTAssertEqual(r1.distance, 108, accuracy: 0.5)
        XCTAssertEqual(r1.crossingCount, 0)
        // 112 < 115 → straight across.
        let t2 = build(alternativeLength: 115)
        let r2 = try t2.route(t2.router(), from: (0, 0), to: (100, 0))
        XCTAssertEqual(r2.distance, 100, accuracy: 0.5)
        XCTAssertEqual(r2.crossingCount, 1)
        XCTAssertEqual(r2.duration, 100 / 1.35 + 10, accuracy: 0.05)
    }

    func testCrossingCountMergesCrossingEdgeWithItsNode() throws {
        var t = RoutingTestGraph()
        let n0 = t.node(0, 0), n1 = t.node(50, 0, crossing: true), n2 = t.node(100, 0), n3 = t.node(110, 0)
        let n4 = t.node(120, 0, crossing: true), n5 = t.node(130, 0), n6 = t.node(200, 0), n7 = t.node(210, 0)
        let n8 = t.node(260, 0)
        t.edge(n0, n1, name: "Walk")
        t.edge(n1, n2, name: "Walk")
        t.edge(n2, n3, name: "Walk")
        t.edge(n3, n4, wayClass: .crossing, crossing: true)
        t.edge(n4, n5, wayClass: .crossing, crossing: true)
        t.edge(n5, n6, name: "Walk")
        t.edge(n6, n7, wayClass: .crossing, crossing: true)
        t.edge(n7, n8, name: "Walk")
        let r = try t.route(t.router(), from: (0, 0), to: (260, 0))
        // n1 alone, the n3–n5 crossing (incl. node n4) once, the n6–n7 crossing edge.
        XCTAssertEqual(r.crossingCount, 3)
        XCTAssertEqual(r.duration, 260 / 1.35 + 30, accuracy: 0.05)
        XCTAssertEqual(r.maneuvers.map(\.kind), [.depart, .crossStreet, .crossStreet, .crossStreet, .arrive])
        XCTAssertEqual(r.maneuvers[1].distanceFromStart, 50, accuracy: 0.1)
        XCTAssertEqual(r.maneuvers[2].distanceFromStart, 110, accuracy: 0.1)
        XCTAssertEqual(r.maneuvers[3].distanceFromStart, 200, accuracy: 0.1)
    }

    func testDualCarriagewayCrossingCountsEachRoadNode() throws {
        var t = RoutingTestGraph()
        let kerbA = t.node(0, 0), roadA = t.node(5, 0, crossing: true), island = t.node(10, 0)
        let roadB = t.node(15, 0, crossing: true), kerbB = t.node(20, 0), end = t.node(60, 0)
        let start = t.node(-40, 0)
        t.edge(start, kerbA, name: "Sidewalk")
        t.edge(kerbA, roadA, wayClass: .crossing, crossing: true)
        t.edge(roadA, island, wayClass: .crossing, crossing: true)
        t.edge(island, roadB, wayClass: .crossing, crossing: true)
        t.edge(roadB, kerbB, wayClass: .crossing, crossing: true)
        t.edge(kerbB, end, name: "Sidewalk")
        let r = try t.route(t.router(), from: (-40, 0), to: (60, 0))
        XCTAssertEqual(r.crossingCount, 2)
        XCTAssertEqual(r.maneuvers.map(\.kind), [.depart, .crossStreet, .arrive])
        XCTAssertEqual(r.duration, 100 / 1.35 + 20, accuracy: 0.05)
    }

    func testCrossingCountRules() {
        func leg(_ crossingEdge: Bool, endsAtCrossing: Bool = false) -> RouteAssembler.Leg {
            RouteAssembler.Leg(geometry: [], isCrossingEdge: crossingEdge, endsAtCrossingNode: endsAtCrossing)
        }
        XCTAssertEqual(RouteAssembler.crossingCount([]), 0)
        // Crossing way split at its (crossing) road node: one crossing.
        XCTAssertEqual(RouteAssembler.crossingCount([leg(false), leg(true, endsAtCrossing: true), leg(true), leg(false)]), 1)
        // Crossing way without a crossing node.
        XCTAssertEqual(RouteAssembler.crossingCount([leg(false), leg(true), leg(false)]), 1)
        // A crossing node right before / after a crossing edge belongs to that crossing.
        XCTAssertEqual(RouteAssembler.crossingCount([leg(false, endsAtCrossing: true), leg(true), leg(false)]), 1)
        XCTAssertEqual(RouteAssembler.crossingCount([leg(false), leg(true, endsAtCrossing: true), leg(false)]), 1)
        // Isolated crossing nodes, including the destination node.
        XCTAssertEqual(RouteAssembler.crossingCount([leg(false, endsAtCrossing: true), leg(false, endsAtCrossing: true)]), 2)
        // Two separate crossing runs.
        XCTAssertEqual(RouteAssembler.crossingCount([leg(true), leg(false), leg(true)]), 2)
    }

    func testBothEndsSnapOntoSameNode() throws {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(200, 0)
        t.edge(a, b)
        let r = try t.route(t.router(), from: (0, 5), to: (0, -5))
        XCTAssertEqual(r.coordinates.count, 3)
        XCTAssertEqual(r.coordinates[1], t.nodes[a].coordinate)
        XCTAssertEqual(r.distance, 10, accuracy: 0.01)
        XCTAssertEqual(r.maneuvers.map(\.kind), [.depart, .arrive])

        let here = try t.route(t.router(), from: (0, 0), to: (0, 0))
        XCTAssertEqual(here.coordinates, [t.nodes[a].coordinate])
        XCTAssertEqual(here.distance, 0)
        XCTAssertEqual(here.duration, 0)
        XCTAssertEqual(here.stepCount, 0)
        XCTAssertEqual(here.segments, [])
        XCTAssertEqual(here.shadeFraction, 0)
    }

    func testSunPenaltyUsesEdgeShadeFractions() throws {
        // Two 100 m-ish paths with partial shade; the shadier one wins with k > 0 even though it is longer.
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(100, 0)
        t.edge(a, b, shade: 0.3)
        t.edge(a, b, via: [(50, RoutingTestGraph.bulge(forLength: 104))], shade: 0.9)
        let routes = try t.alternatives(t.router(), from: (0, 0), to: (100, 0))
        XCTAssertEqual(routes.count, 2)
        XCTAssertEqual(routes[0].distance, 104, accuracy: 0.5)
        XCTAssertEqual(routes[1].distance, 100, accuracy: 0.5)
    }

    // MARK: - Snapping

    private func straightStreet() -> RoutingTestGraph {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(200, 0), c = t.node(200, 100)
        t.edge(a, b, via: [(100, 0)], name: "Long St")
        t.edge(b, c, name: "Side St")
        return t
    }

    func testOriginAndDestinationOnSameEdge() throws {
        let t = straightStreet()
        let router = t.router()
        let r = try t.route(router, from: (50, 10), to: (150, 10))
        XCTAssertEqual(r.distance, 120, accuracy: 0.2)
        XCTAssertEqual(r.coordinates.count, 5) // origin, snap, shape point at 100 m, snap, destination
        XCTAssertEqual(r.coordinates.first, t.at(50, 10))
        XCTAssertEqual(r.coordinates.last, t.at(150, 10))
        XCTAssertEqual(t.xy(r.coordinates[1]).distance(to: Point2D(x: 50, y: 0)), 0, accuracy: 0.01)
        XCTAssertEqual(t.xy(r.coordinates[3]).distance(to: Point2D(x: 150, y: 0)), 0, accuracy: 0.01)
        XCTAssertEqual(r.maneuvers.first?.streetName, "Long St")

        let back = try t.route(router, from: (150, -5), to: (50, -5))
        XCTAssertEqual(back.distance, 110, accuracy: 0.2)
        XCTAssertTrue(t.passes(back, near: 100, 0))
    }

    func testOriginAndDestinationSnapToSamePoint() throws {
        let t = straightStreet()
        let r = try t.route(t.router(), from: (50, 10), to: (50, -10))
        XCTAssertEqual(r.distance, 20, accuracy: 0.1)
        XCTAssertEqual(r.coordinates.count, 3)
        XCTAssertEqual(r.maneuvers.map(\.kind), [.depart, .arrive])
        XCTAssertEqual(r.crossingCount, 0)
    }

    func testSnappingExactlyOntoNodeAddsNoAccessLeg() throws {
        let t = straightStreet()
        let router = t.router()
        let r = try t.route(router, from: (0, 0), to: (200, 100))
        XCTAssertEqual(r.coordinates.first, t.nodes[0].coordinate)
        XCTAssertEqual(r.coordinates.last, t.nodes[2].coordinate)
        XCTAssertEqual(r.coordinates.count, 4)
        XCTAssertEqual(r.distance, 300, accuracy: 0.2)

        // Within 1 m of the street: the route starts at the snapped point, no access leg.
        let close = try t.route(router, from: (150, 0.6), to: (200, 100))
        XCTAssertEqual(t.xy(close.coordinates[0]).distance(to: Point2D(x: 150, y: 0)), 0, accuracy: 0.01)
        XCTAssertEqual(close.distance, 150, accuracy: 0.1)

        // Close to a node along the edge: snaps onto the node, with an access leg from the real origin.
        let nearNode = try t.route(router, from: (0.3, 5), to: (200, 100))
        XCTAssertEqual(nearNode.coordinates[0], t.at(0.3, 5))
        XCTAssertEqual(nearNode.coordinates[1], t.nodes[0].coordinate)
    }

    func testAccessLegsAreSunnyWithoutShadeEngine() throws {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(100, 0)
        t.edge(a, b, shade: 1)
        let r = try t.route(t.router(), from: (20, 20), to: (80, -5))
        XCTAssertEqual(r.distance, 20 + 60 + 5, accuracy: 0.1)
        XCTAssertEqual(r.sunnyDistance, 25, accuracy: 0.1)
        XCTAssertEqual(r.shadedDistance, 60, accuracy: 0.1) // virtual sub-edges inherit the parent's shade
        XCTAssertEqual(r.segments.map(\.isShaded), [false, true, false])
        XCTAssertEqual(r.shadeFraction, 60.0 / 85.0, accuracy: 1e-3)
        XCTAssertEqual(r.shadedDuration + r.sunnyDuration, r.duration, accuracy: 1e-9)
        XCTAssertEqual(r.shadedDuration, r.duration * 60 / 85, accuracy: 0.05)
    }

    func testTooFarFromNetwork() throws {
        let t = straightStreet()
        let router = t.router()
        XCTAssertThrowsError(try t.route(router, from: (50, 400), to: (150, 0))) {
            XCTAssertEqual($0 as? ShadeError, .originTooFarFromNetwork)
        }
        XCTAssertThrowsError(try t.route(router, from: (50, 0), to: (100, -260))) {
            XCTAssertEqual($0 as? ShadeError, .destinationTooFarFromNetwork)
        }
        XCTAssertThrowsError(try t.alternatives(router, from: (50, 400), to: (100, -400))) {
            XCTAssertEqual($0 as? ShadeError, .originTooFarFromNetwork)
        }
        XCTAssertThrowsError(try router.route(from: GeoCoordinate(latitude: .nan, longitude: 0), to: t.at(0, 0),
                                              profile: .fastest, preferences: .default, sun: RoutingTestGraph.sun,
                                              departure: RoutingTestGraph.departure)) {
            XCTAssertEqual($0 as? ShadeError, .originTooFarFromNetwork)
        }
        // 249 m away is still fine.
        let r = try t.route(router, from: (50, -249), to: (150, 0))
        XCTAssertEqual(r.distance, 249 + 100, accuracy: 0.5)
    }

    func testDisconnectedNetworkThrowsNoRouteFound() {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(100, 0), c = t.node(0, 150), d = t.node(100, 150)
        t.edge(a, b)
        t.edge(c, d)
        let router = t.router()
        XCTAssertThrowsError(try t.route(router, from: (50, 0), to: (50, 150))) {
            XCTAssertEqual($0 as? ShadeError, .noRouteFound)
        }
        XCTAssertThrowsError(try t.alternatives(router, from: (0, 0), to: (100, 150))) {
            XCTAssertEqual($0 as? ShadeError, .noRouteFound)
        }
    }

    func testEmptyGraphThrowsNoWalkableNetwork() {
        let router = WalkRouter(graph: .empty, edgeShade: [], shadeEngine: nil)
        XCTAssertThrowsError(try router.route(from: RoutingTestGraph.origin, to: RoutingTestGraph.origin,
                                              profile: .fastest, preferences: .default, sun: RoutingTestGraph.sun,
                                              departure: RoutingTestGraph.departure)) {
            XCTAssertEqual($0 as? ShadeError, .noWalkableNetwork)
        }
    }

    func testOriginOnSelfLoopEdge() throws {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(100, 0)
        t.edge(a, b)
        t.edge(a, a, via: [(-40, 0), (-40, 40), (0, 40)]) // 160 m loop west of a
        let r = try t.route(t.router(), from: (-40, 10), to: (100, 0))
        // Shorter way round the loop: (-40,10) → (-40,0) → (0,0) = 50 m, then 100 m.
        XCTAssertEqual(r.distance, 150, accuracy: 0.2)
    }

    // MARK: - Metrics

    func testSegmentsMergeEqualNeighboursAndSumToDistance() throws {
        var t = RoutingTestGraph()
        let n = (0...4).map { t.node(Double($0) * 25, 0) }
        t.edge(n[0], n[1], shade: 1)
        t.edge(n[1], n[2], shade: 0.8)
        t.edge(n[2], n[3], shade: 0)
        t.edge(n[3], n[4], shade: 0.2)
        let r = try t.route(t.router(), from: (0, 0), to: (100, 0))
        XCTAssertEqual(r.segments.map(\.isShaded), [true, false])
        XCTAssertEqual(r.segments[0].length, 50, accuracy: 0.05)
        XCTAssertEqual(r.segments[0].coordinates.count, 3)
        XCTAssertEqual(r.segments[1].coordinates.first, r.segments[0].coordinates.last)
        XCTAssertEqual(r.segments.map(\.length).reduce(0, +), r.distance, accuracy: 1e-6)
        XCTAssertEqual(r.shadeFraction, 0.5, accuracy: 1e-3)
        XCTAssertEqual(r.stepCount, Int((r.distance / 0.74).rounded()))
        XCTAssertEqual(r.departure, RoutingTestGraph.departure)
        XCTAssertEqual(r.sun, RoutingTestGraph.sun)
        XCTAssertNil(r.elevation)
    }

    func testSunDownCountsEverythingShaded() throws {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(100, 0)
        t.edge(a, b, shade: 0)
        let night = SunPosition(azimuth: 0, elevation: -10)
        let r = try t.route(t.router(), from: (10, 10), to: (90, 0), sun: night)
        XCTAssertEqual(r.shadeFraction, 1)
        XCTAssertEqual(r.sunnyDistance, 0)
    }

    func testInjectedShadeRunsAreUsed() throws {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var polylines: [[GeoCoordinate]] = []
            func record(_ p: [GeoCoordinate]) { lock.lock(); polylines.append(p); lock.unlock() }
            var calls: [[GeoCoordinate]] { lock.lock(); defer { lock.unlock() }; return polylines }
        }
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(100, 0)
        t.edge(a, b, shade: 0)
        let box = Box()
        let router = WalkRouter(graph: t.graph, edgeShade: t.shade, shadeRuns: { polyline, sun in
            box.record(polyline)
            let length = GeoMath.length(of: polyline)
            return [RouteSegment(coordinates: polyline, length: length, isShaded: sun.isUp)]
        })
        let r = try t.route(router, from: (0, 10), to: (100, 0))
        XCTAssertEqual(box.calls.count, 1)
        XCTAssertEqual(box.calls.first, r.coordinates)
        XCTAssertEqual(r.segments.count, 1)
        XCTAssertEqual(r.shadeFraction, 1) // access leg included, coloured by the provider
        XCTAssertEqual(r.shadedDistance, r.distance, accuracy: 1e-9)
    }

    func testMissingOrInvalidEdgeShadeIsTreatedAsSunny() throws {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(100, 0)
        t.edge(a, b)
        t.edge(a, b, via: [(50, 20)])
        let router = WalkRouter(graph: t.graph, edgeShade: [.nan], shadeEngine: nil)
        let routes = try router.alternatives(from: t.at(0, 0), to: t.at(100, 0), preferences: .default,
                                             sun: RoutingTestGraph.sun, departure: RoutingTestGraph.departure)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes[0].shadeFraction, 0)
    }

    func testCoolSpotsNearRouteInRouteOrder() throws {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), b = t.node(200, 0), c = t.node(0, 300)
        t.edge(a, b)
        t.edge(a, c)
        let spots = [
            CoolSpot(id: 1, kind: .drinkingWater, name: "Fountain", coordinate: t.at(100, 30)),
            CoolSpot(id: 2, kind: .park, name: nil, coordinate: t.at(100, 60)),
            CoolSpot(id: 3, kind: .shelter, name: nil, coordinate: t.at(-30, 0)),
            CoolSpot(id: 4, kind: .indoorCool, name: "Library", coordinate: t.at(150, -39)),
            CoolSpot(id: 5, kind: .park, name: nil, coordinate: t.at(0, 200)),
        ]
        let r = try t.route(t.router(coolSpots: spots), from: (0, 0), to: (200, 0))
        XCTAssertEqual(r.coolSpotIDs, [3, 1, 4])
    }

    // MARK: - Optimality & performance

    func testAStarMatchesDijkstraOnRandomGraphs() throws {
        var rng = RoutingTestRNG(seed: 42)
        for trial in 0..<6 {
            var t = RoutingTestGraph()
            let side = 9
            for j in 0..<side {
                for i in 0..<side {
                    t.node(Double(i) * 30 + rng.next(in: -8...8), Double(j) * 30 + rng.next(in: -8...8),
                           crossing: rng.next(in: 0...1) < 0.15)
                }
            }
            let classes: [WayClass] = [.footway, .residential, .minorRoad, .majorRoad, .steps, .path]
            for j in 0..<side {
                for i in 0..<side {
                    let id = j * side + i
                    if i + 1 < side, rng.next(in: 0...1) < 0.85 {
                        t.edge(id, id + 1, wayClass: classes[Int(rng.next(in: 0...5.999))], shade: rng.next(in: 0...1))
                    }
                    if j + 1 < side, rng.next(in: 0...1) < 0.85 {
                        t.edge(id, id + side, wayClass: classes[Int(rng.next(in: 0...5.999))], shade: rng.next(in: 0...1))
                    }
                }
            }
            let net = RoutingNetwork(graph: t.graph, edgeShade: t.shade)
            let query = QueryGraph(net: net)
            for k in [0.0, 1, 16] {
                for avoid in [false, true] {
                    let cost = AStar.CostModel(sunPenalty: k, avoidStairs: avoid)
                    let goal = side * side - 1
                    let reference = dijkstra(net, from: 0, cost: cost)
                    let path = AStar.shortestPath(in: query, from: 0, to: goal, cost: cost)
                    if reference[goal].isInfinite {
                        XCTAssertNil(path, "trial \(trial)")
                        continue
                    }
                    let steps = try XCTUnwrap(path, "trial \(trial)")
                    let total = steps.reduce(0.0) { $0 + edgeCost(net, $1.edge, entering: $1.to, cost: cost) }
                    XCTAssertEqual(total, reference[goal], accuracy: 1e-6, "trial \(trial) k \(k)")
                    XCTAssertEqual(steps.first?.from, 0)
                    XCTAssertEqual(steps.last?.to, goal)
                    for (x, y) in zip(steps, steps.dropFirst()) { XCTAssertEqual(x.to, y.from) }
                }
            }
        }
    }

    func testSpatialIndexMatchesBruteForce() {
        var rng = RoutingTestRNG(seed: 99)
        var geometries: [[Point2D]] = []
        for _ in 0..<300 {
            var pts = [Point2D(x: rng.next(in: -500...500), y: rng.next(in: -500...500))]
            for _ in 0..<Int(rng.next(in: 1...4.99)) {
                let prev = pts[pts.count - 1]
                pts.append(Point2D(x: prev.x + rng.next(in: -120...120), y: prev.y + rng.next(in: -120...120)))
            }
            geometries.append(pts)
        }
        geometries.append([Point2D(x: 10, y: -2000), Point2D(x: 10.000_000_01, y: 2000)]) // steep and long
        geometries.append([Point2D(x: -3000, y: 7), Point2D(x: 3000, y: 7)]) // long horizontal
        geometries.append([Point2D(x: 50, y: -300), Point2D(x: 50, y: 300)]) // on a cell border
        geometries.append([Point2D(x: -300, y: -100), Point2D(x: 300, y: -100)]) // on a cell border
        geometries.append([Point2D(x: 5, y: 5), Point2D(x: 5, y: 5)]) // degenerate
        geometries.append([]) // edge without geometry
        let index = EdgeSpatialIndex(geometries: geometries)
        var hits = 0
        for _ in 0..<500 {
            let q = Point2D(x: rng.next(in: -900...900), y: rng.next(in: -900...900))
            var best = Double.infinity
            for g in geometries where g.count >= 2 {
                for i in 0..<(g.count - 1) { best = min(best, Geometry2D.distanceToSegment(q, g[i], g[i + 1])) }
            }
            let hit = index.nearest(to: q, within: 250)
            if best <= 250 {
                hits += 1
                XCTAssertEqual(hit?.distance ?? -1, best, accuracy: 1e-9)
                if let hit {
                    let (a, b) = index.segment(hit.edge, hit.segment)
                    XCTAssertEqual(a + (b - a) * hit.fraction, hit.point)
                }
            } else {
                XCTAssertNil(hit)
            }
        }
        XCTAssertGreaterThan(hits, 100)
        XCTAssertNil(index.nearest(to: Point2D(x: .nan, y: 0), within: 250))
    }

    func testRoutesTwentyThousandEdgeGraphQuickly() throws {
        var t = RoutingTestGraph()
        let side = 100 // 100 × 100 nodes → 19 800 edges
        var rng = RoutingTestRNG(seed: 7)
        for j in 0..<side { for i in 0..<side { t.node(Double(i) * 20, Double(j) * 20) } }
        for j in 0..<side {
            for i in 0..<side {
                let id = j * side + i
                if i + 1 < side { t.edge(id, id + 1, shade: rng.next(in: 0...1) < 0.4 ? 1 : 0) }
                if j + 1 < side { t.edge(id, id + side, shade: rng.next(in: 0...1) < 0.4 ? 1 : 0) }
            }
        }
        XCTAssertGreaterThanOrEqual(t.edges.count, 19_800)
        let started = Date()
        let router = t.router()
        let routes = try t.alternatives(router, from: (3, 5), to: (1_975, 1_970))
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertFalse(routes.isEmpty)
        XCTAssertTrue(routes.contains { $0.profiles.contains(.fastest) })
        // Debug builds are ~10× slower than release; this only guards against O(E)-per-step regressions.
        XCTAssertLessThan(elapsed, 8, "index build + 7 searches took \(elapsed) s")
    }

    // MARK: - Helpers

    private func edgeCost(_ net: RoutingNetwork, _ e: Int, entering v: Int, cost: AStar.CostModel) -> Double {
        let mult = net.edgeIsSteps[e] ? cost.stairsFactor : net.edgeClassFactor[e]
        let crossing = net.nodeIsCrossing[v] ? 12.0 : 0
        return (net.edgeLength[e] * mult + crossing) * (1 + cost.sunPenalty * net.edgeSunny[e])
    }

    /// Plain O(V²) Dijkstra over the base graph as an oracle.
    private func dijkstra(_ net: RoutingNetwork, from s: Int, cost: AStar.CostModel) -> [Double] {
        var dist = [Double](repeating: .infinity, count: net.nodeCount)
        var done = [Bool](repeating: false, count: net.nodeCount)
        dist[s] = 0
        for _ in 0..<net.nodeCount {
            var u = -1
            for v in 0..<net.nodeCount where !done[v] && dist[v].isFinite && (u < 0 || dist[v] < dist[u]) { u = v }
            if u < 0 { break }
            done[u] = true
            for e in net.graph.adjacency[u] {
                let v = net.graph.edges[e].other(u)
                dist[v] = min(dist[v], dist[u] + edgeCost(net, e, entering: v, cost: cost))
            }
        }
        return dist
    }
}

/// Deterministic PRNG for synthetic graphs.
struct RoutingTestRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        let unit = Double(nextUInt64() >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
