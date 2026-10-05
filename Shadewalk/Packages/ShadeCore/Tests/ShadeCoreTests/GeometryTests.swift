import XCTest
@testable import ShadeCore

final class GeometryTests: XCTestCase {
    let seoul = GeoCoordinate(latitude: 37.5716, longitude: 126.9769)

    func testDistanceAndBearing() {
        let north = GeoMath.destination(from: seoul, bearing: 0, distance: 1000)
        XCTAssertEqual(GeoMath.distance(seoul, north), 1000, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearing(from: seoul, to: north), 0, accuracy: 0.01)
        let east = GeoMath.destination(from: seoul, bearing: 90, distance: 500)
        XCTAssertEqual(GeoMath.distance(seoul, east), 500, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearing(from: seoul, to: east), 90, accuracy: 0.05)
    }

    func testProjectionRoundTrip() {
        let p = LocalProjection(origin: seoul)
        let c = GeoMath.destination(from: seoul, bearing: 45, distance: 300)
        let xy = p.project(c)
        XCTAssertEqual(xy.length, 300, accuracy: 0.5)
        XCTAssertEqual(xy.x, xy.y, accuracy: 0.5)
        let back = p.unproject(xy)
        XCTAssertEqual(back.latitude, c.latitude, accuracy: 1e-9)
        XCTAssertEqual(back.longitude, c.longitude, accuracy: 1e-9)
    }

    func testAngleHelpers() {
        XCTAssertEqual(GeoMath.normalizeDegrees(-90), 270)
        XCTAssertEqual(GeoMath.normalizeDegrees(720), 0)
        XCTAssertEqual(GeoMath.angleDifference(from: 350, to: 10), 20)
        XCTAssertEqual(GeoMath.angleDifference(from: 10, to: 350), -20)
    }

    func testPointInPolygonAndRay() {
        let square = [Point2D(x: 0, y: 0), Point2D(x: 10, y: 0), Point2D(x: 10, y: 10), Point2D(x: 0, y: 10)]
        XCTAssertTrue(Geometry2D.contains(square, Point2D(x: 5, y: 5)))
        XCTAssertFalse(Geometry2D.contains(square, Point2D(x: 15, y: 5)))
        let t = Geometry2D.rayPolygonEntry(origin: Point2D(x: -5, y: 5), dir: Point2D(x: 1, y: 0), ring: square)
        XCTAssertEqual(t ?? -1, 5, accuracy: 1e-9)
        XCTAssertNil(Geometry2D.rayPolygonEntry(origin: Point2D(x: -5, y: 5), dir: Point2D(x: -1, y: 0), ring: square))
        XCTAssertEqual(Geometry2D.rayPolygonEntry(origin: Point2D(x: 5, y: 5), dir: Point2D(x: 1, y: 0), ring: square), 0)
    }

    func testConvexHullAndArea() {
        let pts = [Point2D(x: 0, y: 0), Point2D(x: 2, y: 0), Point2D(x: 1, y: 1), Point2D(x: 2, y: 2), Point2D(x: 0, y: 2)]
        let hull = Geometry2D.convexHull(pts)
        XCTAssertEqual(hull.count, 4)
        XCTAssertEqual(Geometry2D.signedArea(hull), 4, accuracy: 1e-9)
        let c = Geometry2D.centroid(hull)
        XCTAssertEqual(c.x, 1, accuracy: 1e-9)
        XCTAssertEqual(c.y, 1, accuracy: 1e-9)
    }

    func testResampleAndProjection() {
        let a = seoul
        let b = GeoMath.destination(from: a, bearing: 90, distance: 100)
        let c = GeoMath.destination(from: b, bearing: 0, distance: 100)
        let line = [a, b, c]
        XCTAssertEqual(GeoMath.length(of: line), 200, accuracy: 0.5)
        let samples = GeoMath.resample(line, spacing: 10)
        XCTAssertEqual(samples.count, 21)
        XCTAssertEqual(GeoMath.distance(samples.last!, c), 0, accuracy: 0.01)
        let q = GeoMath.destination(from: GeoMath.destination(from: a, bearing: 90, distance: 40), bearing: 180, distance: 7)
        let proj = GeoMath.project(q, onto: line)!
        XCTAssertEqual(proj.distanceToLine, 7, accuracy: 0.1)
        XCTAssertEqual(proj.distanceAlong, 40, accuracy: 0.1)
        XCTAssertEqual(proj.segmentIndex, 0)
        let mid = GeoMath.coordinate(along: line, atDistance: 150)!
        XCTAssertEqual(GeoMath.distance(mid, GeoMath.destination(from: b, bearing: 0, distance: 50)), 0, accuracy: 0.1)
        let (head, tail) = GeoMath.split(line, atDistance: 150)
        XCTAssertEqual(GeoMath.length(of: head), 150, accuracy: 0.2)
        XCTAssertEqual(GeoMath.length(of: tail), 50, accuracy: 0.2)
    }

