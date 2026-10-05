import XCTest
@testable import ShadeCore

/// Loads JSON fixtures bundled with the test target.
enum OSMTestFixtures {
    static func data(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
                                "missing fixture \(name).json")
        return try Data(contentsOf: url)
    }

    static let syntheticBBox = BoundingBox(minLatitude: 37.5598, minLongitude: 126.9895,
                                           maxLatitude: 37.5630, maxLongitude: 126.9935)
    static let seoulBBox = BoundingBox(minLatitude: 37.5690, minLongitude: 126.9745,
                                       maxLatitude: 37.5730, maxLongitude: 126.9800)
}

final class OSMParserTests: XCTestCase {
    let origin = GeoCoordinate(latitude: 37.5716, longitude: 126.9769)
    lazy var projection = LocalProjection(origin: origin)

    /// Coordinate `x` metres east and `y` metres north of `origin`.
    func pt(_ x: Double, _ y: Double) -> GeoCoordinate { projection.unproject(Point2D(x: x, y: y)) }

    // MARK: Decoding

    func testDecodingIsLenient() throws {
        let json = """
        {"version": 0.6, "generator": "test", "osm3s": {"copyright": "x"}, "elements": [
          {"type": "node", "id": 1, "lat": 37.5, "lon": 127.0, "timestamp": "2020-01-01", "extra": [1, 2]},
          {"type": "node", "id": 2, "lat": 37.5, "tags": {"natural": "tree", "height": 12, "leaf_cycle": null, "x": true}},
          {"type": "way", "id": 10, "bounds": {"minlat": 0}, "nodes": [1, 2, 3, 4],
           "geometry": [null, {"lat": 37.5, "lon": 127.0}, {"lat": "bad"}, {"lat": 95.0, "lon": 1.0}],
           "tags": {"highway": "footway"}},
          {"type": "way", "id": 11, "nodes": "garbage", "geometry": 5, "center": {"lat": 37.6, "lon": 127.1}},
          {"type": "relation", "id": 20, "members": [
             {"type": "way", "ref": 10, "role": "outer", "geometry": [{"lat": 37.5, "lon": 127.0}, null]},
             {"type": "node", "ref": 1, "role": "label", "lat": 37.5, "lon": 127.0},
             {"type": "area", "ref": 3},
             {"type": "way", "ref": 12}
          ]},
          {"type": "area", "id": 3600000001},
          {"type": "node", "lat": 1, "lon": 2},
          {"type": "node", "id": "x"},
          42,
          null
        ]}
        """
        let elements = try OSMAreaParser.decodeElements(Data(json.utf8))
        XCTAssertEqual(elements.map(\.id), [1, 2, 10, 11, 20])
        XCTAssertEqual(elements[0].coordinate, GeoCoordinate(latitude: 37.5, longitude: 127.0))
        XCTAssertTrue(elements[0].tags.isEmpty)
        // Missing lon → no coordinate; non-string tag values stringified, nulls dropped.
        XCTAssertNil(elements[1].coordinate)
        XCTAssertEqual(elements[1].tags, ["natural": "tree", "height": "12", "x": "yes"])
        // Null, malformed and out-of-range geometry entries become nil but keep their index.
        let way = elements[2]
        XCTAssertEqual(way.nodes, [1, 2, 3, 4])
        XCTAssertEqual(way.geometry?.count, 4)
        XCTAssertEqual(way.geometry?.compactMap { $0 }, [GeoCoordinate(latitude: 37.5, longitude: 127.0)])
        XCTAssertNil(elements[3].nodes)
        XCTAssertNil(elements[3].geometry)
        XCTAssertEqual(elements[3].center, GeoCoordinate(latitude: 37.6, longitude: 127.1))
        let members = try XCTUnwrap(elements[4].members)
        XCTAssertEqual(members.map(\.ref), [10, 1, 12])
        XCTAssertEqual(members[0].role, "outer")
        XCTAssertEqual(members[0].geometry?.count, 2)
        XCTAssertEqual(members[1].coordinate, GeoCoordinate(latitude: 37.5, longitude: 127.0))
        XCTAssertEqual(members[2].role, "")
        XCTAssertNil(members[2].geometry)
    }

