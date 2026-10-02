import XCTest
@testable import ShadeCore

final class SeatSideAdvisorTests: XCTestCase {
    let seoul = GeoCoordinate(latitude: 37.5665, longitude: 126.9780)
    let sydney = GeoCoordinate(latitude: -33.8688, longitude: 151.2093)
    let departure = Date(timeIntervalSince1970: 1_774_000_000)

    // MARK: - Helpers

    /// Straight path of `length` metres on `bearing`, split into `segments` pieces.
    func straightPath(from start: GeoCoordinate, bearing: Double, length: Double, segments: Int = 10) -> [GeoCoordinate] {
        (0...segments).map { GeoMath.destination(from: start, bearing: bearing, distance: length * Double($0) / Double(segments)) }
    }

    /// Closed loop of `count` points on a circle of `radius` metres (clockwise, back to the start).
    func loopPath(center: GeoCoordinate, radius: Double, count: Int = 36) -> [GeoCoordinate] {
        (0...count).map { GeoMath.destination(from: center, bearing: 360 * Double($0) / Double(count), distance: radius) }
    }

    /// Solar noon for the local day of `date` (SolarCalculator is part of this module).
    func solarNoon(_ y: Int, _ m: Int, _ d: Int, at coordinate: GeoCoordinate, tz identifier: String) throws -> Date {
        let tz = try XCTUnwrap(TimeZone(identifier: identifier))
        return SolarCalculator.sunTimes(on: try localDate(y, m, d, 12, 0, tz), coordinate: coordinate, timeZone: tz).solarNoon
    }

