import XCTest
@testable import ShadeCore

final class WalkGraphBuilderTests: XCTestCase {
    let origin = GeoCoordinate(latitude: 37.5716, longitude: 126.9769)
    lazy var projection = LocalProjection(origin: origin)

    /// Coordinate `x` metres east and `y` metres north of `origin`.
    func pt(_ x: Double, _ y: Double) -> GeoCoordinate { projection.unproject(Point2D(x: x, y: y)) }

    /// Walkable way through `points` (node id, x, y).
    func way(_ id: Int64, _ points: [(Int64, Double, Double)], _ tags: [String: String] = ["highway": "footway"])
        -> OSMElement {
        OSMElement(type: .way, id: id, tags: tags, nodes: points.map(\.0), geometry: points.map { pt($0.1, $0.2) })
    }

    func node(_ id: Int64, _ x: Double, _ y: Double, _ tags: [String: String]) -> OSMElement {
        OSMElement(type: .node, id: id, coordinate: pt(x, y), tags: tags)
    }

    // MARK: Tag rules

    func testWalkabilityRules() {
        let cases: [([String: String], Bool)] = [
            (["highway": "footway"], true), (["highway": "pedestrian"], true), (["highway": "path"], true),
            (["highway": "steps"], true), (["highway": "living_street"], true), (["highway": "residential"], true),
            (["highway": "service"], true), (["highway": "unclassified"], true), (["highway": "track"], true),
            (["highway": "cycleway"], true), (["highway": "tertiary"], true), (["highway": "tertiary_link"], true),
            (["highway": "secondary"], true), (["highway": "secondary_link"], true), (["highway": "primary"], true),
            (["highway": "primary_link"], true), (["highway": "corridor"], true),
            (["highway": "cycleway", "foot": "no"], false),
            (["highway": "bridleway"], false), (["highway": "bridleway", "foot": "yes"], true),
            (["highway": "bridleway", "foot": "designated"], true),
            (["highway": "motorway"], false), (["highway": "motorway_link"], false), (["highway": "trunk"], false),
            (["highway": "trunk_link"], false), (["highway": "trunk", "foot": "yes"], true),
            (["highway": "motorway", "foot": "designated"], true), (["highway": "trunk", "foot": "permissive"], false),
            (["highway": "footway", "foot": "no"], false), (["highway": "residential", "foot": "use_sidepath"], false),
            (["highway": "footway", "foot": "private"], false),
            (["highway": "service", "access": "private"], false), (["highway": "footway", "access": "no"], false),
            (["highway": "service", "access": "private", "foot": "yes"], true),
            (["highway": "service", "access": "no", "foot": "permissive"], true),
            (["highway": "path", "access": "private", "foot": "designated"], true),
            (["highway": "service", "access": "destination"], true),
            (["highway": "pedestrian", "area": "yes"], false), (["highway": "footway", "area": "no"], true),
            (["highway": "construction"], false), (["highway": "proposed"], false), (["highway": "platform"], false),
            (["building": "yes"], false), ([:], false),
        ]
        for (tags, expected) in cases {
            XCTAssertEqual(WalkGraphBuilder.isWalkable(tags), expected, "\(tags)")
        }
    }

    func testWayClassMapping() {
        let cases: [([String: String], WayClass)] = [
            (["highway": "footway"], .footway), (["highway": "footway", "footway": "sidewalk"], .sidewalk),
            (["highway": "path", "footway": "sidewalk"], .sidewalk),
            (["highway": "footway", "footway": "crossing"], .crossing),
            (["highway": "footway", "crossing": "marked"], .crossing),
            (["highway": "footway", "crossing": "no"], .footway),
            (["highway": "path", "path": "crossing"], .crossing),
            (["highway": "cycleway", "cycleway": "crossing"], .crossing),
            (["highway": "steps"], .steps), (["highway": "pedestrian"], .pedestrian), (["highway": "path"], .path),
            (["highway": "bridleway", "foot": "yes"], .path), (["highway": "living_street"], .livingStreet),
            (["highway": "residential"], .residential), (["highway": "service"], .service),
            (["highway": "track"], .track), (["highway": "cycleway"], .cycleway),
            (["highway": "unclassified"], .minorRoad), (["highway": "tertiary"], .minorRoad),
            (["highway": "tertiary_link"], .minorRoad), (["highway": "secondary"], .majorRoad),
            (["highway": "secondary_link"], .majorRoad), (["highway": "primary"], .majorRoad),
            (["highway": "primary_link"], .majorRoad), (["highway": "trunk", "foot": "yes"], .majorRoad),
            (["highway": "corridor"], .corridor), (["highway": "bus_stop"], .other), ([:], .other),
        ]
        for (tags, expected) in cases {
            XCTAssertEqual(WalkGraphBuilder.wayClass(for: tags), expected, "\(tags)")
        }
    }