    func testInvalidPayloadsThrowDecodingFailed() {
        let payloads = ["", "not json", "<html><body>504 Gateway Timeout</body></html>", "[]", "{}", "{\"elements\": 5}",
                        "{\"elements\": [], \"remark\": \"runtime error: Query timed out in \\\"query\\\" at line 3\"}"]
        for payload in payloads {
            XCTAssertThrowsError(try OSMAreaParser.decodeElements(Data(payload.utf8)), payload) { error in
                guard case ShadeError.decodingFailed = error else { return XCTFail("unexpected \(error)") }
            }
            XCTAssertThrowsError(try OSMAreaParser.parse(Data(payload.utf8), bbox: OSMTestFixtures.syntheticBBox,
                                                         fetchedAt: Date()))
            XCTAssertThrowsError(try OSMAreaParser.parseCoolSpots(Data(payload.utf8)))
        }
    }

    func testEmptyResponseParsesToEmptyAreaData() throws {
        let json = "{\"elements\": [], \"remark\": \"runtime remark: nothing to report\"}"
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let area = try OSMAreaParser.parse(Data(json.utf8), bbox: OSMTestFixtures.syntheticBBox, fetchedAt: date)
        XCTAssertTrue(area.graph.isEmpty)
        XCTAssertTrue(area.buildings.isEmpty && area.trees.isEmpty && area.canopies.isEmpty && area.coolSpots.isEmpty)
        XCTAssertEqual(area.bbox, OSMTestFixtures.syntheticBBox)
        XCTAssertEqual(area.fetchedAt, date)
    }

    func testDuplicatesMergeByTypeAndIDKeepingGeometry() throws {
        let json = """
        {"elements": [
          {"type": "way", "id": 7, "center": {"lat": 37.57, "lon": 126.97}, "nodes": [1, 2, 3, 1],
           "tags": {"amenity": "library", "name": "Library"}},
          {"type": "node", "id": 7, "lat": 37.0, "lon": 127.0},
          {"type": "way", "id": 7, "nodes": [1, 2, 3, 1],
           "geometry": [{"lat": 37.570, "lon": 126.970}, {"lat": 37.570, "lon": 126.971},
                        {"lat": 37.571, "lon": 126.971}, {"lat": 37.570, "lon": 126.970}],
           "tags": {"building": "yes", "name": "Ignored duplicate name"}}
        ]}
        """
        let elements = try OSMAreaParser.decodeElements(Data(json.utf8))
        XCTAssertEqual(elements.map(\.type), [.node, .way])
        let way = elements[1]
        XCTAssertEqual(way.geometry?.count, 4)
        XCTAssertEqual(way.center, GeoCoordinate(latitude: 37.57, longitude: 126.97))
        XCTAssertEqual(way.tags, ["amenity": "library", "name": "Library", "building": "yes"])

        // Geometry with more known vertices wins; existing members with geometry are kept.
        var a = OSMElement(type: .way, id: 1, geometry: [nil, pt(0, 0), nil])
        a.merge(OSMElement(type: .way, id: 1, geometry: [pt(1, 1), pt(0, 0), pt(2, 2)]))
        XCTAssertEqual(a.geometry?.compactMap { $0 }.count, 3)
        var r = OSMElement(type: .relation, id: 2, members: [OSMMember(type: .way, ref: 5)])
        r.merge(OSMElement(type: .relation, id: 2, members: [OSMMember(type: .way, ref: 5, geometry: [pt(0, 0)])]))
        XCTAssertNotNil(r.members?.first?.geometry)
    }

    func testElementEncodingRoundTrips() throws {
        let elements = [
            OSMElement(type: .node, id: 1, coordinate: pt(1, 2), tags: ["natural": "tree"]),
            OSMElement(type: .way, id: 2, tags: ["highway": "footway"], nodes: [1, 3],
                       geometry: [pt(1, 2), nil], center: pt(0, 0)),
            OSMElement(type: .relation, id: 3, members: [
                OSMMember(type: .way, ref: 2, role: "outer", geometry: [pt(0, 0), nil, pt(5, 5)]),
                OSMMember(type: .node, ref: 1, role: "label", coordinate: pt(1, 2)),
            ]),
        ]
        let data = try JSONEncoder().encode(["elements": elements])
        XCTAssertEqual(try OSMAreaParser.decodeElements(data), elements)
    }

    // MARK: Values & heights

    func testLengthParsing() {
        let cases: [(String?, Double?)] = [
            ("12", 12), ("12 m", 12), ("12m", 12), ("12.5m", 12.5), ("12,5", 12.5), (" 7 ", 7), ("12 metres", 12),
            ("40'", 12.192), ("40 ft", 12.192), ("40ft", 12.192), ("40 feet", 12.192), ("12'6\"", 3.81),
            ("12' 6\"", 3.81), ("15;20", 15), ("350 cm", 3.5), (".5", 0.5), ("0", 0),
            (nil, nil), ("", nil), (" ", nil), ("abc", nil), ("-3", nil), ("12 storeys", nil), ("~10", nil),
            ("12'x", nil), (";12", nil),
        ]
        for (raw, expected) in cases {
            let parsed = OSMValueParser.length(raw)
            if let expected {
                XCTAssertEqual(parsed ?? -1, expected, accuracy: 1e-9, "\(raw ?? "nil")")
            } else {
                XCTAssertNil(parsed, "\(raw ?? "nil")")
            }
        }
    }

