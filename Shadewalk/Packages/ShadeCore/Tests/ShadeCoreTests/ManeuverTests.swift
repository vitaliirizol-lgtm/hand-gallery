import XCTest
@testable import ShadeCore

final class ManeuverTests: XCTestCase {
    /// Junction J at (0, 0) approached from the west along Main St, with branches in many directions.
    private func star() -> RoutingTestGraph {
        var t = RoutingTestGraph()
        let w = t.node(-100, 0), j = t.node(0, 0)
        let e = t.node(100, 0), n = t.node(0, 100), s = t.node(0, -100)
        let ne = t.node(86.6, 50), se = t.node(86.6, -50), sw = t.node(-86.6, -50)
        let hairpin = t.node(-99.62, -8.72) // bearing 265° from J
        t.edge(w, j, name: "Main St")
        t.edge(j, e, name: "Main St")
        t.edge(j, n, name: "North Ave")
        t.edge(j, s, name: "South Ave")
        t.edge(j, ne, name: "Slight Rd")
        t.edge(j, se, name: "Fork Rd")
        t.edge(j, sw, name: "Back Rd")
        t.edge(j, hairpin, name: "Hairpin")
        return t
    }

    private func kinds(_ r: WalkRoute) -> [ManeuverKind] { r.maneuvers.map(\.kind) }

    func testTurnDirectionsAtJunction() throws {
        let t = star()
        let router = t.router()
        let cases: [((Double, Double), ManeuverKind, String)] = [
            ((0, 100), .left, "North Ave"),
            ((0, -100), .right, "South Ave"),
            ((86.6, 50), .slightLeft, "Slight Rd"),
            ((86.6, -50), .slightRight, "Fork Rd"),
            ((-86.6, -50), .sharpRight, "Back Rd"),
            ((-99.62, -8.72), .uTurn, "Hairpin"),
        ]
        for (target, kind, street) in cases {
            let r = try t.route(router, from: (-100, 0), to: target)
            XCTAssertEqual(kinds(r), [.depart, kind, .arrive], "towards \(street)")
            XCTAssertEqual(r.maneuvers[0].streetName, "Main St")
            XCTAssertEqual(r.maneuvers[1].streetName, street)
            XCTAssertEqual(r.maneuvers[1].distanceFromStart, 100, accuracy: 0.1)
            XCTAssertEqual(t.xy(r.maneuvers[1].coordinate).length, 0, accuracy: 0.01)
            XCTAssertEqual(r.maneuvers[2].distanceFromStart, r.distance, accuracy: 1e-9)
            XCTAssertEqual(r.maneuvers[2].streetName, street)
        }
    }

    func testStraightOnSameStreetIsNotAnnounced() throws {
        let t = star()
        let r = try t.route(t.router(), from: (-100, 0), to: (100, 0))
        XCTAssertEqual(kinds(r), [.depart, .arrive])
        XCTAssertEqual(r.maneuvers[0].coordinate, t.nodes[0].coordinate)
        XCTAssertEqual(r.maneuvers[1].coordinate, t.nodes[2].coordinate)
    }

    func testStraightOntoRenamedStreetIsAnnounced() throws {
        var t = RoutingTestGraph()
        let a = t.node(-100, 0), j = t.node(0, 0), b = t.node(100, 0), c = t.node(0, 100)
        t.edge(a, j, name: "Main St")
        t.edge(j, b, name: "Broadway")
        t.edge(j, c, name: "Side St")
        let r = try t.route(t.router(), from: (-100, 0), to: (100, 0))
        XCTAssertEqual(kinds(r), [.depart, .continueStraight, .arrive])
        XCTAssertEqual(r.maneuvers[1].streetName, "Broadway")
    }

    func testUnnamedStretchDoesNotTriggerContinueOnReturnToSameStreet() throws {
        var t = RoutingTestGraph()
        let n = (0...3).map { t.node(Double($0) * 50, 0) }
        let side = t.node(50, 50)
        t.edge(n[0], n[1], name: "Main St")
        t.edge(n[1], n[2]) // unnamed sidewalk piece
        t.edge(n[2], n[3], name: "Main St")
        t.edge(n[1], side, name: "Side St")
        let r = try t.route(t.router(), from: (0, 0), to: (150, 0))
        XCTAssertEqual(kinds(r), [.depart, .arrive])
    }