    func testCoveredUnderpassAndBridgeFlags() {
        let covered: [([String: String], Bool)] = [
            (["highway": "footway", "covered": "yes"], true), (["highway": "footway", "covered": "arcade"], true),
            (["highway": "footway", "covered": "colonnade"], true), (["highway": "footway", "covered": "no"], false),
            (["highway": "footway", "covered": "partial"], false),
            (["highway": "footway", "tunnel": "building_passage"], true),
            (["highway": "residential", "tunnel": "yes"], true), (["highway": "footway", "tunnel": "no"], false),
            (["highway": "footway", "indoor": "yes"], true), (["highway": "footway", "indoor": "no"], false),
            (["highway": "corridor"], true), (["highway": "footway"], false),
        ]
        for (tags, expected) in covered {
            XCTAssertEqual(WalkGraphBuilder.isCovered(tags), expected, "covered \(tags)")
        }
        let underpass: [([String: String], Bool)] = [
            (["highway": "footway", "tunnel": "yes"], true), (["highway": "steps", "tunnel": "yes"], true),
            (["highway": "path", "tunnel": "yes"], true),
            (["highway": "footway", "footway": "sidewalk", "tunnel": "yes"], true),
            (["highway": "footway", "tunnel": "building_passage"], false),
            (["highway": "footway", "tunnel": "building_passage", "layer": "-1"], true),
            (["highway": "residential", "tunnel": "yes"], false),
            (["highway": "residential", "tunnel": "yes", "layer": "-1"], true),
            (["highway": "footway", "layer": "-1"], false), (["highway": "footway", "tunnel": "no"], false),
            (["highway": "footway"], false),
        ]
        for (tags, expected) in underpass {
            XCTAssertEqual(WalkGraphBuilder.isUnderpass(tags), expected, "underpass \(tags)")
        }
        XCTAssertTrue(WalkGraphBuilder.isBridge(["bridge": "yes"]))
        XCTAssertTrue(WalkGraphBuilder.isBridge(["bridge": "viaduct"]))
        XCTAssertFalse(WalkGraphBuilder.isBridge(["bridge": "no"]))
        XCTAssertFalse(WalkGraphBuilder.isBridge([:]))
    }

    func testNodeFlags() {
        func flags(_ tags: [String: String]) -> [Bool] {
            let f = WalkGraphBuilder.nodeFlags(tags)
            return [f.isCrossing, f.hasTrafficSignals]
        }
        XCTAssertEqual(flags(["highway": "crossing"]), [true, false])
        XCTAssertEqual(flags(["crossing": "marked"]), [true, false])
        XCTAssertEqual(flags(["highway": "crossing", "crossing": "traffic_signals"]), [true, true])
        XCTAssertEqual(flags(["highway": "crossing", "crossing:signals": "yes"]), [true, true])
        XCTAssertEqual(flags(["highway": "traffic_signals"]), [false, true])
        XCTAssertEqual(flags(["highway": "crossing", "crossing": "no"]), [false, false])
        XCTAssertEqual(flags(["highway": "street_lamp"]), [false, false])
    }

    // MARK: Topology