    func testNumberParsing() {
        XCTAssertEqual(OSMValueParser.number("3"), 3)
        XCTAssertEqual(OSMValueParser.number("3.5"), 3.5)
        XCTAssertEqual(OSMValueParser.number("2,5"), 2.5)
        XCTAssertEqual(OSMValueParser.number("-1"), -1)
        XCTAssertEqual(OSMValueParser.number("4;5"), 4)
        XCTAssertEqual(OSMValueParser.number("6 floors"), 6)
        XCTAssertNil(OSMValueParser.number("x"))
        XCTAssertNil(OSMValueParser.number("-"))
        XCTAssertNil(OSMValueParser.number(nil))
    }

    func testBuildingHeightsFromTags() {
        func h(_ tags: [String: String]) -> OSMBuildingHeights { OSMBuildingHeights(tags: tags) }
        XCTAssertEqual(h(["building": "yes", "height": "21.5"]).height, 21.5)
        XCTAssertEqual(h(["building": "yes", "height": "21", "building:levels": "10"]).height, 21, "height wins")
        XCTAssertEqual(h(["building": "yes", "building:levels": "4", "roof:levels": "1"]).height, 14.3, accuracy: 1e-9)
        XCTAssertEqual(h(["building": "yes", "building:levels": "5"]).height, 16, accuracy: 1e-9)
        XCTAssertEqual(h(["building": "yes", "building:levels": "x"]).height, 9, "unparseable levels → default")
        XCTAssertEqual(h(["building": "yes", "building:levels": "0"]).height, 9)
        XCTAssertEqual(h(["building": "yes", "height": "0"]).height, 9, "zero height → fallback")
        let defaults: [String: Double] = [
            "house": 7, "detached": 7, "residential": 7, "terrace": 7, "apartments": 18, "commercial": 14,
            "office": 14, "retail": 14, "hotel": 14, "garage": 3, "garages": 3, "shed": 3, "kiosk": 3, "hut": 3,
            "yes": 9, "church": 9, "school": 9,
        ]
        for (type, expected) in defaults {
            XCTAssertEqual(h(["building": type]).height, expected, type)
            XCTAssertEqual(h(["building": type]).minHeight, 0, type)
            XCTAssertFalse(h(["building": type]).isRoofOnly, type)
        }
        XCTAssertEqual(OSMBuildingHeights.defaultHeight(forBuildingType: "roof"), 4)
        XCTAssertEqual(OSMBuildingHeights.defaultHeight(forBuildingType: "carport"), 3)
        // Clamping.
        XCTAssertEqual(h(["building": "yes", "height": "1000"]).height, 500)
        XCTAssertEqual(h(["building": "yes", "height": "0.5"]).height, 2)
        // Min height.
        XCTAssertEqual(h(["building": "yes", "height": "10", "min_height": "3"]).minHeight, 3)
        XCTAssertEqual(h(["building": "yes", "building:levels": "5", "building:min_level": "2"]).minHeight, 6.4,
                       accuracy: 1e-9)
        XCTAssertEqual(h(["building": "yes", "height": "10", "min_height": "12"]).minHeight, 9.5, "kept below height")
    }

    func testRoofOnlyStructures() {
        for tags in [["building": "roof"], ["building": "carport"], ["building": "canopy"],
                     ["building": "yes", "walls": "no"]] {
            let h = OSMBuildingHeights(tags: tags)
            XCTAssertTrue(h.isRoofOnly, "\(tags)")
            XCTAssertEqual(h.height, 4, "\(tags)")
            XCTAssertEqual(h.minHeight, 2.5, "\(tags)")
        }
        let tagged = OSMBuildingHeights(tags: ["building": "roof", "height": "6", "min_height": "4.5"])
        XCTAssertEqual(tagged.height, 6)
        XCTAssertEqual(tagged.minHeight, 4.5)
        let low = OSMBuildingHeights(tags: ["building": "roof", "height": "2.2"])
        XCTAssertEqual(low.height, 2.2, accuracy: 1e-9)
        XCTAssertEqual(low.minHeight, 1.7, accuracy: 1e-9, "default min height stays below the roof")
    }

    // MARK: Rings

