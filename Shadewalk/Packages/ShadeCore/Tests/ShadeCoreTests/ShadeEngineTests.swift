import XCTest
@testable import ShadeCore

final class ShadeEngineTests: XCTestCase {
    /// Fixtures are written in local metres (x = east, y = north) around this origin.
    let origin = GeoCoordinate(latitude: 48.8566, longitude: 2.3522)
    var proj: LocalProjection { LocalProjection(origin: origin) }

    // MARK: - Fixture helpers

    func geo(_ x: Double, _ y: Double) -> GeoCoordinate { proj.unproject(Point2D(x: x, y: y)) }

    func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, height: Double, minHeight: Double = 0,
              roofOnly: Bool = false, id: Int64 = 1) -> Building {
        Building(id: id, footprint: [geo(x0, y0), geo(x1, y0), geo(x1, y1), geo(x0, y1)], height: height,
                 minHeight: minHeight, isRoofOnly: roofOnly)
    }

    func square(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [GeoCoordinate] {
        [geo(x0, y0), geo(x1, y0), geo(x1, y1), geo(x0, y1)]
    }

    func engine(_ buildings: [Building] = [], trees: [Tree] = [], canopies: [CanopyArea] = []) -> ShadeEngine {
        ShadeEngine(buildings: buildings, trees: trees, canopies: canopies, origin: origin)
    }

    func sun(_ azimuth: Double, _ elevation: Double) -> SunPosition { SunPosition(azimuth: azimuth, elevation: elevation) }

    func shaded(_ e: ShadeEngine, _ x: Double, _ y: Double, _ s: SunPosition) -> Bool { e.isShaded(geo(x, y), sun: s) }

    // MARK: - Buildings

    func testBuildingDueSouthShadesWithinShadowLength() {
        // 20 m building whose north face is at y = -10; noon sun from the south at 45° → 20 m shadow.
        let e = engine([rect(-10, -30, 10, -10, height: 20)])
        let noon = sun(180, 45)
        XCTAssertTrue(shaded(e, 0, -5, noon))
        XCTAssertTrue(shaded(e, -9, 5, noon))
        XCTAssertTrue(shaded(e, 0, 9, noon))     // 19 m from the face
        XCTAssertFalse(shaded(e, 0, 11, noon))   // 21 m from the face
        XCTAssertFalse(shaded(e, 0, 40, noon))
        XCTAssertFalse(shaded(e, 15, 0, noon))   // beside the building
        XCTAssertFalse(shaded(e, 0, -40, noon))  // south side faces the sun
    }

    func testShadowLengthFollowsElevation() {
        let e = engine([rect(-10, -30, 10, -10, height: 20)])
        // tan 30° → 34.6 m shadow.
        XCTAssertTrue(shaded(e, 0, 20, sun(180, 30)))
        XCTAssertFalse(shaded(e, 0, 26, sun(180, 30)))
        // tan 60° → 11.5 m shadow.
        XCTAssertTrue(shaded(e, 0, 0, sun(180, 60)))
        XCTAssertFalse(shaded(e, 0, 3, sun(180, 60)))
    }

    func testSunFromOtherAzimuths() {
        let east = engine([rect(10, -10, 20, 10, height: 30)])
        XCTAssertTrue(shaded(east, 0, 0, sun(90, 45)))
        XCTAssertFalse(shaded(east, 0, 0, sun(270, 45)))
        XCTAssertFalse(shaded(east, 0, 0, sun(0, 45)))
        XCTAssertFalse(shaded(east, 0, 0, sun(180, 45)))

        let northEast = engine([rect(10, 10, 20, 20, height: 30)])
        XCTAssertTrue(shaded(northEast, 0, 0, sun(45, 45)))   // enters at ~14 m
        XCTAssertTrue(shaded(northEast, 0, 0, sun(30, 45)))   // enters the west face at 20 m
        XCTAssertFalse(shaded(northEast, 0, 0, sun(10, 45)))  // passes west of it
        XCTAssertFalse(shaded(northEast, 0, 0, sun(225, 45)))

        // Morning sun from the east-south-east, building west of the point does nothing.
        let west = engine([rect(-20, -10, -10, 10, height: 30)])
        XCTAssertFalse(shaded(west, 0, 0, sun(110, 20)))
        XCTAssertTrue(shaded(west, 0, 0, sun(270, 20)))
    }

    func testLowSunShadowIsCappedAt400Metres() {
        // 30 m / tan 1° ≈ 1.7 km, capped at 400 m.
        let e = engine([rect(-10, -10, 10, 10, height: 30)])
        let low = sun(180, 1)
        XCTAssertTrue(shaded(e, 0, 300, low))
        XCTAssertTrue(shaded(e, 0, 405, low))   // ray reaches the face at 395 m
        XCTAssertFalse(shaded(e, 0, 420, low))  // would need 410 m
        XCTAssertFalse(shaded(e, 0, 1000, low))
    }

    func testTallVersusShortBuilding() {
        let e = engine([rect(-30, -20, -10, -10, height: 5, id: 1), rect(10, -20, 30, -10, height: 40, id: 2)])
        let noon = sun(180, 45)
        XCTAssertFalse(shaded(e, -20, 0, noon))  // 10 m behind a 5 m building
        XCTAssertTrue(shaded(e, -20, -7, noon))  // 3 m behind it
        XCTAssertTrue(shaded(e, 20, 0, noon))    // 10 m behind a 40 m building
        XCTAssertTrue(shaded(e, 20, 25, noon))
    }

    func testPointInsideSolidBuildingIsShaded() {
        let e = engine([rect(-10, -10, 10, 10, height: 15)])
        XCTAssertTrue(shaded(e, 0, 0, sun(0, 90)))
        XCTAssertTrue(shaded(e, 9, -9, sun(180, 89)))
        XCTAssertTrue(shaded(e, 0, -9.5, sun(180, 2)))
        XCTAssertFalse(shaded(e, 0, 12, sun(0, 90)))
    }

    func testBridgeWithMinHeight() {
        // Footbridge deck 6–8 m above the ground, spanning y ∈ [-5, 5].
        let bridge = rect(-50, -5, 50, 5, height: 8, minHeight: 6)
        let e = engine([bridge])

        // High sun (80°): the deck shadow sits ~1.1–1.4 m north of the deck.
        let high = sun(180, 80)
        XCTAssertTrue(shaded(e, 0, 0, high))     // under the deck
        XCTAssertTrue(shaded(e, 0, 6, high))     // ray enters at 5.7 m, leaves at 62 m height
        XCTAssertFalse(shaded(e, 0, 6.6, high))  // ray already above the deck when it reaches it
        XCTAssertFalse(shaded(e, 0, -4.5, high)) // sun slips in under the south edge
        XCTAssertFalse(shaded(e, 0, 20, high))

        // Low sun (10°): light passes under the deck; its shadow falls ~34–45 m north.
        let low = sun(180, 10)
        XCTAssertFalse(shaded(e, 0, 0, low))
        XCTAssertFalse(shaded(e, 0, 25, low))    // ray 3.5–5.3 m high across the deck → passes beneath
        XCTAssertTrue(shaded(e, 0, 30, low))     // 4.4–6.2 m → clips the underside
        XCTAssertTrue(shaded(e, 0, 45, low))     // 7.1–8.8 m
        XCTAssertFalse(shaded(e, 0, 55, low))    // 8.8 m at entry → above the deck

        // The same footprint as a solid building shades all of those.
        let solid = engine([rect(-50, -5, 50, 5, height: 8)])
        XCTAssertTrue(shaded(solid, 0, 0, low))
        XCTAssertTrue(shaded(solid, 0, 25, low))
    }

    func testRoofOnlyStructure() {
        let roof = rect(-5, -5, 5, 5, height: 4, roofOnly: true)
        let e = engine([roof])
        // Underneath is always shaded, even when low sun would reach under a raised slab.
        XCTAssertTrue(shaded(e, 0, 0, sun(180, 5)))
        XCTAssertTrue(shaded(e, 0, -4.9, sun(180, 10)))
        let slab = engine([rect(-5, -5, 5, 5, height: 4, minHeight: 2.5)])
        XCTAssertFalse(shaded(slab, 0, -4.9, sun(180, 10)))

        // It casts shadow like a slab from the default 2.5 m underside to 4 m: footprint moved 2.5–4 m north.
        let noon = sun(180, 45)
        XCTAssertTrue(shaded(e, 0, 6, noon))
        XCTAssertTrue(shaded(e, 0, 8, noon))
        XCTAssertFalse(shaded(e, 0, 10, noon))
        XCTAssertFalse(shaded(e, 0, -8, noon))

        // Explicit underside.
        let carport = engine([rect(-5, -5, 5, 5, height: 6, minHeight: 3, roofOnly: true)])
        XCTAssertTrue(shaded(carport, 0, 10, noon))
        XCTAssertFalse(shaded(carport, 0, 12, noon))
    }

    // MARK: - Trees and canopies

    func testTreeShadowDiscIsOffsetAwayFromSun() {
        let tree = Tree(id: 1, coordinate: geo(0, 0), height: 10, crownRadius: 4)
        let e = engine(trees: [tree])
        // 45° from the south: centre 0.7 · 10 = 7 m north of the trunk.
        let noon = sun(180, 45)
        XCTAssertTrue(shaded(e, 0, 7, noon))
        XCTAssertTrue(shaded(e, 0, 10.5, noon))
        XCTAssertTrue(shaded(e, 3, 7, noon))
        XCTAssertFalse(shaded(e, 5, 7, noon))
        XCTAssertFalse(shaded(e, 0, 0, noon))   // the trunk itself is 7 m from the disc centre
        XCTAssertFalse(shaded(e, 0, -2, noon))

        // Morning sun from the east → disc 7 m west.
        XCTAssertTrue(shaded(e, -7, 0, sun(90, 45)))
        XCTAssertFalse(shaded(e, 7, 0, sun(90, 45)))

        // High sun: offset 4.04 m.
        XCTAssertTrue(shaded(e, 0, 1, sun(180, 60)))
        XCTAssertTrue(shaded(e, 0, 7.5, sun(180, 60)))
        XCTAssertFalse(shaded(e, 0, 8.5, sun(180, 60)))

        // Very low sun: 200 m offset capped at 60 m.
        let low = sun(180, 2)
        XCTAssertTrue(shaded(e, 0, 60, low))
        XCTAssertTrue(shaded(e, 0, 63, low))
        XCTAssertFalse(shaded(e, 0, 65, low))
        XCTAssertFalse(shaded(e, 0, 200, low))
    }

    func testOversizedCrownIsCapped() {
        let e = engine(trees: [Tree(id: 1, coordinate: geo(0, 0), height: 10, crownRadius: 500)])
        let overhead = sun(0, 90)
        XCTAssertTrue(shaded(e, 25, 0, overhead))
        XCTAssertFalse(shaded(e, 40, 0, overhead))
    }

    func testCanopyAreaShiftedAwayFromSun() {
        let wood = CanopyArea(id: 1, ring: square(0, 0, 100, 100), height: 12)
        let e = engine(canopies: [wood])

        // 45°: offset 0.7 · 12 = 8.4 m north.
        let noon = sun(180, 45)
        XCTAssertTrue(shaded(e, 50, 50, noon))
        XCTAssertTrue(shaded(e, 50, 105, noon))
        XCTAssertFalse(shaded(e, 50, 110, noon))
        XCTAssertFalse(shaded(e, 50, 3, noon))   // the lit southern strip (elevation ≤ 60°)
        XCTAssertFalse(shaded(e, 150, 50, noon))

        // 70°: offset 3.06 m, and the unshifted polygon counts too.
        let high = sun(180, 70)
        XCTAssertTrue(shaded(e, 50, 2, high))
        XCTAssertTrue(shaded(e, 50, 103, high))
        XCTAssertFalse(shaded(e, 50, 104, high))

        // 5°: offset capped at 30 m.
        let low = sun(180, 5)
        XCTAssertTrue(shaded(e, 50, 125, low))
        XCTAssertFalse(shaded(e, 50, 135, low))
        XCTAssertFalse(shaded(e, 50, 20, low))

        // Sun from the west (afternoon) shifts the shade east.
        XCTAssertTrue(shaded(e, 105, 50, sun(270, 45)))
        XCTAssertFalse(shaded(e, 3, 50, sun(270, 45)))
    }

    // MARK: - Sun down and degenerate inputs

    func testSunDownMeansEverythingShaded() {
        let e = engine([rect(-10, -10, 10, 10, height: 20)])
        let line = [geo(-100, 50), geo(100, 50)]
        for s in [sun(180, 0), sun(250, -12), sun(0, .nan)] {
            XCTAssertTrue(e.isShaded(geo(300, 300), sun: s))
            XCTAssertEqual(e.shadeFraction(along: line, sun: s), 1)
            let runs = e.shadeRuns(along: line, sun: s)
            XCTAssertEqual(runs.count, 1)
            XCTAssertEqual(runs.first?.isShaded, true)
            XCTAssertEqual(runs.first?.length ?? 0, GeoMath.length(of: line), accuracy: 1e-6)
            XCTAssertTrue(e.shadowPolygons(sun: s, within: nil).isEmpty)
        }
    }

    func testEmptyEngineIsSunny() {
        let e = ShadeEngine(buildings: [], trees: [], canopies: [])
        XCTAssertFalse(e.isShaded(origin, sun: sun(180, 45)))
        XCTAssertEqual(e.shadeFraction(along: [origin, GeoMath.destination(from: origin, bearing: 90, distance: 50)],
                                       sun: sun(180, 45)), 0)
        XCTAssertTrue(e.shadowPolygons(sun: sun(180, 45), within: nil).isEmpty)
        XCTAssertTrue(e.isShaded(origin, sun: sun(180, -1)))
    }

    func testDefaultOriginIsCentreOfInputs() {
        let a = geo(-200, -100), b = geo(300, 500)
        let e = ShadeEngine(buildings: [Building(id: 1, footprint: [a, geo(-190, -100), geo(-190, -90)], height: 10)],
                            trees: [Tree(id: 2, coordinate: b)], canopies: [])
        XCTAssertEqual(e.projection.origin.latitude, (a.latitude + b.latitude) / 2, accuracy: 1e-12)
        XCTAssertEqual(e.projection.origin.longitude, (a.longitude + b.longitude) / 2, accuracy: 1e-12)
        // An explicit origin wins; an invalid one falls back to the centre.
        XCTAssertEqual(ShadeEngine(buildings: [], trees: [], canopies: [], origin: a).projection.origin, a)
        let fallback = ShadeEngine(buildings: [], trees: [Tree(id: 1, coordinate: b)], canopies: [],
                                   origin: GeoCoordinate(latitude: .nan, longitude: 0))
        XCTAssertEqual(fallback.projection.origin, b)
    }

    func testInvalidInputsAreSkipped() {
        let nan = GeoCoordinate(latitude: .nan, longitude: 2)
        let buildings = [
            Building(id: 1, footprint: [geo(0, 0), geo(10, 0)], height: 10),                // < 3 vertices
            Building(id: 2, footprint: [geo(0, 0), nan, geo(10, 10)], height: 10),           // NaN vertex
            rect(0, 0, 10, 10, height: 0, id: 3),                                             // no height
            rect(0, 0, 10, 10, height: .infinity, id: 4),                                     // bad height
            rect(0, 0, 10, 10, height: 5, minHeight: 8, id: 5),                               // underside above top
            Building(id: 6, footprint: square(20, 20, 30, 30) + [geo(20, 20)], height: 10),   // closed ring: kept
            rect(40, 40, 50, 50, height: -1, roofOnly: true, id: 7),                          // roof: default height
        ]
        let trees = [
            Tree(id: 1, coordinate: nan),
            Tree(id: 2, coordinate: geo(0, 0), crownRadius: 0),
            Tree(id: 3, coordinate: geo(0, 0), height: .nan, crownRadius: 3),                 // kept, no offset
        ]
        let canopies = [CanopyArea(id: 1, ring: [geo(0, 0), geo(1, 1)]), CanopyArea(id: 2, ring: square(60, 60, 70, 70))]
        let e = engine(buildings, trees: trees, canopies: canopies)
        XCTAssertEqual(e.buildingCount, 2)
        XCTAssertEqual(e.treeCount, 1)
        XCTAssertEqual(e.canopyCount, 1)
        XCTAssertTrue(shaded(e, 25, 25, sun(180, 45)))
        XCTAssertTrue(shaded(e, 45, 45, sun(180, 30)))
        XCTAssertTrue(shaded(e, 1, 0, sun(180, 45)))   // tree without height: disc on the trunk
        XCTAssertFalse(shaded(e, 5, 5, sun(180, 45)))  // only dropped buildings cover this point
        XCTAssertFalse(e.isShaded(nan, sun: sun(180, 45)))
        XCTAssertFalse(e.shadowPolygons(sun: sun(180, 45), within: nil).isEmpty)
    }

    // MARK: - Fractions

    func testShadeFractionAlongPolyline() {
        // Shadow covers y = 0 for x ∈ [-2, 62].
        let e = engine([rect(-2, -20, 62, -5, height: 30)])
        let noon = sun(180, 45)
        let line = [geo(-50, 0), geo(50, 0)]
        // 21 samples at x = -50, -45, …, 50; shaded for x = 0 … 50.
        XCTAssertEqual(e.shadeFraction(along: line, sun: noon), 11.0 / 21.0, accuracy: 1e-9)
        XCTAssertEqual(e.shadeFraction(along: line, sun: noon, spacing: 10), 6.0 / 11.0, accuracy: 1e-9)
        // Invalid spacing falls back to 5 m.
        XCTAssertEqual(e.shadeFraction(along: line, sun: noon, spacing: 0), 11.0 / 21.0, accuracy: 1e-9)
        XCTAssertEqual(e.shadeFraction(along: line, sun: noon, spacing: -3), 11.0 / 21.0, accuracy: 1e-9)
        // Short polylines still take two samples (both ends).
        XCTAssertEqual(e.shadeFraction(along: [geo(10, 0), geo(11, 0)], sun: noon), 1)
        XCTAssertEqual(e.shadeFraction(along: [geo(-10, 0), geo(-9, 0)], sun: noon), 0)
        XCTAssertEqual(e.shadeFraction(along: [geo(61, 0), geo(64, 0)], sun: noon), 0.5)
        // Degenerate polylines.
        XCTAssertEqual(e.shadeFraction(along: [], sun: noon), 0)
        XCTAssertEqual(e.shadeFraction(along: [geo(10, 0)], sun: noon), 1)
        XCTAssertEqual(e.shadeFraction(along: [geo(-10, 0)], sun: noon), 0)
    }

    func testEdgeShadeFractions() {
        let e = engine([rect(-2, -20, 62, -5, height: 32)])
        let noon = sun(180, 45)
        let nodes = [
            GraphNode(id: 0, osmID: 10, coordinate: geo(0, 0)),
            GraphNode(id: 1, osmID: 11, coordinate: geo(50, 0)),
            GraphNode(id: 2, osmID: 12, coordinate: geo(50, 100)),
            GraphNode(id: 3, osmID: 13, coordinate: geo(150, 100)),
        ]
        let edges = [
            GraphEdge(id: 0, from: 0, to: 1, geometry: [geo(0, 0), geo(25, 0), geo(50, 0)], length: 50, wayClass: .footway),
            GraphEdge(id: 1, from: 1, to: 2, geometry: [geo(50, 0), geo(50, 100)], length: 100, wayClass: .residential),
            GraphEdge(id: 2, from: 2, to: 3, geometry: [geo(50, 100), geo(150, 100)], length: 100, wayClass: .footway,
                      isCovered: true),
            GraphEdge(id: 3, from: 3, to: 3, geometry: [geo(150, 100), geo(160, 100)], length: 10, wayClass: .path),
        ]
        let graph = WalkGraph(nodes: nodes, edges: edges)
        let f = e.edgeShadeFractions(for: graph, sun: noon)
        XCTAssertEqual(f.count, edges.count)
        XCTAssertEqual(f[0], 1)
        // y = 0 … 100 every 5 m: shaded while within 32 m of the face at y = -5 (y = 0 … 25).
        XCTAssertEqual(f[1], 6.0 / 21.0, accuracy: 1e-9)
        XCTAssertEqual(f[2], 1)  // covered
        XCTAssertEqual(f[3], 0)
        XCTAssertEqual(e.edgeShadeFractions(for: graph, sun: sun(0, -3)), [1, 1, 1, 1])
        XCTAssertEqual(e.edgeShadeFractions(for: .empty, sun: noon), [])
    }

    func testEdgeShadeFractionsLargeGraphMatchesPerEdgeFractions() {
        var rng = ShadeTestRNG(seed: 7)
        let buildings = (0..<150).map { i -> Building in
            let x = rng.uniform(-300, 300), y = rng.uniform(-300, 300)
            return rect(x, y, x + rng.uniform(8, 30), y + rng.uniform(8, 30), height: rng.uniform(5, 40), id: Int64(i))
        }
        let e = engine(buildings)
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        for i in 0..<700 {
            let a = Point2D(x: rng.uniform(-320, 320), y: rng.uniform(-320, 320))
            let b = a + Point2D(x: rng.uniform(-60, 60), y: rng.uniform(-60, 60))
            nodes.append(GraphNode(id: 2 * i, osmID: Int64(2 * i), coordinate: proj.unproject(a)))
            nodes.append(GraphNode(id: 2 * i + 1, osmID: Int64(2 * i + 1), coordinate: proj.unproject(b)))
            edges.append(GraphEdge(id: i, from: 2 * i, to: 2 * i + 1, geometry: [proj.unproject(a), proj.unproject(b)],
                                   length: a.distance(to: b), wayClass: .footway, isCovered: i % 50 == 0))
        }
        let s = sun(140, 28)
        let f = e.edgeShadeFractions(for: WalkGraph(nodes: nodes, edges: edges), sun: s)
        XCTAssertEqual(f.count, edges.count)
        for (i, edge) in edges.enumerated() {
            let expected = edge.isCovered ? 1 : e.shadeFraction(along: edge.geometry, sun: s)
            XCTAssertEqual(f[i], expected, "edge \(i)")
        }
        XCTAssertTrue(f.contains { $0 > 0 && $0 < 1 })
    }

    // MARK: - Runs

    func testShadeRunsSplitAtShadowEdges() throws {
        // Shadow covers y = 0 for x ∈ [-21, 31]; samples every 5 m → boundaries at -22.5 and 32.5.
        let e = engine([rect(-21, -20, 31, -5, height: 30)])
        let line = [geo(-100, 0), geo(0, 0), geo(100, 0)]
        let runs = e.shadeRuns(along: line, sun: sun(180, 45))
        XCTAssertEqual(runs.map(\.isShaded), [false, true, false])
        XCTAssertEqual(runs.map(\.length).reduce(0, +), GeoMath.length(of: line), accuracy: 1e-6)
        XCTAssertEqual(runs[0].length, 77.5, accuracy: 0.01)
        XCTAssertEqual(runs[1].length, 55, accuracy: 0.01)
        XCTAssertEqual(runs[2].length, 67.5, accuracy: 0.01)
        assertRunInvariants(runs, line)
        // The original middle vertex sits inside the shaded run, between its boundary points.
        XCTAssertEqual(runs[1].coordinates.count, 3)
        XCTAssertEqual(runs[1].coordinates[1], line[1])
        XCTAssertEqual(proj.project(runs[1].coordinates[0]).x, -22.5, accuracy: 0.01)
        XCTAssertEqual(proj.project(runs[1].coordinates[2]).x, 32.5, accuracy: 0.01)
        XCTAssertEqual(runs[0].coordinates.count, 2)
    }

    func testShadeRunsMergeShortRuns() {
        let noon = sun(180, 45)
        let line = [geo(-100, 0), geo(100, 0)]
        // A small crown shadow (disc of radius 2.5 centred on the line) → a 5 m shaded run.
        let tree = engine(trees: [Tree(id: 1, coordinate: geo(0, -7), height: 10, crownRadius: 2.5)])
        let merged = tree.shadeRuns(along: line, sun: noon, spacing: 1)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.isShaded, false)
        XCTAssertEqual(merged.first?.coordinates, line)
        XCTAssertEqual(merged.first?.length ?? 0, GeoMath.length(of: line), accuracy: 1e-6)
        let kept = tree.shadeRuns(along: line, sun: noon, spacing: 1, minRunLength: 0)
        XCTAssertEqual(kept.map(\.isShaded), [false, true, false])
        XCTAssertEqual(kept[1].length, 5, accuracy: 0.01)
        assertRunInvariants(kept, line)
        XCTAssertEqual(tree.shadeRuns(along: line, sun: noon, spacing: 1, minRunLength: 4).count, 3)

        // A 5 m sunny gap between two shadows is absorbed into one shaded run.
        let gap = engine([rect(-50.5, -20, -2.5, -5, height: 30, id: 1), rect(2.5, -20, 50.5, -5, height: 30, id: 2)])
        let runs = gap.shadeRuns(along: line, sun: noon, spacing: 1)
        XCTAssertEqual(runs.map(\.isShaded), [false, true, false])
        XCTAssertEqual(runs[1].length, 101, accuracy: 0.01)
        assertRunInvariants(runs, line)
        XCTAssertEqual(gap.shadeRuns(along: line, sun: noon, spacing: 1, minRunLength: 0).count, 5)
    }

    func testShadeRunsDegenerateInputs() {
        let e = engine([rect(-10, -20, 10, -5, height: 30)])
        let noon = sun(180, 45)
        XCTAssertEqual(e.shadeRuns(along: [], sun: noon), [])
        let single = e.shadeRuns(along: [geo(0, 0)], sun: noon)
        XCTAssertEqual(single, [RouteSegment(coordinates: [geo(0, 0)], length: 0, isShaded: true)])
        let sunny = e.shadeRuns(along: [geo(50, 0)], sun: noon)
        XCTAssertEqual(sunny.first?.isShaded, false)
        let zero = e.shadeRuns(along: [geo(0, 0), geo(0, 0)], sun: noon)
        XCTAssertEqual(zero.count, 1)
        XCTAssertEqual(zero.first?.length, 0)
        // Whole polyline in one state: one run carrying every vertex.
        let line = [geo(100, 0), geo(110, 5), geo(120, 0), geo(130, 5)]
        let runs = e.shadeRuns(along: line, sun: noon)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.coordinates, line)
        XCTAssertEqual(runs.first?.isShaded, false)
    }

    func testShadeRunsInvariantsOnBusyStreet() {
        var rng = ShadeTestRNG(seed: 11)
        let trees = (0..<120).map { i in
            Tree(id: Int64(i), coordinate: geo(rng.uniform(-500, 500), rng.uniform(-15, 5)),
                 height: rng.uniform(4, 14), crownRadius: rng.uniform(1, 5))
        }
        let buildings = (0..<25).map { i -> Building in
            let x = rng.uniform(-500, 480)
            return rect(x, -40, x + rng.uniform(5, 30), -12, height: rng.uniform(4, 30), id: Int64(i))
        }
        let e = engine(buildings, trees: trees)
        var line: [GeoCoordinate] = []
        for k in 0...40 { line.append(geo(-500 + 25 * Double(k), rng.uniform(-3, 3))) }
        line.insert(line[10], at: 10)  // duplicated vertex
        for minRun in [0.0, 3, 8, 20] {
            for s in [sun(160, 35), sun(200, 15), sun(120, 60)] {
                let runs = e.shadeRuns(along: line, sun: s, spacing: 2, minRunLength: minRun)
                assertRunInvariants(runs, line)
                if runs.count > 1 {
                    for r in runs { XCTAssertGreaterThanOrEqual(r.length, minRun - 1e-9) }
                }
                for k in 1..<max(1, runs.count) { XCTAssertNotEqual(runs[k].isShaded, runs[k - 1].isShaded) }
            }
        }
    }

    func testRunMergerPicksShortestFirst() {
        func r(_ a: Double, _ b: Double, _ s: Bool) -> ShadeRun { ShadeRun(start: a, end: b, isShaded: s) }
        let input = [r(0, 10, false), r(10, 13, true), r(13, 23, false), r(23, 29, true)]
        XCTAssertEqual(ShadeRunBuilder.merge(input, minLength: 5), [r(0, 23, false), r(23, 29, true)])
        let tail = [r(0, 10, false), r(10, 13, true), r(13, 23, false), r(23, 25, true), r(25, 26, false)]
        XCTAssertEqual(ShadeRunBuilder.merge(tail, minLength: 5), [r(0, 26, false)])
        XCTAssertEqual(ShadeRunBuilder.merge(input, minLength: 0), input)
        XCTAssertEqual(ShadeRunBuilder.merge(input, minLength: .nan), input)
        XCTAssertEqual(ShadeRunBuilder.merge(input, minLength: .infinity), [r(0, 29, false)])
        XCTAssertEqual(ShadeRunBuilder.merge([r(0, 1, true)], minLength: 5), [r(0, 1, true)])
    }

    /// Lengths sum to the polyline length, runs chain through shared boundary coordinates and keep the endpoints.
    func assertRunInvariants(_ runs: [RouteSegment], _ polyline: [GeoCoordinate], file: StaticString = #filePath,
                             line ln: UInt = #line) {
        guard let first = runs.first, let last = runs.last else { return XCTFail("no runs", file: file, line: ln) }
        let total = GeoMath.length(of: polyline)
        XCTAssertEqual(runs.map(\.length).reduce(0, +), total, accuracy: total * 0.01, file: file, line: ln)
        XCTAssertEqual(first.coordinates.first, polyline.first, file: file, line: ln)
        XCTAssertEqual(last.coordinates.last, polyline.last, file: file, line: ln)
        for (k, run) in runs.enumerated() {
            XCTAssertGreaterThanOrEqual(run.coordinates.count, 2, file: file, line: ln)
            XCTAssertEqual(run.length, GeoMath.length(of: run.coordinates), accuracy: 0.05 + run.length * 0.001,
                           file: file, line: ln)
            if k > 0 { XCTAssertEqual(runs[k - 1].coordinates.last, run.coordinates.first, file: file, line: ln) }
        }
        // Every original vertex survives somewhere (as an interior vertex or as a boundary point).
        let all = runs.flatMap(\.coordinates)
        for v in polyline { XCTAssertTrue(all.contains(v), "vertex \(v) missing", file: file, line: ln) }
    }

    // MARK: - Overlay polygons

    func testShadowPolygonsGeometry() throws {
        let noon = sun(180, 45)
        let e = engine([rect(-10, -30, 10, -10, height: 20)])
        let polys = e.shadowPolygons(sun: noon, within: nil)
        XCTAssertEqual(polys.count, 1)
        let b = try XCTUnwrap(bounds(polys[0]))
        // Footprint ∪ footprint moved 20 m north.
        XCTAssertEqual(b.minX, -10, accuracy: 0.01)
        XCTAssertEqual(b.maxX, 10, accuracy: 0.01)
        XCTAssertEqual(b.minY, -30, accuracy: 0.01)
        XCTAssertEqual(b.maxY, 10, accuracy: 0.01)
        XCTAssertNotEqual(polys[0].first, polys[0].last)

        // Trees → 12-gon at the offset centre; canopies → moved ring.
        let mixed = engine(trees: [Tree(id: 1, coordinate: geo(0, 0), height: 10, crownRadius: 4)],
                           canopies: [CanopyArea(id: 2, ring: square(100, 0, 150, 50), height: 12)])
        let mp = mixed.shadowPolygons(sun: noon, within: nil)
        XCTAssertEqual(mp.count, 2)
        let canopy = try XCTUnwrap(mp.first { $0.count == 4 })
        let cb = try XCTUnwrap(bounds(canopy))
        XCTAssertEqual(cb.minY, 8.4, accuracy: 0.01)
        XCTAssertEqual(cb.maxY, 58.4, accuracy: 0.01)
        XCTAssertEqual(cb.minX, 100, accuracy: 0.01)
        let disc = try XCTUnwrap(mp.first { $0.count == 12 })
        let db = try XCTUnwrap(bounds(disc))
        XCTAssertEqual((db.minY + db.maxY) / 2, 7, accuracy: 0.01)
        XCTAssertEqual((db.minX + db.maxX) / 2, 0, accuracy: 0.01)
        XCTAssertEqual(db.maxX - db.minX, 8, accuracy: 0.01)
    }

    func testShadowPolygonsRaisedAndRoofOnly() throws {
        let noon = sun(180, 45)
        // Deck 6–8 m: shadow is the footprint moved 6…8 m north (not touching the ground below it).
        let bridge = engine([rect(-20, -5, 20, 5, height: 8, minHeight: 6)])
        let bp = bridge.shadowPolygons(sun: noon, within: nil)
        XCTAssertEqual(bp.count, 1)
        let bb = try XCTUnwrap(bounds(bp[0]))
        XCTAssertEqual(bb.minY, 1, accuracy: 0.01)
        XCTAssertEqual(bb.maxY, 13, accuracy: 0.01)

        // Roof-only: footprint plus the slab shadow (2.5–4 m).
        let roof = engine([rect(-5, -5, 5, 5, height: 4, roofOnly: true)])
        let rp = roof.shadowPolygons(sun: noon, within: nil)
        XCTAssertEqual(rp.count, 2)
        let rb = rp.compactMap(bounds).sorted { $0.minY < $1.minY }
        XCTAssertEqual(rb[0].minY, -5, accuracy: 0.01)
        XCTAssertEqual(rb[0].maxY, 5, accuracy: 0.01)
        XCTAssertEqual(rb[1].minY, -2.5, accuracy: 0.01)
        XCTAssertEqual(rb[1].maxY, 9, accuracy: 0.01)
    }

    func testShadowPolygonsCappedAt400Metres() throws {
        let e = engine([rect(-10, -10, 10, 10, height: 50)])
        let polys = e.shadowPolygons(sun: sun(225, 0.5), within: nil)
        let b = try XCTUnwrap(polys.first.flatMap(bounds))
        let reach = 400 / 2.0.squareRoot()
        XCTAssertEqual(b.maxX, 10 + reach, accuracy: 0.05)
        XCTAssertEqual(b.maxY, 10 + reach, accuracy: 0.05)
        XCTAssertEqual(b.minX, -10, accuracy: 0.01)
    }

    func testShadowPolygonsClipAndLimit() {
        let noon = sun(180, 45)
        let buildings = (0..<10).map { i in rect(Double(i) * 100, 0, Double(i) * 100 + 20, 20, height: 10, id: Int64(i)) }
        let e = engine(buildings, trees: [Tree(id: 99, coordinate: geo(450, 20))])
        XCTAssertEqual(e.shadowPolygons(sun: noon, within: nil).count, 11)

        // Bbox around buildings 3 and 4 only.
        let box = BoundingBox(coordinates: [geo(290, -10), geo(430, 40)])
        XCTAssertEqual(e.shadowPolygons(sun: noon, within: box).count, 2)
        // The shadow (not the footprint) reaching into the bbox counts: buildings' shadows end at y = 30.
        let north = BoundingBox(coordinates: [geo(-50, 25), geo(440, 28)])
        XCTAssertEqual(e.shadowPolygons(sun: noon, within: north).count, 5)
        // Far away.
        let far = BoundingBox(coordinates: [geo(5000, 5000), geo(5100, 5100)])
        XCTAssertTrue(e.shadowPolygons(sun: noon, within: far).isEmpty)

        // Limit keeps those nearest the bbox centre.
        let centred = BoundingBox(coordinates: [geo(-1000, -1000), geo(1900, 1000)]) // centre x = 450
        let nearest = e.shadowPolygons(sun: noon, within: centred, maxPolygons: 2)
        XCTAssertEqual(nearest.count, 2)
        let xs = nearest.compactMap(bounds).map { ($0.minX + $0.maxX) / 2 }.sorted()
        XCTAssertEqual(xs[0], 410, accuracy: 0.1)   // building 4
        XCTAssertEqual(xs[1], 450, accuracy: 0.1)   // the tree (disc 21.6 m from the centre)
        XCTAssertTrue(e.shadowPolygons(sun: noon, within: nil, maxPolygons: 0).isEmpty)
    }

    func bounds(_ ring: [GeoCoordinate]) -> ShadeRect? {
        let pts = proj.project(ring)
        guard let b = Geometry2D.bounds(pts) else { return nil }
        return ShadeRect(minX: b.min.x, minY: b.min.y, maxX: b.max.x, maxY: b.max.y)
    }

    // MARK: - Grid traversal

    func testGridRayVisitsContiguousCellsInOrder() throws {
        let grid = try XCTUnwrap(ShadeGrid(covering: ShadeRect(minX: 0, minY: 0, maxX: 200, maxY: 100),
                                           targetCellSize: 25, maxCells: 10_000))
        XCTAssertEqual(grid.columns, 9)
        XCTAssertEqual(grid.rows, 5)
        for (origin, dir, length) in [(Point2D(x: 3, y: 4), Point2D(x: 0.8, y: 0.6), 150.0),
                                      (Point2D(x: 190, y: 90), Point2D(x: -1, y: 0), 500),
                                      (Point2D(x: 50, y: 50), Point2D(x: 0, y: -1), 30),
                                      (Point2D(x: -40, y: 10), Point2D(x: 1, y: 0), 100),
                                      (Point2D(x: 60, y: 60), Point2D.zero, 10)] {
            var ray = try XCTUnwrap(ShadeGridRay(grid: grid, origin: origin, dir: dir, length: length))
            var steps: [ShadeGridStep] = []
            while let s = ray.next() { steps.append(s) }
            XCTAssertFalse(steps.isEmpty)
            for k in 1..<max(1, steps.count) {
                XCTAssertEqual(steps[k].tEnter, steps[k - 1].tExit, accuracy: 1e-9)
                let a = steps[k - 1].cell, b = steps[k].cell
                let manhattan = abs(a % grid.columns - b % grid.columns) + abs(a / grid.columns - b / grid.columns)
                XCTAssertEqual(manhattan, 1)
            }
            // Each step's midpoint lies in its cell.
            for s in steps where s.tExit - s.tEnter > 1e-6 {
                let t = (s.tEnter + s.tExit) / 2
                XCTAssertEqual(grid.cell(containing: origin + dir * t), s.cell)
            }
        }
        XCTAssertNil(ShadeGridRay(grid: grid, origin: Point2D(x: -40, y: 10), dir: Point2D(x: -1, y: 0), length: 100))
        XCTAssertEqual(grid.column(.nan), 0)
        XCTAssertEqual(grid.row(.infinity), grid.rows - 1)
        XCTAssertNil(grid.cell(containing: Point2D(x: .nan, y: 5)))
    }

    func testFittedGridGrowsCellsForHugePolygons() throws {
        let huge = ShadeRect(minX: 0, minY: 0, maxX: 10_000, maxY: 10_000)
        let small = ShadeRect(minX: 10, minY: 10, maxX: 20, maxY: 20)
        let normal = try XCTUnwrap(ShadeGrid.fitted(to: [small, huge], padding: 1e-3, targetCellSize: 25,
                                                    maxCells: 1 << 20, maxEntries: 1 << 23))
        XCTAssertEqual(normal.cellSize, 25)
        let coarse = try XCTUnwrap(ShadeGrid.fitted(to: [small, huge], padding: 1e-3, targetCellSize: 25,
                                                    maxCells: 1 << 20, maxEntries: 5000))
        XCTAssertGreaterThan(coarse.cellSize, 25)
        XCTAssertLessThanOrEqual(coarse.cellCount, 5000)
        XCTAssertNil(ShadeGrid.fitted(to: [], padding: 0, targetCellSize: 25, maxCells: 100, maxEntries: 100))

        // A forest larger than the default grid budget still answers queries correctly.
        let forest = CanopyArea(id: 1, ring: square(-20_000, -20_000, 20_000, 20_000), height: 15)
        let e = engine([rect(0, 0, 10, 10, height: 10)], canopies: [forest])
        XCTAssertTrue(shaded(e, 500, 500, sun(180, 70)))
        XCTAssertFalse(shaded(e, 500, -19_990, sun(180, 30)))  // lit strip along the southern edge
    }

    // MARK: - Reference comparison, concurrency, performance

    func testMatchesBruteForceReference() {
        var rng = ShadeTestRNG(seed: 2024)
        let city = randomCity(&rng, buildings: 300, trees: 150, canopies: 6, extent: 400)
        let e = engine(city.buildings, trees: city.trees, canopies: city.canopies)
        let reference = ReferenceShade(city: city, projection: proj)
        var suns = [sun(0, 30), sun(90, 12), sun(180, 45), sun(270, 70), sun(45, 3), sun(180, 89.5)]
        for _ in 0..<14 { suns.append(sun(rng.uniform(0, 360), rng.uniform(0.5, 88))) }
        var shadedCount = 0, total = 0
        for s in suns {
            for _ in 0..<400 {
                let p = Point2D(x: rng.uniform(-480, 480), y: rng.uniform(-480, 480))
                let expected = reference.isShaded(p, sun: s)
                XCTAssertEqual(e.isShaded(proj.unproject(p), sun: s), expected, "p=\(p) sun=\(s)")
                if expected { shadedCount += 1 }
                total += 1
            }
        }
        // Sanity: the fixture exercises both outcomes.
        XCTAssertGreaterThan(shadedCount, total / 10)
        XCTAssertLessThan(shadedCount, total * 9 / 10)
    }

    func testConcurrentQueriesMatchSerial() {
        var rng = ShadeTestRNG(seed: 5)
        let city = randomCity(&rng, buildings: 200, trees: 100, canopies: 3, extent: 300)
        let e = engine(city.buildings, trees: city.trees, canopies: city.canopies)
        let points = (0..<2000).map { _ in proj.unproject(Point2D(x: rng.uniform(-320, 320), y: rng.uniform(-320, 320))) }
        let s = sun(150, 30)
        let serial = points.map { e.isShaded($0, sun: s) }
        let results = UnsafeMutableBufferPointer<Bool>.allocate(capacity: points.count * 4)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: 4) { w in
            for (i, p) in points.enumerated() { results[w * points.count + i] = e.isShaded(p, sun: s) }
        }
        for w in 0..<4 { XCTAssertEqual(Array(results[(w * points.count)..<((w + 1) * points.count)]), serial) }
    }

    func testPerformance2kBuildings20kSamples() {
        var rng = ShadeTestRNG(seed: 99)
        let city = randomCity(&rng, buildings: 2000, trees: 500, canopies: 4, extent: 1000)
        let start = Date()
        let e = engine(city.buildings, trees: city.trees, canopies: city.canopies)
        let built = Date()
        let points = (0..<20_000).map { _ in
            proj.unproject(Point2D(x: rng.uniform(-1000, 1000), y: rng.uniform(-1000, 1000)))
        }
        let s = sun(135, 25)
        let queryStart = Date()
        var shadedCount = 0
        for p in points where e.isShaded(p, sun: s) { shadedCount += 1 }
        let elapsed = Date().timeIntervalSince(queryStart)
        XCTAssertGreaterThan(shadedCount, 0)
        XCTAssertLessThan(elapsed + built.timeIntervalSince(start), 15)
    }

    func testIndexBuildScales() {
        var rng = ShadeTestRNG(seed: 3)
        let city = randomCity(&rng, buildings: 20_000, trees: 10_000, canopies: 0, extent: 2500)
        let start = Date()
        let e = engine(city.buildings, trees: city.trees, canopies: city.canopies)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(e.buildingCount, 20_000)
        XCTAssertEqual(e.treeCount, 10_000)
        XCTAssertLessThan(elapsed, 10)  // debug build; release target < 0.5 s
    }

    // MARK: - Random fixtures

    struct City {
        var buildings: [Building]
        var trees: [Tree]
        var canopies: [CanopyArea]
    }

    private func randomCity(_ rng: inout ShadeTestRNG, buildings nb: Int, trees nt: Int, canopies nc: Int,
                            extent: Double) -> City {
        var buildings: [Building] = []
        buildings.reserveCapacity(nb)
        for i in 0..<nb {
            let c = Point2D(x: rng.uniform(-extent, extent), y: rng.uniform(-extent, extent))
            let w = rng.uniform(5, 40), h = rng.uniform(5, 30), angle = rng.uniform(0, .pi)
            var local: [Point2D]
            if i % 5 == 0 {
                // Non-convex L shape.
                local = [Point2D(x: 0, y: 0), Point2D(x: w, y: 0), Point2D(x: w, y: h / 2), Point2D(x: w / 2, y: h / 2),
                         Point2D(x: w / 2, y: h), Point2D(x: 0, y: h)]
            } else {
                local = [Point2D(x: 0, y: 0), Point2D(x: w, y: 0), Point2D(x: w, y: h), Point2D(x: 0, y: h)]
            }
            local = local.map { p in
                Point2D(x: c.x + p.x * cos(angle) - p.y * sin(angle), y: c.y + p.x * sin(angle) + p.y * cos(angle))
            }
            let height = rng.uniform(3, 60)
            var minHeight = 0.0
            var roof = false
            switch i % 10 {
            case 3: minHeight = rng.uniform(2, height - 1)
            case 7: roof = true; minHeight = rng.next() < 0.5 ? 0 : rng.uniform(2, max(2.1, height - 0.5))
            default: break
            }
            buildings.append(Building(id: Int64(i), footprint: proj.unproject(local), height: height,
                                      minHeight: minHeight, isRoofOnly: roof))
        }
        let trees = (0..<nt).map { i in
            Tree(id: Int64(i),
                 coordinate: proj.unproject(Point2D(x: rng.uniform(-extent, extent), y: rng.uniform(-extent, extent))),
                 height: rng.uniform(3, 25), crownRadius: rng.uniform(1, 8))
        }
        let canopies = (0..<nc).map { i -> CanopyArea in
            let c = Point2D(x: rng.uniform(-extent, extent), y: rng.uniform(-extent, extent))
            let r = rng.uniform(20, 80)
            let ring = (0..<9).map { k -> Point2D in
                let a = Double(k) / 9 * 2 * .pi
                let rr = r * (k % 2 == 0 ? 1 : 0.6)
                return Point2D(x: c.x + rr * cos(a), y: c.y + rr * sin(a))
            }
            return CanopyArea(id: Int64(i), ring: proj.unproject(ring), height: rng.uniform(5, 25))
        }
        return City(buildings: buildings, trees: trees, canopies: canopies)
    }
}