    func testSplitsAtSharedNodesAndEndpoints() throws {
        // A straight street 1-2-3-4 with a side path 3-5; node 2 is only a shape point.
        let elements = [
            way(10, [(1, 0, 0), (2, 20, 0), (3, 40, 0), (4, 80, 0)], ["highway": "residential", "name": "Main St"]),
            way(11, [(3, 40, 0), (5, 40, 30)], ["highway": "steps"]),
        ]
        let g = WalkGraphBuilder.build(from: elements)
        Self.assertValidGraph(g)
        XCTAssertEqual(g.nodes.map(\.osmID), [1, 3, 4, 5])
        XCTAssertEqual(g.edges.count, 3)
        let first = g.edges[0]
        XCTAssertEqual([first.from, first.to].map { g.nodes[$0].osmID }, [1, 3])
        XCTAssertEqual(first.geometry, [pt(0, 0), pt(20, 0), pt(40, 0)], "intermediate geometry kept")
        XCTAssertEqual(first.length, 40, accuracy: 0.05)
        XCTAssertEqual(first.wayClass, .residential)
        XCTAssertEqual(first.name, "Main St")
        XCTAssertEqual(first.wayID, 10)
        XCTAssertEqual(g.edges[2].wayClass, .steps)
        XCTAssertTrue(g.edges[2].isSteps)
        XCTAssertEqual(g.neighbors(of: 1).count, 3)
    }