    func testOpenRingNormalisation() throws {
        let a = pt(0, 0), b = pt(10, 0), c = pt(10, 10), d = pt(0, 10)
        XCTAssertEqual(MultipolygonAssembler.openRing([a, b, c, d, a]), [a, b, c, d])
        XCTAssertEqual(MultipolygonAssembler.openRing([a, a, b, b, c, a, a]), [a, b, c])
        XCTAssertEqual(MultipolygonAssembler.openRing([a, b, c]), [a, b, c])
        XCTAssertNil(MultipolygonAssembler.openRing([a, b, a]))
        XCTAssertNil(MultipolygonAssembler.openRing([a, b, a, b, a]), "only 2 distinct vertices")
        XCTAssertNil(MultipolygonAssembler.openRing([]))
    }

    func testRingOfWay() {
        let a = pt(0, 0), b = pt(10, 0), c = pt(10, 10), d = pt(0, 10)
        let closed = OSMElement(type: .way, id: 1, nodes: [1, 2, 3, 4, 1], geometry: [a, b, c, d, a])
        XCTAssertEqual(MultipolygonAssembler.ring(ofWay: closed), [a, b, c, d])
        let withNull = OSMElement(type: .way, id: 1, nodes: [1, 2, 3, 4, 1], geometry: [a, b, nil, d, a])
        XCTAssertEqual(MultipolygonAssembler.ring(ofWay: withNull), [a, b, d])
        let open = OSMElement(type: .way, id: 1, nodes: [1, 2, 3, 4], geometry: [a, b, c, d])
        XCTAssertNil(MultipolygonAssembler.ring(ofWay: open))
        let noIDs = OSMElement(type: .way, id: 1, geometry: [a, b, c, a])
        XCTAssertEqual(MultipolygonAssembler.ring(ofWay: noIDs), [a, b, c])
        XCTAssertNil(MultipolygonAssembler.ring(ofWay: OSMElement(type: .way, id: 1)))
        // No inline geometry: node positions are used.
        let byNodes = OSMElement(type: .way, id: 1, nodes: [1, 2, 3, 1])
        XCTAssertEqual(MultipolygonAssembler.ring(ofWay: byNodes, nodeCoordinates: [1: a, 2: b, 3: c]), [a, b, c])
    }

    func testAssembleRingsJoinsPiecesEndToEnd() {
        let a = pt(0, 0), b = pt(20, 0), c = pt(20, 20), d = pt(0, 20), e = pt(10, 30)
        // Second piece runs the "wrong" way and must be reversed.
        XCTAssertEqual(MultipolygonAssembler.assembleRings([[a, b, c], [a, d, c]]), [[a, b, c, d]])
        // Three pieces in scrambled order and orientation.
        XCTAssertEqual(MultipolygonAssembler.assembleRings([[c, e, d], [a, b], [c, b], [d, a]]), [[c, e, d, a, b]])
        // Already-closed piece plus an unclosable piece.
        let far1 = pt(100, 100), far2 = pt(120, 100)
        XCTAssertEqual(MultipolygonAssembler.assembleRings([[a, b, c, a], [far1, far2]]), [[a, b, c]])
        XCTAssertTrue(MultipolygonAssembler.assembleRings([[a, b], [b, c]]).isEmpty)
        XCTAssertTrue(MultipolygonAssembler.assembleRings([[a], []]).isEmpty)
    }

    func testMultipolygonBuildingsUseOuterRingsOnly() throws {
        let a = pt(0, 0), b = pt(20, 0), c = pt(20, 20), d = pt(0, 20)
        let i1 = pt(5, 5), i2 = pt(10, 5), i3 = pt(10, 10)
        let rel = OSMElement(type: .relation, id: 77, tags: ["type": "multipolygon", "building": "office"], members: [
            OSMMember(type: .way, ref: 1, role: "outer", geometry: [a, b, c]),
            OSMMember(type: .way, ref: 2, role: "inner", geometry: [i1, i2, i3, i1]),
            OSMMember(type: .way, ref: 3, role: "", geometry: [c, nil, d, a]),
            OSMMember(type: .node, ref: 4, role: "entrance", coordinate: a),
        ])
        let buildings = OSMAreaParser.buildings(from: [rel])
        XCTAssertEqual(buildings.count, 1)
        XCTAssertEqual(buildings[0].footprint, [a, b, c, d])
        XCTAssertEqual(buildings[0].id, -(77 << 12))
        XCTAssertEqual(buildings[0].height, 14)

        let two = OSMElement(type: .relation, id: 78, tags: ["type": "multipolygon", "building": "yes"], members: [
            OSMMember(type: .way, ref: 1, role: "outer", geometry: [a, b, c, a]),
            OSMMember(type: .way, ref: 2, role: "outer", geometry: [pt(50, 50), pt(60, 50), pt(60, 60), pt(50, 50)]),
        ])
        XCTAssertEqual(OSMAreaParser.buildings(from: [two]).map(\.id), [-(78 << 12), -(78 << 12 | 1)])
        // Not a multipolygon, or members without geometry: nothing.
        var notMP = two
        notMP.tags["type"] = "building"
        XCTAssertTrue(OSMAreaParser.buildings(from: [notMP]).isEmpty)
        let noGeometry = OSMElement(type: .relation, id: 79, tags: ["type": "multipolygon", "building": "yes"],
                                    members: [OSMMember(type: .way, ref: 1, role: "outer")])
        XCTAssertTrue(OSMAreaParser.buildings(from: [noGeometry]).isEmpty)
    }