/// Straightforward O(n) implementation of SPEC §4.3 (no index, no early outs) used to check the engine.
private struct ReferenceShade {
    struct B { var ring: [Point2D]; var height: Double; var minHeight: Double; var roof: Bool }
    let buildings: [B]
    let trees: [(Point2D, Tree)]
    let canopies: [([Point2D], Double)]

    init(city: ShadeEngineTests.City, projection: LocalProjection) {
        buildings = city.buildings.map { b in
            B(ring: projection.project(b.footprint), height: b.height,
              minHeight: b.isRoofOnly && b.minHeight <= 0 ? 2.5 : b.minHeight, roof: b.isRoofOnly)
        }
        trees = city.trees.map { (projection.project($0.coordinate), $0) }
        canopies = city.canopies.map { (projection.project($0.ring), $0.height) }
    }

    func isShaded(_ p: Point2D, sun: SunPosition) -> Bool {
        guard sun.elevation > 0 else { return true }
        let tanE = tan(GeoMath.radians(sun.elevation))
        let d = sun.shadowDirection, u = sun.directionToSun
        for (t, tree) in trees {
            let c = t + d * min(0.7 * tree.height / tanE, 60)
            if p.distance(to: c) <= tree.crownRadius { return true }
        }
        for (ring, h) in canopies {
            let o = d * min(0.7 * h / tanE, 30)
            if Geometry2D.contains(ring.map { $0 + o }, p) { return true }
            if sun.elevation > 60 && Geometry2D.contains(ring, p) { return true }
        }
        let maxH = buildings.map(\.height).max() ?? 0
        let reach = min(maxH / tanE, 400)
        for b in buildings {
            let inside = Geometry2D.contains(b.ring, p)
            if b.roof && inside { return true }
            var ts: [Double] = []
            for i in 0..<b.ring.count {
                let a = b.ring[i], c = b.ring[(i + 1) % b.ring.count]
                if let t = Geometry2D.raySegmentIntersection(origin: p, dir: u, a: a, b: c) {
                    ts.append(t)
                }
            }
            guard inside || !ts.isEmpty else { continue }
            let tIn = inside ? 0 : ts.min() ?? 0
            let tOut = ts.max() ?? 0
            if tIn <= reach && tIn * tanE <= b.height && tOut * tanE >= b.minHeight { return true }
        }
        return false
    }
}

/// Deterministic PRNG for fixtures (SplitMix64).
private struct ShadeTestRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    mutating func uniform(_ lo: Double, _ hi: Double) -> Double { lo + (hi - lo) * next() }
}
