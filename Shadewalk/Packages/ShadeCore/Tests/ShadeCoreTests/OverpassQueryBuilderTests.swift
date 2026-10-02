import XCTest
@testable import ShadeCore

final class OverpassQueryBuilderTests: XCTestCase {
    let bbox = BoundingBox(minLatitude: 37.5690, minLongitude: 126.9745, maxLatitude: 37.5730, maxLongitude: 126.9800)

    func testAreaQueryHeaderUsesGlobalBBoxAndTimeout() {
        let q = OverpassQueryBuilder.areaQuery(for: bbox)
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:90][bbox:37.569000,126.974500,37.573000,126.980000];\n"), q)
        XCTAssertTrue(OverpassQueryBuilder.areaQuery(for: bbox, timeout: 25).hasPrefix("[out:json][timeout:25][bbox:"))
        XCTAssertTrue(OverpassQueryBuilder.areaQuery(for: bbox, timeout: 0).hasPrefix("[out:json][timeout:1][bbox:"))
        // The global bbox applies to every statement: no per-statement filters or around clauses.
        XCTAssertFalse(q.contains("(around:"))
        XCTAssertEqual(occurrences(of: "[bbox:", in: q), 1)
    }

    func testAreaQueryWalkNetworkStatement() throws {
        let q = OverpassQueryBuilder.areaQuery(for: bbox)
        let line = try XCTUnwrap(q.split(separator: "\n").first { $0.contains("way[\"highway\"~\"^(footway") })
        for value in ["footway", "pedestrian", "path", "steps", "living_street", "residential", "service",
                      "unclassified", "track", "cycleway", "bridleway", "corridor", "tertiary", "tertiary_link",
                      "secondary", "secondary_link", "primary", "primary_link"] {
            XCTAssertTrue(line.contains("|\(value)|") || line.contains("(\(value)|") || line.contains("|\(value))"),
                          "missing \(value)")
        }
        XCTAssertFalse(line.contains("motorway"))
        XCTAssertTrue(q.contains("way[\"highway\"~\"^(motorway|motorway_link|trunk|trunk_link)$\"][\"foot\"~\"^(yes|designated)$\"];"))
        // Walk network is printed with node ids and inline geometry.
        let walkBlock = try XCTUnwrap(q.range(of: "out geom qt;"))
        XCTAssertLessThan(try XCTUnwrap(q.range(of: "way[\"highway\"")).lowerBound, walkBlock.lowerBound)
    }

    func testAreaQueryContainsEveryLayerWithTheRightOutMode() {
        let q = OverpassQueryBuilder.areaQuery(for: bbox)
        let expectedInOrder = [
            "node[\"highway\"=\"crossing\"];", "node[\"crossing\"];", "node[\"highway\"=\"traffic_signals\"];", "out qt;",
            "way[\"building\"];", "relation[\"building\"][\"type\"=\"multipolygon\"];", "out geom qt;",
            "node[\"natural\"=\"tree\"];", "out qt;",
            "way[\"natural\"=\"tree_row\"];", "out geom qt;",
            "way[\"natural\"=\"wood\"];", "way[\"landuse\"=\"forest\"];",
            "relation[\"natural\"=\"wood\"][\"type\"=\"multipolygon\"];",
            "relation[\"landuse\"=\"forest\"][\"type\"=\"multipolygon\"];", "out geom qt;",
            "node[\"amenity\"~\"^(drinking_water|water_point|library|community_centre|shelter)$\"];",
            "way[\"shop\"~\"^(mall|department_store)$\"];",
            "relation[\"leisure\"=\"park\"];", "out center qt;",
        ]
        var cursor = q.startIndex
        for fragment in expectedInOrder {
            guard let r = q.range(of: fragment, range: cursor..<q.endIndex) else {
                return XCTFail("missing or out of order: \(fragment)\n\(q)")
            }
            cursor = r.upperBound
        }
        XCTAssertEqual(occurrences(of: "out geom qt;", in: q), 4)
        XCTAssertEqual(occurrences(of: "out qt;", in: q), 2)
        XCTAssertEqual(occurrences(of: "out center qt;", in: q), 1)
        XCTAssertTrue(q.hasSuffix("out center qt;"))
    }

    func testAreaQueryIsSyntacticallyBalanced() {
        for q in [OverpassQueryBuilder.areaQuery(for: bbox),
                  OverpassQueryBuilder.coolSpotQuery(near: bbox.center, radius: 800)] {
            XCTAssertEqual(occurrences(of: "(", in: q), occurrences(of: ")", in: q))
            XCTAssertEqual(occurrences(of: "[", in: q), occurrences(of: "]", in: q))
            XCTAssertEqual(occurrences(of: "\"", in: q) % 2, 0)
            // Every non-empty line is a union bracket or ends a statement.
            for line in q.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                XCTAssertTrue(t == "(" || t.hasSuffix(";"), "bad line: \(t)")
            }
        }
    }

    func testCoolSpotQueryUsesAroundFilterOnEveryStatement() {
        let center = GeoCoordinate(latitude: 37.5716, longitude: 126.9769)
        let q = OverpassQueryBuilder.coolSpotQuery(near: center, radius: 499.6)
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:30];\n"), q)
        XCTAssertFalse(q.contains("[bbox:"))
        let around = "(around:500,37.571600,126.976900);"
        XCTAssertEqual(occurrences(of: around, in: q), 9)
        for kind in ["node", "way", "relation"] {
            XCTAssertTrue(q.contains("\(kind)[\"amenity\"~\"^(drinking_water|water_point|library|community_centre|shelter)$\"]\(around)"))
            XCTAssertTrue(q.contains("\(kind)[\"shop\"~\"^(mall|department_store)$\"]\(around)"))
            XCTAssertTrue(q.contains("\(kind)[\"leisure\"=\"park\"]\(around)"))
        }
        XCTAssertTrue(q.hasSuffix("out center qt;"))
        XCTAssertTrue(OverpassQueryBuilder.coolSpotQuery(near: center, radius: 100, timeout: 12).hasPrefix("[out:json][timeout:12];"))
    }

    func testCoolSpotQueryClampsRadius() {
        let c = GeoCoordinate(latitude: -33.8688, longitude: 151.2093)
        XCTAssertTrue(OverpassQueryBuilder.coolSpotQuery(near: c, radius: 0).contains("(around:1,-33.868800,151.209300)"))
        XCTAssertTrue(OverpassQueryBuilder.coolSpotQuery(near: c, radius: -50).contains("(around:1,"))
        XCTAssertTrue(OverpassQueryBuilder.coolSpotQuery(near: c, radius: 1e9).contains("(around:50000,"))
        XCTAssertTrue(OverpassQueryBuilder.coolSpotQuery(near: c, radius: .nan).contains("(around:1000,"))
        XCTAssertTrue(OverpassQueryBuilder.coolSpotQuery(near: c, radius: .infinity).contains("(around:1000,"))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}