    func testBuildingsSkipNonBuildings() {
        let ring: [GeoCoordinate?] = [pt(0, 0), pt(10, 0), pt(10, 10), pt(0, 0)]
        let ids: [Int64] = [1, 2, 3, 1]
        let elements = [
            OSMElement(type: .way, id: 1, tags: ["building": "no"], nodes: ids, geometry: ring),
            OSMElement(type: .way, id: 2, tags: ["building": "proposed"], nodes: ids, geometry: ring),
            OSMElement(type: .way, id: 3, tags: ["amenity": "parking"], nodes: ids, geometry: ring),
            OSMElement(type: .node, id: 4, coordinate: pt(0, 0), tags: ["building": "yes"]),
            OSMElement(type: .way, id: 5, tags: ["building": "yes"], nodes: ids, geometry: ring),
        ]
        XCTAssertEqual(OSMAreaParser.buildings(from: elements).map(\.id), [5])
    }

    // MARK: Trees & canopy

    func testTreeAttributes() {
        func tree(_ tags: [String: String]) -> Tree? {
            OSMAreaParser.trees(from: [OSMElement(type: .node, id: 9, coordinate: pt(0, 0),
                                                  tags: tags.merging(["natural": "tree"]) { a, _ in a })]).first
        }
        XCTAssertEqual(tree([:])?.height, 8)
        XCTAssertEqual(tree([:])?.crownRadius, 4)
        XCTAssertEqual(tree(["height": "10", "diameter_crown": "6"])?.height, 10)
        XCTAssertEqual(tree(["height": "10", "diameter_crown": "6"])?.crownRadius, 3)
        XCTAssertEqual(tree(["diameter_crown": "9 m"])?.crownRadius, 4.5)
        XCTAssertEqual(tree(["circumference": "1.2"])?.crownRadius ?? 0, 12.5 * 1.2 / .pi, accuracy: 1e-9)
        XCTAssertEqual(tree(["circumference": "120"])?.crownRadius ?? 0, 12.5 * 1.2 / .pi, accuracy: 1e-9, "cm")
        XCTAssertEqual(tree(["circumference": "0.1"])?.crownRadius, 1, "clamped")
        XCTAssertEqual(tree(["diameter_crown": "100"])?.crownRadius, 20, "clamped")
        XCTAssertEqual(tree(["height": "300"])?.height, 60, "clamped")
        XCTAssertEqual(tree(["height": "tall"])?.height, 8)
        XCTAssertNil(OSMAreaParser.trees(from: [OSMElement(type: .node, id: 1, tags: ["natural": "tree"])]).first,
                     "no position")
        XCTAssertTrue(OSMAreaParser.trees(from: [OSMElement(type: .node, id: 1, coordinate: pt(0, 0),
                                                            tags: ["natural": "scrub"])]).isEmpty)
    }

    func testTreeRowSamplesEveryEightMetres() throws {
        let row = OSMElement(type: .way, id: 300, tags: ["natural": "tree_row", "height": "6"], nodes: [1, 2],
                             geometry: [pt(0, 0), pt(41, 0)])
        let trees = OSMAreaParser.trees(from: [row])
        XCTAssertEqual(trees.count, 7) // ceil(41 / 8) = 6 intervals
        XCTAssertEqual(trees.map(\.id), (0..<7).map { -(300 << 20 | Int64($0)) })
        XCTAssertTrue(trees.allSatisfy { $0.height == 6 && $0.crownRadius == 4 })
        XCTAssertEqual(GeoMath.distance(try XCTUnwrap(trees.first).coordinate, pt(0, 0)), 0, accuracy: 0.01)
        XCTAssertEqual(GeoMath.distance(try XCTUnwrap(trees.last).coordinate, pt(41, 0)), 0, accuracy: 0.01)
        for (a, b) in zip(trees, trees.dropFirst()) {
            XCTAssertLessThanOrEqual(GeoMath.distance(a.coordinate, b.coordinate), 8.0001)
        }

        // Null entries split the row; ids keep counting and never collide with another row's.
        let split = OSMElement(type: .way, id: 301, tags: ["natural": "tree_row"], nodes: [1, 2, 3, 4, 5],
                               geometry: [pt(0, 10), pt(7, 10), nil, pt(30, 10), pt(37, 10)])
        let splitTrees = OSMAreaParser.trees(from: [split])
        XCTAssertEqual(splitTrees.count, 4)
        let allIDs = (trees + splitTrees).map(\.id)
        XCTAssertEqual(Set(allIDs).count, allIDs.count)
        XCTAssertTrue(allIDs.allSatisfy { $0 < 0 })
    }