    func testBoundingBox() {
        let box = BoundingBox(coordinates: [seoul, GeoMath.destination(from: seoul, bearing: 45, distance: 1000)])!
        XCTAssertTrue(box.contains(box.center))
        let grown = box.expanded(byMeters: 100)
        XCTAssertEqual(grown.heightMeters - box.heightMeters, 200, accuracy: 1)
        XCTAssertTrue(grown.contains(box))
        let tiny = BoundingBox(coordinates: [seoul])!.ensuringMinimumSize(meters: 600)
        XCTAssertEqual(tiny.widthMeters, 600, accuracy: 1)
        XCTAssertEqual(tiny.heightMeters, 600, accuracy: 1)
        XCTAssertEqual(box.overpassString.split(separator: ",").count, 4)
    }

    func testSunVectors() {
        let noonSouth = SunPosition(azimuth: 180, elevation: 45)
        XCTAssertEqual(noonSouth.directionToSun.y, -1, accuracy: 1e-9)
        XCTAssertEqual(noonSouth.shadowDirection.y, 1, accuracy: 1e-9)
        XCTAssertEqual(noonSouth.shadowLength(forHeight: 10), 10, accuracy: 1e-9)
        XCTAssertEqual(SunPosition(azimuth: 0, elevation: -3).shadowLength(forHeight: 10), .infinity)
    }

    func testSlopeCategory() {
        XCTAssertEqual(SlopeCategory(grade: 0.01), .flat)
        XCTAssertEqual(SlopeCategory(grade: -0.03), .gentle)
        XCTAssertEqual(SlopeCategory(grade: 0.05), .moderate)
        XCTAssertEqual(SlopeCategory(grade: 0.12), .steep)
        XCTAssertTrue(SlopeCategory.flat < .steep)
    }

    func testWeatherSnapshotLookup() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func snap(_ dt: TimeInterval, _ temp: Double) -> WeatherSnapshot {
            WeatherSnapshot(time: t0.addingTimeInterval(dt), temperature: temp, apparentTemperature: nil, uvIndex: nil, cloudCover: nil, isDay: true)
        }
        let f = WeatherForecast(current: snap(0, 20), hourly: [snap(3600, 21), snap(7200, 22)])
        XCTAssertEqual(f.snapshot(at: t0.addingTimeInterval(7000))?.temperature, 22)
        XCTAssertNil(f.snapshot(at: t0.addingTimeInterval(7200 + 6000)))
    }

    func testGraphAdjacency() {
        let n = (0..<3).map { GraphNode(id: $0, osmID: Int64($0), coordinate: GeoMath.destination(from: seoul, bearing: 90, distance: Double($0) * 10)) }
        let e = [
            GraphEdge(id: 0, from: 0, to: 1, geometry: [n[0].coordinate, n[1].coordinate], length: 10, wayClass: .footway),
            GraphEdge(id: 1, from: 1, to: 2, geometry: [n[1].coordinate, n[2].coordinate], length: 10, wayClass: .steps),
        ]
        let g = WalkGraph(nodes: n, edges: e)
        XCTAssertEqual(g.neighbors(of: 1).map(\.node).sorted(), [0, 2])
        XCTAssertTrue(g.edges[1].isSteps)
        XCTAssertEqual(g.edges[0].geometry(startingAt: 1).first, n[1].coordinate)
    }

    func testNormalizeDegreesStaysBelow360() {
        XCTAssertEqual(GeoMath.normalizeDegrees(-1e-15), 0)
        XCTAssertEqual(GeoMath.normalizeDegrees(-1e-13), 360 - 1e-13)
        XCTAssertEqual(GeoMath.normalizeDegrees(720), 0)
        XCTAssertEqual(GeoMath.normalizeDegrees(-90), 270)
        XCTAssertEqual(GeoMath.angleDifference(from: 1e-15, to: 0), 0)
    }

    func testInterpolateTakesTheShortWayAcrossTheAntimeridian() {
        let a = GeoCoordinate(latitude: -18, longitude: 179.9)
        let b = GeoCoordinate(latitude: -18.2, longitude: -179.9)
        let mid = GeoMath.interpolate(a, b, fraction: 0.5)
        XCTAssertEqual(abs(mid.longitude), 180, accuracy: 1e-9)
        XCTAssertEqual(mid.latitude, -18.1, accuracy: 1e-12)
        let quarter = GeoMath.interpolate(a, b, fraction: 0.75)
        XCTAssertEqual(quarter.longitude, -179.95, accuracy: 1e-9)
        XCTAssertLessThan(GeoMath.distance(a, quarter), GeoMath.distance(a, b))
        // Ordinary segments are unchanged.
        let c = GeoCoordinate(latitude: 37.5, longitude: 126.9), d = GeoCoordinate(latitude: 37.6, longitude: 127.1)
        XCTAssertEqual(GeoMath.interpolate(c, d, fraction: 0.25),
                       GeoCoordinate(latitude: 37.5 + 0.1 * 0.25, longitude: 126.9 + (127.1 - 126.9) * 0.25))
    }
}