    func testCrossingNodesAndEdgesAreFlagged() throws {
        let elements = [
            way(10, [(1, 0, 0), (2, 20, 0), (3, 40, 0)], ["highway": "tertiary"]),
            way(11, [(4, 20, -10), (2, 20, 0), (5, 20, 10)], ["highway": "footway", "footway": "crossing"]),
            node(2, 20, 0, ["highway": "crossing", "crossing": "traffic_signals"]),
            node(3, 40, 0, ["highway": "traffic_signals"]),
            node(4, 20, -10, ["barrier": "kerb"]),
        ]
        let g = WalkGraphBuilder.build(from: elements)
        Self.assertValidGraph(g)
        let byOSM = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.osmID, $0) })
        XCTAssertEqual(byOSM[2]?.isCrossing, true)
        XCTAssertEqual(byOSM[2]?.hasTrafficSignals, true)
        XCTAssertEqual(byOSM[3]?.isCrossing, false)
        XCTAssertEqual(byOSM[3]?.hasTrafficSignals, true)
        XCTAssertEqual(byOSM[4]?.isCrossing, false)
        let crossingEdges = g.edges.filter(\.isCrossing)
        XCTAssertEqual(crossingEdges.count, 2)
        XCTAssertTrue(crossingEdges.allSatisfy { $0.wayClass == .crossing && $0.wayID == 11 })
    }

    func testNullGeometrySplitsWayIntoPieces() {
        let piecewise = OSMElement(type: .way, id: 10, tags: ["highway": "footway"], nodes: [1, 2, 3, 4, 5],
                                   geometry: [pt(0, 0), pt(20, 0), nil, pt(60, 0), pt(80, 0)])
        let link = way(11, [(2, 20, 0), (6, 40, 20), (4, 60, 0)])
        let g = WalkGraphBuilder.build(from: [piecewise, link])
        Self.assertValidGraph(g)
        XCTAssertEqual(Set(g.nodes.map(\.osmID)), [1, 2, 4, 5])
        XCTAssertEqual(g.edges.count, 3)
        XCTAssertFalse(g.edges.contains { $0.wayID == 10 && $0.length > 25 }, "no edge spans the unknown vertex")
    }

    func testWaysWithMismatchedOrMissingGeometry() {
        let base = way(10, [(1, 0, 0), (2, 50, 0)])
        let mismatched = OSMElement(type: .way, id: 11, tags: ["highway": "footway"], nodes: [2, 3, 4],
                                    geometry: [pt(50, 0), pt(50, 50)])
        let noNodes = OSMElement(type: .way, id: 12, tags: ["highway": "footway"], geometry: [pt(0, 0), pt(0, 50)])
        var g = WalkGraphBuilder.build(from: [base, mismatched, noNodes])
        XCTAssertEqual(g.nodes.map(\.osmID), [1, 2])
        XCTAssertEqual(g.edges.map(\.wayID), [10])

        // Without inline geometry the node positions are used.
        let byNodes = OSMElement(type: .way, id: 13, tags: ["highway": "footway"], nodes: [2, 7])
        g = WalkGraphBuilder.build(from: [base, byNodes, node(2, 50, 0, [:]), node(7, 50, 40, [:])])
        Self.assertValidGraph(g)
        XCTAssertEqual(g.nodes.map(\.osmID), [1, 2, 7])
        XCTAssertEqual(g.edges[1].length, 40, accuracy: 0.05)
    }

    func testShortEdgesAreContractedNotDisconnected() throws {
        // 1 ── 2 is 0.3 m long; 2 ── 3 and 1 ── 4 are normal.
        let elements = [
            way(10, [(1, 0, 0), (2, 0.3, 0)]),
            way(11, [(2, 0.3, 0), (3, 50, 0)]),
            way(12, [(1, 0, 0), (4, 0, -40)]),
            way(13, [(5, 30, 30), (6, 30, 30.2)], ["highway": "footway", "footway": "crossing"]),
            way(14, [(6, 30, 30.2), (3, 50, 0)]),
            node(2, 0.3, 0, ["highway": "crossing"]),
        ]
        let g = WalkGraphBuilder.build(from: elements)
        Self.assertValidGraph(g)
        XCTAssertEqual(g.nodes.map(\.osmID), [1, 3, 4, 5])
        XCTAssertEqual(g.edges.map(\.wayID), [11, 12, 14])
        XCTAssertTrue(g.edges.allSatisfy { $0.length >= WalkGraphBuilder.minimumEdgeLength })
        let merged = try XCTUnwrap(g.nodes.first { $0.osmID == 1 })
        XCTAssertTrue(merged.isCrossing, "flags of merged nodes are kept")
        XCTAssertEqual(g.edges[0].geometry.first, merged.coordinate, "geometry snapped to the merged node")
        XCTAssertEqual(g.edges[0].length, GeoMath.length(of: g.edges[0].geometry), accuracy: 1e-9)
        XCTAssertEqual(g.nodes.first { $0.osmID == 5 }?.isCrossing, true, "contracted crossing edge marks its node")
    }

    func testContractionRepeatsUntilNoShortEdgeRemains() {
        // 1 ── 2 (0.3 m) is contracted into 1, which shortens 2 ── 3 (0.55 m) to 1 ── 3 (0.25 m): contract it too.
        let elements = [
            way(10, [(1, 0, 0), (2, -0.3, 0)]),
            way(11, [(2, -0.3, 0), (3, 0.25, 0)]),
            way(12, [(3, 0.25, 0), (4, 0.25, 30)]),
            way(13, [(1, 0, 0), (5, 0, -30)]),
        ]
        let g = WalkGraphBuilder.build(from: elements)
        Self.assertValidGraph(g)
        XCTAssertEqual(g.nodes.map(\.osmID), [1, 4, 5])
        XCTAssertEqual(g.edges.map(\.wayID), [12, 13])
    }

    func testLoopCreatedByContractionIsSplitAtShapePoint() throws {
        // 1 ── 2 is 0.3 m; way 11 leaves 2 and returns to 1 via shape point 3, so contraction turns it into a loop.
        let elements = [
            way(10, [(1, 0, 0), (2, 0.3, 0)]),
            way(11, [(2, 0.3, 0), (3, 10, 15), (1, 0, 0)]),
            way(12, [(1, 0, 0), (4, 0, -40)]),
            node(3, 10, 15, ["highway": "crossing"]),
        ]
        let g = WalkGraphBuilder.build(from: elements)
        Self.assertValidGraph(g)
        XCTAssertEqual(g.nodes.map(\.osmID), [1, 4, 3])
        XCTAssertEqual(g.edges.map(\.wayID), [11, 11, 12])
        XCTAssertEqual(g.nodes[2].isCrossing, true, "split node keeps its tags")
        XCTAssertEqual(g.edges[0].length + g.edges[1].length, 2 * 18.03, accuracy: 0.05)
    }

    func testKeepsLargestConnectedComponentOnly() {
        let elements = [
            way(10, [(1, 0, 0), (2, 50, 0), (3, 100, 0)], ["highway": "residential"]),
            way(11, [(3, 100, 0), (4, 100, 50)]),
            way(20, [(100, 500, 500), (101, 600, 500)]),
            way(21, [(200, -500, 0), (201, -500, 900)]),
        ]
        let g = WalkGraphBuilder.build(from: elements)
        Self.assertValidGraph(g)
        XCTAssertEqual(g.nodes.map(\.osmID), [1, 3, 4])
        XCTAssertEqual(g.nodes.map(\.id), [0, 1, 2])
        XCTAssertEqual(g.edges.map(\.id), [0, 1])
        XCTAssertEqual(Self.componentCount(g), 1)

        // Equal node counts: the longer component wins.
        let tie = WalkGraphBuilder.build(from: [way(1, [(1, 0, 0), (2, 10, 0)]), way(2, [(3, 0, 50), (4, 90, 50)])])
        XCTAssertEqual(tie.nodes.map(\.osmID), [3, 4])
    }

    func testClosedLoopIsSplitInsteadOfSelfLoop() {
        let elements = [
            way(10, [(1, 0, 0), (2, 20, 0), (3, 20, 20), (4, 0, 20), (1, 0, 0)]),
            way(11, [(1, 0, 0), (5, -30, 0)]),
        ]
        let g = WalkGraphBuilder.build(from: elements)
        Self.assertValidGraph(g)
        XCTAssertFalse(g.edges.contains { $0.from == $0.to })
        XCTAssertEqual(g.edges.filter { $0.wayID == 10 }.count, 2)
        XCTAssertEqual(g.edges.filter { $0.wayID == 10 }.reduce(0) { $0 + $1.length }, 80, accuracy: 0.1)
    }

    func testFiltersAndDeduplicatesWays() {
        let street = way(10, [(1, 0, 0), (2, 50, 0)], ["highway": "residential"])
        let elements = [
            street, street,
            way(11, [(2, 50, 0), (3, 100, 0)], ["highway": "motorway"]),
            way(12, [(2, 50, 0), (4, 50, 50)], ["highway": "service", "access": "private"]),
            way(13, [(1, 0, 0), (5, 0, 50)], ["building": "yes"]),
            OSMElement(type: .relation, id: 10, tags: ["highway": "pedestrian"]),
        ]
        let g = WalkGraphBuilder.build(from: elements)
        XCTAssertEqual(g.nodes.map(\.osmID), [1, 2])
        XCTAssertEqual(g.edges.count, 1)
        XCTAssertTrue(WalkGraphBuilder.build(from: []).isEmpty)
        XCTAssertTrue(WalkGraphBuilder.build(from: Array(elements.dropFirst(2))).isEmpty)
        XCTAssertTrue(WalkGraphBuilder.build(from: [way(1, [(1, 0, 0), (2, 0.2, 0)])]).isEmpty, "only a tiny edge")
    }

    func testBuildIsIndependentOfElementOrder() throws {
        let elements = try OSMAreaParser.decodeElements(OSMTestFixtures.data("synthetic_block"))
        let reference = WalkGraphBuilder.build(from: elements)
        var rng = OSMSeededGenerator(seed: 42)
        for _ in 0..<5 {
            let shuffled = WalkGraphBuilder.build(from: elements.shuffled(using: &rng))
            XCTAssertEqual(shuffled.nodes, reference.nodes)
            XCTAssertEqual(shuffled.edges, reference.edges)
        }
    }

    // MARK: Fixtures

    func testSyntheticFixtureGraph() throws {
        let area = try OSMAreaParser.parse(OSMTestFixtures.data("synthetic_block"), bbox: OSMTestFixtures.syntheticBBox,
                                           fetchedAt: Date())
        let g = area.graph
        Self.assertValidGraph(g)
        XCTAssertEqual(Self.componentCount(g), 1)
        XCTAssertEqual(g.nodes.count, 23)
        XCTAssertEqual(g.edges.count, 31)
        let osmIDs = Set(g.nodes.map(\.osmID))
        let wayIDs = Set(g.edges.map(\.wayID))
        // Excluded: motorway, private service, foot=no cycleway, area, access=no, length mismatch,
        // the disconnected fragment, shape points, nodes outside the bbox, the contracted node.
        for id: Int64 in [501, 502, 701, 702, 703, 711, 712, 713, 730, 731, 801, 802, 803, 901, 902, 602, 720] {
            XCTAssertFalse(osmIDs.contains(id), "node \(id)")
        }
        for id: Int64 in [1040, 1060, 1061, 1062, 1063, 1070, 1071, 1080, 1090] {
            XCTAssertFalse(wayIDs.contains(id), "way \(id)")
        }
        for id: Int64 in [1001, 1002, 1008, 1010, 1011, 1020, 1021, 1030, 1050, 1064, 1081] {
            XCTAssertTrue(wayIDs.contains(id), "way \(id)")
        }
        func edges(_ wayID: Int64) -> [GraphEdge] { g.edges.filter { $0.wayID == wayID } }
        XCTAssertTrue(edges(1011).allSatisfy { $0.isCrossing && $0.wayClass == .crossing })
        XCTAssertEqual(edges(1011).count, 2)
        XCTAssertTrue(edges(1010).allSatisfy { $0.wayClass == .sidewalk })
        XCTAssertEqual(edges(1020).first?.wayClass, .steps)
        XCTAssertEqual(edges(1021).first?.isBridge, true)
        XCTAssertEqual(edges(1030).first?.isUnderpass, true)
        XCTAssertEqual(edges(1030).first?.isCovered, true)
        let arcade = try XCTUnwrap(edges(1050).first)
        XCTAssertTrue(arcade.isCovered)
        XCTAssertFalse(arcade.isUnderpass)
        XCTAssertEqual(arcade.name, "Market Arcade")
        XCTAssertEqual(arcade.geometry.count, 3)
        XCTAssertEqual(edges(1002).map(\.wayClass), [.minorRoad, .minorRoad, .minorRoad])
        XCTAssertEqual(edges(1004).first?.wayClass, .majorRoad)
        XCTAssertEqual(edges(1005).first?.wayClass, .livingStreet)
        XCTAssertEqual(edges(1006).first?.wayClass, .service)
        XCTAssertEqual(edges(1064).first?.wayClass, .path)
        XCTAssertEqual(edges(1008).count, 1, "only the known part of a way leaving the bbox")
        let byOSM = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.osmID, $0) })
        XCTAssertEqual(byOSM[301]?.isCrossing, true)
        XCTAssertEqual(byOSM[301]?.hasTrafficSignals, true)
        XCTAssertEqual(byOSM[105]?.isCrossing, false)
        XCTAssertEqual(byOSM[105]?.hasTrafficSignals, true)
        // 1080 (0.3 m) was contracted: 1081 now starts at node 109.
        let link = try XCTUnwrap(edges(1081).first)
        let n109 = try XCTUnwrap(byOSM[109])
        XCTAssertTrue([link.from, link.to].contains(n109.id))
        XCTAssertNotNil(byOSM[721])
    }

    // MARK: Helpers

    /// Structural invariants every built graph must satisfy.
    static func assertValidGraph(_ g: WalkGraph, file: StaticString = #filePath, line: UInt = #line) {
        for (i, n) in g.nodes.enumerated() {
            XCTAssertEqual(n.id, i, "dense node ids", file: file, line: line)
        }
        XCTAssertEqual(Set(g.nodes.map(\.osmID)).count, g.nodes.count, "unique OSM nodes", file: file, line: line)
        for (i, e) in g.edges.enumerated() {
            XCTAssertEqual(e.id, i, "dense edge ids", file: file, line: line)
            guard g.nodes.indices.contains(e.from), g.nodes.indices.contains(e.to) else {
                return XCTFail("edge \(i) endpoints out of range", file: file, line: line)
            }
            XCTAssertGreaterThanOrEqual(e.geometry.count, 2, file: file, line: line)
            XCTAssertEqual(e.geometry.first, g.nodes[e.from].coordinate, "edge \(i) start", file: file, line: line)
            XCTAssertEqual(e.geometry.last, g.nodes[e.to].coordinate, "edge \(i) end", file: file, line: line)
            XCTAssertEqual(e.length, GeoMath.length(of: e.geometry), accuracy: 1e-6, file: file, line: line)
            XCTAssertGreaterThanOrEqual(e.length, WalkGraphBuilder.minimumEdgeLength, file: file, line: line)
            XCTAssertNotEqual(e.from, e.to, "edge \(i) is a self-loop", file: file, line: line)
        }
        for (i, adjacent) in g.adjacency.enumerated() {
            XCTAssertFalse(adjacent.isEmpty, "node \(i) has no edges", file: file, line: line)
        }
    }

    /// Number of connected components.
    static func componentCount(_ g: WalkGraph) -> Int {
        var seen = Array(repeating: false, count: g.nodes.count)
        var count = 0
        for start in g.nodes.indices where !seen[start] {
            count += 1
            var stack = [start]
            seen[start] = true
            while let n = stack.popLast() {
                for (_, next) in g.neighbors(of: n) where !seen[next] {
                    seen[next] = true
                    stack.append(next)
                }
            }
        }
        return count
    }
}

/// Deterministic SplitMix64 generator for reproducible shuffles.
struct OSMSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