    func testCanopies() {
        let ring: [GeoCoordinate?] = [pt(0, 0), pt(50, 0), pt(50, 50), pt(0, 50), pt(0, 0)]
        let elements = [
            OSMElement(type: .way, id: 1, tags: ["natural": "wood"], nodes: [1, 2, 3, 4, 1], geometry: ring),
            OSMElement(type: .way, id: 2, tags: ["landuse": "forest", "height": "20"], nodes: [1, 2, 3, 4, 1],
                       geometry: ring),
            OSMElement(type: .way, id: 3, tags: ["natural": "wood"], nodes: [1, 2, 3], geometry: [pt(0, 0), pt(1, 0), pt(2, 2)]),
            OSMElement(type: .relation, id: 4, tags: ["type": "multipolygon", "natural": "wood"], members: [
                OSMMember(type: .way, ref: 9, role: "outer", geometry: ring),
            ]),
            OSMElement(type: .way, id: 5, tags: ["landuse": "grass"], nodes: [1, 2, 3, 4, 1], geometry: ring),
        ]
        let canopies = OSMAreaParser.canopies(from: elements)
        XCTAssertEqual(canopies.map(\.id), [1, 2, -(4 << 12)])
        XCTAssertEqual(canopies.map(\.height), [12, 20, 12])
        XCTAssertEqual(canopies[0].ring.count, 4)
    }

    // MARK: Cool spots

    func testCoolSpotKindMapping() {
        let cases: [([String: String], CoolSpotKind?)] = [
            (["amenity": "drinking_water"], .drinkingWater), (["amenity": "water_point"], .drinkingWater),
            (["amenity": "library"], .indoorCool), (["amenity": "community_centre"], .indoorCool),
            (["shop": "mall"], .indoorCool), (["shop": "department_store"], .indoorCool),
            (["amenity": "shelter"], .shelter), (["leisure": "park"], .park),
            (["leisure": "park", "amenity": "drinking_water"], .drinkingWater),
            (["amenity": "bench"], nil), (["shop": "bakery"], nil), (["leisure": "pitch"], nil), ([:], nil),
        ]
        for (tags, kind) in cases {
            XCTAssertEqual(OSMAreaParser.coolSpotKind(tags), kind, "\(tags)")
        }
    }

    func testCoolSpotsFromElements() {
        let elements = [
            OSMElement(type: .node, id: 1, coordinate: pt(0, 0), tags: ["amenity": "drinking_water"]),
            OSMElement(type: .node, id: 2, coordinate: pt(1, 0), tags: ["amenity": "library", "name": " ",
                                                                       "name:en": "Library", "opening_hours": "24/7"]),
            OSMElement(type: .node, id: 3, coordinate: pt(2, 0), tags: ["amenity": "shelter", "access": "private"]),
            OSMElement(type: .way, id: 4, tags: ["leisure": "park", "name": "Park"], center: pt(10, 10)),
            OSMElement(type: .way, id: 5, tags: ["shop": "mall"], geometry: [pt(0, 0), nil, pt(20, 20)]),
            OSMElement(type: .relation, id: 6, tags: ["leisure": "park"], center: pt(30, 30)),
            OSMElement(type: .relation, id: 7, tags: ["leisure": "park"], members: [
                OSMMember(type: .way, ref: 1, role: "outer", geometry: [pt(0, 0), pt(40, 0)]),
            ]),
            OSMElement(type: .way, id: 8, tags: ["amenity": "library"]),
            OSMElement(type: .node, id: 9, tags: ["amenity": "drinking_water"]),
        ]
        let spots = OSMAreaParser.coolSpots(from: elements)
        XCTAssertEqual(spots.map(\.id), [1, 2, -8, -10, -13, -15])
        XCTAssertEqual(spots.map(\.kind), [.drinkingWater, .indoorCool, .park, .indoorCool, .park, .park])
        XCTAssertNil(spots[0].name)
        XCTAssertEqual(spots[1].name, "Library", "blank name falls back to name:en")
        XCTAssertEqual(spots[1].openingHours, "24/7")
        XCTAssertEqual(spots[2].coordinate, pt(10, 10))
        XCTAssertEqual(GeoMath.distance(spots[3].coordinate, pt(10, 10)), 0, accuracy: 0.01, "mean of geometry")
        XCTAssertEqual(GeoMath.distance(spots[5].coordinate, pt(20, 0)), 0, accuracy: 0.01, "mean of members")
    }