    func localDate(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int, _ tz: TimeZone) throws -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return try XCTUnwrap(cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)))
    }

    func assertDegenerate(_ advice: SeatSideAdvice, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(advice.recommendation, .either, file: file, line: line)
        XCTAssertEqual(advice.reason, .balanced, file: file, line: line)
        XCTAssertTrue(advice.timeline.isEmpty, file: file, line: line)
        XCTAssertEqual(advice.sunOnLeftShare, 0, file: file, line: line)
        XCTAssertEqual(advice.sunOnRightShare, 0, file: file, line: line)
        XCTAssertEqual(advice.sunDownFraction, 0, file: file, line: line)
    }

    // MARK: - Real sun scenarios

    func testEastboundAtNorthernNoonSitsLeft() throws {
        let noon = try solarNoon(2026, 3, 20, at: seoul, tz: "Asia/Seoul")
        let path = straightPath(from: seoul, bearing: 90, length: 12_000)
        let advice = SeatSideAdvisor.advise(path: path, departure: noon.addingTimeInterval(-600), duration: 1200, cloudCover: 10)
        XCTAssertEqual(advice.recommendation, .left)
        XCTAssertEqual(advice.reason, .sunMostlyOnRight)
        XCTAssertEqual(advice.sunOnRightShare, 1, accuracy: 1e-9)
        XCTAssertEqual(advice.sunOnLeftShare, 0, accuracy: 1e-9)
        XCTAssertEqual(advice.sunDownFraction, 0)
        XCTAssertEqual(advice.duration, 1200)
        XCTAssertEqual(advice.timeline.count, 41)
        XCTAssertTrue(advice.timeline.allSatisfy { $0.sunSide == .right && $0.intensity > 0.5 })
    }

    func testWestboundAtNorthernNoonSitsRight() throws {
        let noon = try solarNoon(2026, 3, 20, at: seoul, tz: "Asia/Seoul")
        let path = straightPath(from: seoul, bearing: 270, length: 12_000)
        let advice = SeatSideAdvisor.advise(path: path, departure: noon.addingTimeInterval(-600), duration: 1200, cloudCover: nil)
        XCTAssertEqual(advice.recommendation, .right)
        XCTAssertEqual(advice.reason, .sunMostlyOnLeft)
        XCTAssertEqual(advice.sunOnLeftShare, 1, accuracy: 1e-9)
        XCTAssertTrue(advice.timeline.allSatisfy { $0.sunSide == .left })
    }

    func testNorthboundInTheMorningSitsLeft() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let morning = try localDate(2026, 3, 20, 8, 0, tz)
        let path = straightPath(from: seoul, bearing: 0, length: 15_000)
        let advice = SeatSideAdvisor.advise(path: path, departure: morning, duration: 1500, cloudCover: 0)
        XCTAssertEqual(advice.recommendation, .left)
        XCTAssertEqual(advice.reason, .sunMostlyOnRight)
        XCTAssertGreaterThan(advice.sunOnRightShare, 0.99)
    }

    func testSouthernHemisphereNoonEastboundSitsRight() throws {
        let noon = try solarNoon(2026, 3, 20, at: sydney, tz: "Australia/Sydney")
        let path = straightPath(from: sydney, bearing: 90, length: 12_000)
        let advice = SeatSideAdvisor.advise(path: path, departure: noon.addingTimeInterval(-600), duration: 1200, cloudCover: nil)
        XCTAssertEqual(advice.recommendation, .right)
        XCTAssertEqual(advice.reason, .sunMostlyOnLeft)
        XCTAssertTrue(advice.timeline.allSatisfy { $0.sunSide == .left })
    }

    func testNightTripIsSunDown() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let night = try localDate(2026, 3, 20, 23, 0, tz)
        let advice = SeatSideAdvisor.advise(path: straightPath(from: seoul, bearing: 90, length: 20_000),
                                            departure: night, duration: 1800, cloudCover: 95)
        XCTAssertEqual(advice.recommendation, .either)
        XCTAssertEqual(advice.reason, .sunDown)
        XCTAssertEqual(advice.sunDownFraction, 1)
        XCTAssertEqual(advice.sunOnLeftShare, 0)
        XCTAssertEqual(advice.sunOnRightShare, 0)
        XCTAssertEqual(advice.timeline.count, 61)
        XCTAssertTrue(advice.timeline.allSatisfy { $0.sunSide == .none && $0.intensity == 0 })
    }

    func testTripAcrossSunsetCountsPartialSunDown() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let times = SolarCalculator.sunTimes(on: try localDate(2026, 3, 20, 12, 0, tz), coordinate: seoul, timeZone: tz)
        let sunset = try XCTUnwrap(times.sunset)
        // Southbound (sun in the west ⇒ right side) from 30 min before to 30 min after sunset.
        let advice = SeatSideAdvisor.advise(path: straightPath(from: seoul, bearing: 180, length: 10_000),
                                            departure: sunset.addingTimeInterval(-1800), duration: 3600, cloudCover: nil)
        XCTAssertNotEqual(advice.reason, .sunDown)
        XCTAssertEqual(advice.recommendation, .left)
        XCTAssertGreaterThan(advice.sunDownFraction, 0.35)
        XCTAssertLessThan(advice.sunDownFraction, 0.65)
        XCTAssertEqual(advice.timeline.first?.sunSide, .right)
        XCTAssertEqual(advice.timeline.last?.sunSide, SunSide.none)
    }

    func testOvercastStillFillsTimeline() throws {
        let noon = try solarNoon(2026, 3, 20, at: seoul, tz: "Asia/Seoul")
        let path = straightPath(from: seoul, bearing: 90, length: 12_000)
        let overcast = SeatSideAdvisor.advise(path: path, departure: noon, duration: 1200, cloudCover: 90)
        XCTAssertEqual(overcast.recommendation, .either)
        XCTAssertEqual(overcast.reason, .overcast)
        XCTAssertEqual(overcast.timeline.count, 41)
        XCTAssertEqual(overcast.sunOnRightShare, 1, accuracy: 1e-9)

        XCTAssertEqual(SeatSideAdvisor.advise(path: path, departure: noon, duration: 1200, cloudCover: 85).reason, .overcast)
        XCTAssertEqual(SeatSideAdvisor.advise(path: path, departure: noon, duration: 1200, cloudCover: 84.9).recommendation, .left)
        XCTAssertEqual(SeatSideAdvisor.advise(path: path, departure: noon, duration: 1200, cloudCover: .nan).recommendation, .left)
    }

    func testLoopRouteIsBalanced() throws {
        let noon = try solarNoon(2026, 3, 20, at: seoul, tz: "Asia/Seoul")
        let advice = SeatSideAdvisor.advise(path: loopPath(center: seoul, radius: 2000), departure: noon.addingTimeInterval(-900),
                                            duration: 1800, cloudCover: nil)
        XCTAssertEqual(advice.recommendation, .either)
        XCTAssertEqual(advice.reason, .balanced)
        XCTAssertEqual(advice.sunOnLeftShare + advice.sunOnRightShare, 1, accuracy: 1e-9)
        XCTAssertLessThan(abs(advice.sunOnLeftShare - advice.sunOnRightShare), SeatSideAdvisor.decisionMargin)
        XCTAssertTrue(advice.timeline.contains { $0.sunSide == .left })
        XCTAssertTrue(advice.timeline.contains { $0.sunSide == .right })
    }

    func testDefaultUsesSolarCalculator() {
        let path = straightPath(from: seoul, bearing: 45, length: 5000)
        let a = SeatSideAdvisor.advise(path: path, departure: departure, duration: 900, cloudCover: nil)
        let b = SeatSideAdvisor.advise(path: path, departure: departure, duration: 900, cloudCover: nil,
                                       sunPosition: SolarCalculator.position(at:coordinate:))
        XCTAssertEqual(a, b)
    }

    // MARK: - Injected sun

    func testSquareLoopWithFixedSunIsExactlyBalanced() {
        let a = seoul
        let b = GeoMath.destination(from: a, bearing: 90, distance: 1000)
        let c = GeoMath.destination(from: b, bearing: 0, distance: 1000)
        let d = GeoMath.destination(from: c, bearing: 270, distance: 1000)
        let advice = SeatSideAdvisor.advise(path: [a, b, c, d, a], departure: departure, duration: 1200, cloudCover: nil) { _, _ in
            SunPosition(azimuth: 180, elevation: 30)
        }
        XCTAssertEqual(advice.recommendation, .either)
        XCTAssertEqual(advice.reason, .balanced)
        XCTAssertEqual(advice.sunOnLeftShare, 0.5, accuracy: 0.03)
        let sides = Set(advice.timeline.map(\.sunSide))
        XCTAssertEqual(sides, [.right, .behind, .left, .ahead])
    }

    func testDecisionMarginBoundary() {
        // One 30 s step ⇒ exactly two samples of equal weight: right sun first, then left sun.
        let path = straightPath(from: seoul, bearing: 90, length: 500, segments: 1)
        func advice(rightCos: Double, leftCos: Double) -> SeatSideAdvice {
            SeatSideAdvisor.advise(path: path, departure: departure, duration: 30, cloudCover: nil) { date, _ in
                date == self.departure
                    ? SunPosition(azimuth: 180, elevation: GeoMath.degrees(acos(rightCos)))
                    : SunPosition(azimuth: 0, elevation: GeoMath.degrees(acos(leftCos)))
            }
        }
        let atMargin = advice(rightCos: 0.575, leftCos: 0.425)
        XCTAssertEqual(atMargin.timeline.count, 2)
        XCTAssertEqual(atMargin.sunOnRightShare, 0.575, accuracy: 1e-9)
        XCTAssertEqual(atMargin.recommendation, .left)
        XCTAssertEqual(atMargin.reason, .sunMostlyOnRight)

        let belowMargin = advice(rightCos: 0.57, leftCos: 0.43)
        XCTAssertEqual(belowMargin.recommendation, .either)
        XCTAssertEqual(belowMargin.reason, .balanced)

        let leftHeavy = advice(rightCos: 0.3, leftCos: 0.7)
        XCTAssertEqual(leftHeavy.recommendation, .right)
        XCTAssertEqual(leftHeavy.reason, .sunMostlyOnLeft)
    }

    func testSunOnlyAheadOrBehindIsBalancedWithZeroShares() {
        let path = straightPath(from: seoul, bearing: 0, length: 3000)
        let advice = SeatSideAdvisor.advise(path: path, departure: departure, duration: 600, cloudCover: nil) { date, _ in
            SunPosition(azimuth: date.timeIntervalSince(self.departure) < 300 ? 5 : 180, elevation: 20)
        }
        XCTAssertEqual(advice.recommendation, .either)
        XCTAssertEqual(advice.reason, .balanced)
        XCTAssertEqual(advice.sunOnLeftShare, 0)
        XCTAssertEqual(advice.sunOnRightShare, 0)
        XCTAssertEqual(advice.timeline.first?.sunSide, .ahead)
        XCTAssertEqual(advice.timeline.last?.sunSide, .behind)
    }

    func testSamplingSpacingAndPositions() {
        let path = straightPath(from: seoul, bearing: 90, length: 3000, segments: 3)
        var visited: [(Date, GeoCoordinate)] = []
        let advice = SeatSideAdvisor.advise(path: path, departure: departure, duration: 95, cloudCover: nil) { date, c in
            visited.append((date, c))
            return SunPosition(azimuth: 180, elevation: 45)
        }
        // ceil(95 / 30) = 4 steps of 23.75 s ⇒ 5 samples.
        XCTAssertEqual(advice.timeline.map(\.fraction), [0, 0.25, 0.5, 0.75, 1])
        for (sample, (date, coordinate)) in zip(advice.timeline, visited) {
            XCTAssertEqual(sample.time, date)
            XCTAssertEqual(sample.time.timeIntervalSince(departure), 95 * sample.fraction, accuracy: 1e-9)
            // Constant speed: the position is the same fraction of the path length.
            XCTAssertEqual(GeoMath.distance(path[0], coordinate), 3000 * sample.fraction, accuracy: 1)
            // Heading ≈ 90° (great-circle drift over 3 km is ~0.02°), so |sin rel| ≈ 1.
            XCTAssertEqual(sample.intensity, cos(GeoMath.radians(45)), accuracy: 1e-6)
        }
        XCTAssertEqual(GeoMath.distance(visited.last?.1 ?? path[0], path[3]), 0, accuracy: 0.01)

        let short = SeatSideAdvisor.advise(path: path, departure: departure, duration: 5, cloudCover: nil)
        XCTAssertEqual(short.timeline.count, 2, "at least two samples")
        let exact = SeatSideAdvisor.advise(path: path, departure: departure, duration: 90, cloudCover: nil)
        XCTAssertEqual(exact.timeline.count, 4)
    }

    func testVeryLongTripIsCapped() {
        let path = straightPath(from: seoul, bearing: 90, length: 50_000)
        let advice = SeatSideAdvisor.advise(path: path, departure: departure, duration: 10_000_000, cloudCover: nil) { _, _ in
            SunPosition(azimuth: 180, elevation: 10)
        }
        XCTAssertEqual(advice.timeline.count, SeatSideAdvisor.maxSamples)
        XCTAssertEqual(advice.timeline.last?.fraction, 1)
    }

    func testZeroLengthSegmentsAreSkippedForHeading() {
        let a = seoul
        let b = GeoMath.destination(from: a, bearing: 90, distance: 2000)
        let c = GeoMath.destination(from: b, bearing: 90, distance: 2000)
        let advice = SeatSideAdvisor.advise(path: [a, a, a, b, b, c, c], departure: departure, duration: 300, cloudCover: nil) { _, _ in
            SunPosition(azimuth: 180, elevation: 30)
        }
        XCTAssertEqual(advice.timeline.count, 11)
        XCTAssertTrue(advice.timeline.allSatisfy { $0.sunSide == .right }, "duplicate points must not yield a north (0°) heading")
        XCTAssertEqual(advice.recommendation, .left)
    }

    func testPathAcrossAntimeridianStaysLocal() {
        let a = GeoCoordinate(latitude: -16.8, longitude: 179.99)
        let b = GeoCoordinate(latitude: -16.8, longitude: -179.99)
        var longitudes: [Double] = []
        let advice = SeatSideAdvisor.advise(path: [a, b], departure: departure, duration: 120, cloudCover: nil) { _, c in
            longitudes.append(c.longitude)
            return SunPosition(azimuth: 180, elevation: 40)
        }
        XCTAssertEqual(longitudes.count, 5)
        XCTAssertTrue(longitudes.allSatisfy { abs($0) >= 179.98 && abs($0) <= 180 }, "\(longitudes)")
        XCTAssertEqual(advice.recommendation, .left, "eastbound across the date line with the sun south")
    }

    func testDegenerateInputs() {
        let path = straightPath(from: seoul, bearing: 90, length: 1000)
        assertDegenerate(SeatSideAdvisor.advise(path: [], departure: departure, duration: 600, cloudCover: nil))
        assertDegenerate(SeatSideAdvisor.advise(path: [seoul], departure: departure, duration: 600, cloudCover: nil))
        assertDegenerate(SeatSideAdvisor.advise(path: [seoul, seoul, seoul], departure: departure, duration: 600, cloudCover: nil))
        assertDegenerate(SeatSideAdvisor.advise(path: path, departure: departure, duration: 0, cloudCover: nil))
        assertDegenerate(SeatSideAdvisor.advise(path: path, departure: departure, duration: -60, cloudCover: 99))
        assertDegenerate(SeatSideAdvisor.advise(path: path, departure: departure, duration: .nan, cloudCover: nil))
        assertDegenerate(SeatSideAdvisor.advise(path: path, departure: departure, duration: .infinity, cloudCover: nil))
        let invalid = [GeoCoordinate(latitude: .nan, longitude: 0), seoul, GeoCoordinate(latitude: 91, longitude: 0)]
        assertDegenerate(SeatSideAdvisor.advise(path: invalid, departure: departure, duration: 600, cloudCover: nil))
        XCTAssertEqual(SeatSideAdvisor.advise(path: [seoul], departure: departure, duration: 600, cloudCover: nil).duration, 600)
        XCTAssertEqual(SeatSideAdvisor.advise(path: path, departure: departure, duration: -5, cloudCover: nil).duration, 0)
    }

    // MARK: - Classification

    func testClassificationBoundaries() {
        func side(_ rel: Double, heading: Double = 0, elevation: Double = 30) -> SunSide {
            SeatSideAdvisor.classify(sun: SunPosition(azimuth: GeoMath.normalizeDegrees(heading + rel), elevation: elevation),
                                     heading: heading).side
        }
        XCTAssertEqual(side(0), .ahead)
        XCTAssertEqual(side(15), .ahead)
        XCTAssertEqual(side(15.01), .right)
        XCTAssertEqual(side(90), .right)
        XCTAssertEqual(side(164.99), .right)
        XCTAssertEqual(side(165), .behind)
        XCTAssertEqual(side(180), .behind)
        XCTAssertEqual(side(195), .behind)
        XCTAssertEqual(side(195.01), .left)
        XCTAssertEqual(side(270), .left)
        XCTAssertEqual(side(344.99), .left)
        XCTAssertEqual(side(345), .ahead)
        XCTAssertEqual(side(90, heading: 300), .right, "rel wraps through north")
        XCTAssertEqual(side(90, elevation: -1), SunSide.none)
        XCTAssertEqual(side(90, elevation: 0), SunSide.none)
    }

    func testClassificationIntensity() {
        let r = SeatSideAdvisor.classify(sun: SunPosition(azimuth: 120, elevation: 60), heading: 0)
        XCTAssertEqual(r.side, .right)
        XCTAssertEqual(r.intensity, sin(GeoMath.radians(120)) * 0.5, accuracy: 1e-9)
        let l = SeatSideAdvisor.classify(sun: SunPosition(azimuth: 0, elevation: 0.5), heading: 90)
        XCTAssertEqual(l.side, .left)
        XCTAssertEqual(l.intensity, cos(GeoMath.radians(0.5)), accuracy: 1e-9)
        XCTAssertEqual(SeatSideAdvisor.classify(sun: SunPosition(azimuth: 10, elevation: 40), heading: 0).intensity, 0)
        XCTAssertEqual(SeatSideAdvisor.classify(sun: SunPosition(azimuth: 90, elevation: -5), heading: 0).intensity, 0)
        XCTAssertEqual(SeatSideAdvisor.classify(sun: SunPosition(azimuth: 90, elevation: 30), heading: .nan).side, SunSide.none)
    }
}
