import XCTest
@testable import ShadeCore

final class ElevationProfileTests: XCTestCase {
    private let t = RoutingTestGraph()

    // MARK: - Sampling

    func testSamplesEvenlyAlongLongRoute() {
        let line = [t.at(0, 0), t.at(2000, 0)]
        let samples = ElevationProfileBuilder.samplePoints(along: line)
        XCTAssertEqual(samples.count, 60)
        XCTAssertEqual(samples.first, line[0])
        XCTAssertEqual(samples.last, line[1])
        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertEqual(GeoMath.distance(a, b), 2000.0 / 59, accuracy: 0.05)
        }
    }

    func testSamplesFollowPolylineCorners() {
        let line = [t.at(0, 0), t.at(500, 0), t.at(1000, 0), t.at(1000, 1000)]
        let samples = ElevationProfileBuilder.samplePoints(along: line, maxSamples: 21)
        XCTAssertEqual(samples.count, 21)
        XCTAssertEqual(t.xy(samples[10]).distance(to: Point2D(x: 1000, y: 0)), 0, accuracy: 0.05)
        XCTAssertEqual(t.xy(samples[15]).distance(to: Point2D(x: 1000, y: 500)), 0, accuracy: 0.05)
        XCTAssertEqual(samples.last, line.last)
    }

    func testShortRouteUsesFewerSamplesAtLeastTenMetresApart() {
        let line = [t.at(0, 0), t.at(35, 0)]
        let samples = ElevationProfileBuilder.samplePoints(along: line)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(GeoMath.distance(samples[0], samples[1]), 35.0 / 3, accuracy: 0.01)
        let tiny = ElevationProfileBuilder.samplePoints(along: [t.at(0, 0), t.at(4, 0)])
        XCTAssertEqual(tiny, [t.at(0, 0), t.at(4, 0)])
    }

    func testSamplingDegenerateInput() {
        let a = t.at(0, 0), b = t.at(100, 0)
        XCTAssertEqual(ElevationProfileBuilder.samplePoints(along: []), [])
        XCTAssertEqual(ElevationProfileBuilder.samplePoints(along: [a]), [a])
        XCTAssertEqual(ElevationProfileBuilder.samplePoints(along: [a, b], maxSamples: 0), [])
        XCTAssertEqual(ElevationProfileBuilder.samplePoints(along: [a, b], maxSamples: 1), [a])
        XCTAssertEqual(ElevationProfileBuilder.samplePoints(along: [a, b], maxSamples: 2), [a, b])
        XCTAssertEqual(ElevationProfileBuilder.samplePoints(along: [a, a, a]), [a, a])
    }

    // MARK: - Profile

    func testLinearRampIsSmoothedAndBinned() {
        let elevations = (0...10).map(Double.init)
        let p = ElevationProfileBuilder.profile(elevations: elevations, totalDistance: 1000)
        XCTAssertEqual(p.sampleSpacing, 100, accuracy: 1e-9)
        XCTAssertEqual(p.elevations.count, 11)
        XCTAssertEqual(p.elevations[0], 0.5, accuracy: 1e-9) // 2-point average at the ends
        XCTAssertEqual(p.elevations[5], 5, accuracy: 1e-9)
        XCTAssertEqual(p.elevations[10], 9.5, accuracy: 1e-9)
        XCTAssertEqual(p.ascent, 9, accuracy: 1e-9)
        XCTAssertEqual(p.descent, 0, accuracy: 1e-9)
        XCTAssertEqual(p.bins.count, 10) // fewer samples than 12 bins
        XCTAssertEqual(p.bins[0].grade, 0.005, accuracy: 1e-9)
        XCTAssertEqual(p.bins[5].grade, 0.01, accuracy: 1e-9)
        XCTAssertEqual(p.bins[9].grade, 0.005, accuracy: 1e-9)
        XCTAssertEqual(p.maxGrade, 0.01, accuracy: 1e-9)
        XCTAssertEqual(p.overallCategory, .flat)
    }

    func testHillGivesSignedGradesAscentDescentAndSteepCategory() {
        let elevations: [Double] = [0, 0, 0, 0, 10, 20, 30, 20, 10, 0, 0, 0, 0]
        let p = ElevationProfileBuilder.profile(elevations: elevations, totalDistance: 120)
        XCTAssertEqual(p.bins.count, 12)
        let third = 1.0 / 3
        let expected: [Double] = [0, 0, third, 2 * third, 1, third, -third, -1, -2 * third, -third, 0, 0]
        for (bin, grade) in zip(p.bins, expected) {
            XCTAssertEqual(bin.grade, grade, accuracy: 1e-9)
        }
        XCTAssertEqual(p.ascent, 70.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(p.descent, 70.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(p.maxGrade, 1, accuracy: 1e-9)
        XCTAssertEqual(p.bins[0].category, .flat)
        XCTAssertEqual(p.bins[4].category, .steep)
        XCTAssertEqual(p.bins[7].category, .steep)
        XCTAssertEqual(p.overallCategory, .steep)
    }

    func testTwelveBinsOverManySamples() {
        // 60 samples rising 1 m every 10 m (10 % grade).
        let elevations = (0..<60).map(Double.init)
        let p = ElevationProfileBuilder.profile(elevations: elevations, totalDistance: 590)
        XCTAssertEqual(p.bins.count, 12)
        for bin in p.bins.dropFirst().dropLast() {
            XCTAssertEqual(bin.grade, 0.1, accuracy: 1e-9)
            XCTAssertEqual(bin.category, .steep)
        }
        XCTAssertLessThan(p.bins[0].grade, 0.1) // end smoothing flattens the first and last bins a little
        XCTAssertEqual(p.maxGrade, 0.1, accuracy: 1e-9)
        XCTAssertEqual(ElevationProfileBuilder.profile(elevations: elevations, totalDistance: 590, binCount: 5).bins.count, 5)
    }

    func testFewSamplesGiveFewerBins() {
        let p = ElevationProfileBuilder.profile(elevations: [10, 12, 11, 15], totalDistance: 30)
        XCTAssertEqual(p.bins.count, 3)
        XCTAssertEqual(p.sampleSpacing, 10, accuracy: 1e-9)
    }

    func testDegenerateProfiles() {
        let empty = ElevationProfileBuilder.profile(elevations: [], totalDistance: 100)
        XCTAssertEqual(empty.elevations, [])
        XCTAssertEqual(empty.bins, [])
        XCTAssertEqual(empty.maxGrade, 0)
        XCTAssertEqual(empty.overallCategory, .flat)

        let single = ElevationProfileBuilder.profile(elevations: [42], totalDistance: 100)
        XCTAssertEqual(single.elevations, [42])
        XCTAssertEqual(single.bins, [])
        XCTAssertEqual(single.ascent, 0)

        let zeroLength = ElevationProfileBuilder.profile(elevations: [1, 2, 3], totalDistance: 0)
        XCTAssertEqual(zeroLength.sampleSpacing, 0)
        XCTAssertEqual(zeroLength.bins.count, 2)
        XCTAssertTrue(zeroLength.bins.allSatisfy { $0.grade == 0 })
        XCTAssertEqual(zeroLength.maxGrade, 0)
        XCTAssertEqual(zeroLength.ascent, 1, accuracy: 1e-9)

        let invalidDistance = ElevationProfileBuilder.profile(elevations: [1, 5], totalDistance: .nan)
        XCTAssertEqual(invalidDistance.maxGrade, 0)
        XCTAssertEqual(ElevationProfileBuilder.profile(elevations: [1, 5], totalDistance: 100, binCount: 0).bins, [])
    }

    func testNonFiniteElevationsAreReplaced() {
        let p = ElevationProfileBuilder.profile(elevations: [.nan, 1, .infinity, 3], totalDistance: 30)
        XCTAssertEqual(p.elevations.count, 4)
        XCTAssertTrue(p.elevations.allSatisfy(\.isFinite))
        XCTAssertTrue(ElevationProfileBuilder.profile(elevations: [.nan, .nan], totalDistance: 10).elevations.isEmpty)
    }
}