    func testParseCoolSpotsResponse() throws {
        let json = """
        {"elements": [
          {"type": "node", "id": 11, "lat": 37.5701, "lon": 126.9801, "tags": {"amenity": "drinking_water"}},
          {"type": "way", "id": 12, "center": {"lat": 37.5702, "lon": 126.9802}, "nodes": [1, 2, 3, 1],
           "tags": {"shop": "department_store", "name": "Store", "opening_hours": "10:00-20:00"}},
          {"type": "relation", "id": 13, "center": {"lat": 37.5703, "lon": 126.9803},
           "tags": {"leisure": "park", "type": "multipolygon"}}
        ]}
        """
        let spots = try OSMAreaParser.parseCoolSpots(Data(json.utf8))
        XCTAssertEqual(spots.count, 3)
        XCTAssertEqual(spots[1], CoolSpot(id: -24, kind: .indoorCool, name: "Store",
                                          coordinate: GeoCoordinate(latitude: 37.5702, longitude: 126.9802),
                                          openingHours: "10:00-20:00"))
        XCTAssertEqual(spots[2].kind, .park)
        XCTAssertEqual(spots[2].id, -27)
    }

    // MARK: Synthetic fixture

    func testSyntheticFixtureBuildings() throws {
        let area = try OSMAreaParser.parse(OSMTestFixtures.data("synthetic_block"), bbox: OSMTestFixtures.syntheticBBox,
                                           fetchedAt: Date(timeIntervalSince1970: 0))
        let byID = Dictionary(uniqueKeysWithValues: area.buildings.map { ($0.id, $0) })
        XCTAssertEqual(area.buildings.count, 25)
        let expectedHeights: [Int64: Double] = [
            3001: 12, 3002: 12, 3003: 12.5, 3004: 12.5, 3005: 12.192, 3006: 12.192, 3007: 15, 3008: 14.3,
            3009: 7, 3010: 18, 3011: 14, 3012: 3, 3013: 9, 3014: 4, 3015: 4, 3016: 10, 3017: 16, 3018: 500,
            3019: 2, 3020: 20, 3024: 3.81, 2010: 9.6, -(4001 << 12): 20, -(4002 << 12): 9, -(4002 << 12 | 1): 9,
        ]
        for (id, height) in expectedHeights {
            let b = try XCTUnwrap(byID[id], "building \(id)")
            XCTAssertEqual(b.height, height, accuracy: 1e-9, "building \(id)")
            XCTAssertGreaterThanOrEqual(b.footprint.count, 3)
            XCTAssertNotEqual(b.footprint.first, b.footprint.last, "rings are open")
        }
        for id: Int64 in [3021, 3022, 3023] { XCTAssertNil(byID[id], "building \(id) should be skipped") }
        XCTAssertEqual(byID[3014]?.isRoofOnly, true)
        XCTAssertEqual(byID[3014]?.minHeight, 2.5)
        XCTAssertEqual(byID[3015]?.isRoofOnly, true)
        XCTAssertEqual(byID[3016]?.minHeight, 3)
        XCTAssertEqual(byID[3017]?.minHeight ?? 0, 6.4, accuracy: 1e-9)
        XCTAssertEqual(byID[3013]?.minHeight, 0)
        XCTAssertEqual(byID[3020]?.footprint.count, 5, "null vertex skipped")
        let twin = try XCTUnwrap(byID[-(4001 << 12)])
        XCTAssertEqual(twin.footprint.count, 4, "two outer halves joined, inner ignored")
        XCTAssertEqual(Set(twin.footprint), Set([GeoCoordinate(latitude: 37.5612, longitude: 126.9914),
                                                 GeoCoordinate(latitude: 37.5612, longitude: 126.9918),
                                                 GeoCoordinate(latitude: 37.5615, longitude: 126.9918),
                                                 GeoCoordinate(latitude: 37.5615, longitude: 126.9914)]))
    }