    func testSlightBendWithoutJunctionIsSuppressed() throws {
        func build(secondName: String) -> RoutingTestGraph {
            var t = RoutingTestGraph()
            let a = t.node(0, 0), m = t.node(100, 0), b = t.node(186.6, 50)
            t.edge(a, m, name: "Path")
            t.edge(m, b, name: secondName)
            return t
        }
        let same = build(secondName: "Path")
        XCTAssertEqual(kinds(try same.route(same.router(), from: (0, 0), to: (186.6, 50))), [.depart, .arrive])
        let renamed = build(secondName: "Other Path")
        XCTAssertEqual(kinds(try renamed.route(renamed.router(), from: (0, 0), to: (186.6, 50))),
                       [.depart, .slightLeft, .arrive])
    }

    func testRealTurnWithoutJunctionIsAnnounced() throws {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), m = t.node(100, 0), b = t.node(100, -100)
        t.edge(a, m, name: "Path")
        t.edge(m, b, name: "Path")
        let r = try t.route(t.router(), from: (0, 0), to: (100, -100))
        XCTAssertEqual(kinds(r), [.depart, .right, .arrive])
    }

    func testCrossStreetTakesPriorityOverTurn() throws {
        var t = RoutingTestGraph()
        let a = t.node(0, 0), j = t.node(100, 0), b = t.node(100, 30), c = t.node(200, 0)
        t.edge(a, j, name: "Sidewalk")
        t.edge(j, b, wayClass: .crossing, crossing: true)
        t.edge(j, c, name: "Sidewalk")
        let r = try t.route(t.router(), from: (0, 0), to: (100, 30))
        XCTAssertEqual(kinds(r), [.depart, .crossStreet, .arrive])
        XCTAssertEqual(r.crossingCount, 1)
    }

    func testAccessLegJunctionsAreCoveredByDepartAndArrive() throws {
        let t = star()
        let r = try t.route(t.router(), from: (-100, 10), to: (10, 100))
        XCTAssertEqual(kinds(r), [.depart, .left, .arrive])
        XCTAssertEqual(r.maneuvers[0].coordinate, t.at(-100, 10))
        XCTAssertEqual(r.maneuvers[0].streetName, "Main St")
        XCTAssertEqual(r.maneuvers[1].distanceFromStart, 110, accuracy: 0.1)
        XCTAssertEqual(r.maneuvers[2].coordinate, t.at(10, 100))
        XCTAssertEqual(r.maneuvers[2].distanceFromStart, r.distance, accuracy: 1e-9)
    }

    func testTurnAngleBuckets() {
        let expected: [(Double, ManeuverKind)] = [
            (0, .continueStraight), (19.9, .continueStraight), (-19.9, .continueStraight),
            (20, .slightRight), (-44.9, .slightLeft), (45, .right), (-90, .left), (134.9, .right),
            (135, .sharpRight), (-169.9, .sharpLeft), (170, .uTurn), (-175, .uTurn), (180, .uTurn),
        ]
        for (angle, kind) in expected {
            XCTAssertEqual(ManeuverBuilder.turnKind(angle: angle), kind, "angle \(angle)")
        }
    }

    func testBuilderHandlesDegenerateInput() {
        XCTAssertEqual(ManeuverBuilder.build(coordinates: [], cumulative: [], legs: []), [])
        let c = RoutingTestGraph().at(0, 0)
        let single = ManeuverBuilder.build(coordinates: [c], cumulative: [0],
                                           legs: [ManeuverBuilder.Leg(startIndex: 0, name: "X")])
        XCTAssertEqual(single.map(\.kind), [.depart, .arrive])
        XCTAssertEqual(single.map(\.streetName), ["X", "X"])
    }

    func testPointAlongPolyline() {
        let t = RoutingTestGraph()
        let line = [t.at(0, 0), t.at(100, 0), t.at(100, 100)]
        let cum = GeoMath.cumulativeDistances(of: line)
        let p = ManeuverBuilder.point(coordinates: line, cumulative: cum, at: 150)
        XCTAssertEqual(t.xy(p).distance(to: Point2D(x: 100, y: 50)), 0, accuracy: 0.05)
        XCTAssertEqual(ManeuverBuilder.point(coordinates: line, cumulative: cum, at: -5), line[0])
        XCTAssertEqual(ManeuverBuilder.point(coordinates: line, cumulative: cum, at: 1e6), line[2])
    }
}