    func testSyntheticFixtureTreesAndCanopies() throws {
        let area = try OSMAreaParser.parse(OSMTestFixtures.data("synthetic_block"), bbox: OSMTestFixtures.syntheticBBox,
                                           fetchedAt: Date())
        let single = area.trees.filter { $0.id > 0 }
        XCTAssertEqual(single.map(\.id), [5001, 5002, 5003, 5004])
        XCTAssertEqual(single.map(\.height), [10, 8, 8, 12])
        XCTAssertEqual(single[0].crownRadius, 3)
        XCTAssertEqual(single[1].crownRadius, 4)
        XCTAssertEqual(single[2].crownRadius, 12.5 * 1.2 / .pi, accuracy: 1e-9)
        XCTAssertEqual(single[3].crownRadius, 4.5)
        let row = area.trees.filter { $0.id < 0 }
        let rowLine = [GeoCoordinate(latitude: 37.5605, longitude: 126.9912),
                       GeoCoordinate(latitude: 37.5605, longitude: 126.99165)]
        let expected = Int((GeoMath.length(of: rowLine) / 8).rounded(.up)) + 1
        XCTAssertEqual(row.count, expected)
        XCTAssertTrue(row.allSatisfy { $0.height == 6 })
        XCTAssertEqual(Set(row.map(\.id)).count, row.count)

        XCTAssertEqual(area.canopies.map(\.id), [5201, -(5301 << 12)])
        XCTAssertEqual(area.canopies.map(\.ring.count), [5, 4])
        XCTAssertTrue(area.canopies.allSatisfy { $0.height == 12 })
    }

    func testSyntheticFixtureCoolSpots() throws {
        let area = try OSMAreaParser.parse(OSMTestFixtures.data("synthetic_block"), bbox: OSMTestFixtures.syntheticBBox,
                                           fetchedAt: Date())
        let byID = Dictionary(uniqueKeysWithValues: area.coolSpots.map { ($0.id, $0) })
        let expected: [Int64: CoolSpotKind] = [
            6001: .drinkingWater, 6002: .drinkingWater, 6003: .indoorCool, 6004: .indoorCool, 6005: .indoorCool,
            6006: .shelter, -4020: .indoorCool, -12202: .indoorCool, -12204: .park, -12403: .park,
        ]
        XCTAssertEqual(area.coolSpots.count, expected.count)
        for (id, kind) in expected { XCTAssertEqual(byID[id]?.kind, kind, "cool spot \(id)") }
        XCTAssertEqual(Set(area.coolSpots.map(\.kind)), Set(CoolSpotKind.allCases), "every kind present")
        XCTAssertNil(byID[6001]?.name)
        XCTAssertEqual(byID[6002]?.name, "Refill Station")
        let library = try XCTUnwrap(byID[-4020])
        XCTAssertEqual(library.name, "City Library")
        XCTAssertEqual(library.openingHours, "Mo-Fr 09:00-18:00")
        XCTAssertEqual(library.coordinate, GeoCoordinate(latitude: 37.56065, longitude: 126.9916))
        XCTAssertEqual(byID[-12403]?.name, "Central Park")
        // The library way is printed twice (geometry + centre) and still yields one building.
        XCTAssertEqual(area.buildings.filter { $0.id == 2010 }.count, 1)
        // parseCoolSpots gives the same list.
        XCTAssertEqual(try OSMAreaParser.parseCoolSpots(OSMTestFixtures.data("synthetic_block")), area.coolSpots)
    }

    // MARK: Real data

    func testRealSeoulFixture() throws {
        let data = try OSMTestFixtures.data("seoul_gwanghwamun")
        let area = try OSMAreaParser.parse(data, bbox: OSMTestFixtures.seoulBBox, fetchedAt: Date())
        XCTAssertGreaterThan(area.buildings.count, 50)
        XCTAssertGreaterThan(area.graph.edges.count, 50)
        XCTAssertGreaterThan(area.trees.count, 0)
        XCTAssertGreaterThan(area.coolSpots.count, 0)
        XCTAssertTrue(area.buildings.allSatisfy { $0.footprint.count >= 3 && (2...500).contains($0.height) })
        XCTAssertTrue(area.graph.edges.contains { $0.wayClass == .crossing })
        XCTAssertTrue(area.graph.nodes.contains { $0.isCrossing && $0.hasTrafficSignals })
        XCTAssertTrue(area.graph.edges.contains { $0.isSteps })
        WalkGraphBuilderTests.assertValidGraph(area.graph)
        XCTAssertEqual(WalkGraphBuilderTests.componentCount(area.graph), 1)
    }
}
