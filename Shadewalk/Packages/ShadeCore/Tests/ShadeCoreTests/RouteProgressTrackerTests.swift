import XCTest
@testable import ShadeCore

final class RouteProgressTrackerTests: XCTestCase {
    private let origin = GeoCoordinate(latitude: 37.5665, longitude: 126.9780)
    private var projection: LocalProjection { LocalProjection(origin: origin) }

    // MARK: - Helpers

    /// Coordinate `x` metres east and `y` metres north of `origin`.
    private func pt(_ x: Double, _ y: Double = 0) -> GeoCoordinate {
        projection.unproject(Point2D(x: x, y: y))
    }

    private func fix(_ x: Double, _ y: Double = 0, accuracy: Double = 5, course: Double? = nil) -> LocationFix {
        LocationFix(coordinate: pt(x, y), horizontalAccuracy: accuracy, course: course,
                    timestamp: Date(timeIntervalSince1970: 1_750_000_000))
    }

    private func route(_ points: [GeoCoordinate], segments: [(Double, Bool)] = [], maneuvers: [Maneuver] = [],
                       duration: TimeInterval? = nil, sunUp: Bool = true, shadeFraction: Double = 0.5) -> WalkRoute {
        let length = GeoMath.length(of: points)
        return WalkRoute(
            id: "test", profile: .shadiest, profiles: [.shadiest], coordinates: points,
            segments: segments.map { RouteSegment(coordinates: [], length: $0.0, isShaded: $0.1) },
            distance: length, duration: duration ?? length / 1.35, stepCount: Int(length / 0.74),
            shadeFraction: shadeFraction, shadedDistance: length * shadeFraction,
            sunnyDistance: length * (1 - shadeFraction), shadedDuration: 0, sunnyDuration: 0, crossingCount: 0,
            stairsCount: 0, underpassCount: 0, maneuvers: maneuvers,
            departure: Date(timeIntervalSince1970: 1_750_000_000),
            sun: SunPosition(azimuth: 180, elevation: sunUp ? 45 : -10))
    }

    /// Straight route due east, `length` metres, a vertex every 50 m.
    private func straight(_ length: Double = 1000, segments: [(Double, Bool)] = [], maneuvers: [Maneuver] = [],
                          duration: TimeInterval? = nil) -> WalkRoute {
        route(stride(from: 0, through: length, by: 50).map { pt($0) }, segments: segments, maneuvers: maneuvers,
              duration: duration)
    }

    // MARK: - Projection & metrics

    func testProjectsFixesAlongStraightRoute() {
        var tracker = RouteProgressTracker(route: straight(1000, duration: 800))
        XCTAssertEqual(tracker.totalLength, 1000, accuracy: 0.5)
        XCTAssertNil(tracker.lastProgress)

        var p = tracker.update(with: fix(0))
        XCTAssertEqual(p.distanceAlong, 0, accuracy: 0.5)
        XCTAssertEqual(p.fractionCompleted, 0, accuracy: 0.001)

        p = tracker.update(with: fix(120, 3))
        XCTAssertEqual(p.distanceAlong, 120, accuracy: 0.5)
        XCTAssertEqual(p.distanceFromRoute, 3, accuracy: 0.2)

        p = tracker.update(with: fix(250, -10))
        XCTAssertEqual(p.distanceAlong, 250, accuracy: 0.5)
        XCTAssertEqual(p.remainingDistance, 750, accuracy: 0.5)
        XCTAssertEqual(p.fractionCompleted, 0.25, accuracy: 0.001)
        XCTAssertEqual(p.remainingDuration, 600, accuracy: 0.5)
        XCTAssertEqual(p.distanceFromRoute, 10, accuracy: 0.2)
        XCTAssertLessThan(GeoMath.distance(p.snappedCoordinate, pt(250)), 0.5)
        XCTAssertFalse(p.isOffRoute)
        XCTAssertFalse(p.hasArrived)
        XCTAssertEqual(tracker.lastProgress, p)
    }

    func testFallsBackToWholeRouteWhenWindowedMatchIsFar() {
        var tracker = RouteProgressTracker(route: straight(1000))
        _ = tracker.update(with: fix(0))
        // 600 m ahead is outside the [−30, 150] window; the windowed match is 450 m away → whole-route search.
        let p = tracker.update(with: fix(600, 4))
        XCTAssertEqual(p.distanceAlong, 600, accuracy: 0.5)
        XCTAssertEqual(p.distanceFromRoute, 4, accuracy: 0.2)
    }

    func testWindowedMatchWithin50MetresIsKept() {
        var tracker = RouteProgressTracker(route: straight(1000))
        _ = tracker.update(with: fix(0))
        // 200 m ahead: the window ends at 150 m, exactly 50 m away → no fallback yet.
        let p = tracker.update(with: fix(200))
        XCTAssertEqual(p.distanceAlong, 150, accuracy: 0.5)
        XCTAssertEqual(p.distanceFromRoute, 50, accuracy: 0.5)
        // The next fix catches up.
        XCTAssertEqual(tracker.update(with: fix(210)).distanceAlong, 210, accuracy: 0.5)
    }

    func testParallelLegDoesNotPullProgressAhead() {
        // U-turn: east 300 m, north 20 m, back west 300 m. The return leg runs 20 m from the first one.
        let u = route([pt(0), pt(300), pt(300, 20), pt(0, 20)])
        var tracker = RouteProgressTracker(route: u)
        _ = tracker.update(with: fix(0))
        // 12 m north of the first leg = 8 m from the return leg; the window keeps us on the first leg.
        var p = tracker.update(with: fix(20, 12))
        XCTAssertEqual(p.distanceAlong, 20, accuracy: 0.5)
        XCTAssertEqual(p.distanceFromRoute, 12, accuracy: 0.2)

        p = tracker.update(with: fix(150, 1))
        XCTAssertEqual(p.distanceAlong, 150, accuracy: 0.5)
        p = tracker.update(with: fix(299, 2))
        XCTAssertEqual(p.distanceAlong, 299, accuracy: 1)
        p = tracker.update(with: fix(301, 15))
        XCTAssertEqual(p.distanceAlong, 315, accuracy: 1)
        p = tracker.update(with: fix(250, 21))
        XCTAssertEqual(p.distanceAlong, 370, accuracy: 1)
        p = tracker.update(with: fix(200, 19))
        XCTAssertEqual(p.distanceAlong, 420, accuracy: 1)
        // Now 1 m from the return leg and 19 m from the first leg: progress follows the return leg.
        p = tracker.update(with: fix(100, 19))
        XCTAssertEqual(p.distanceAlong, 520, accuracy: 1)
        XCTAssertEqual(p.distanceFromRoute, 1, accuracy: 0.2)
    }

    func testWindowAheadScalesWithAccuracy() {
        let u = route([pt(0), pt(300), pt(300, 20), pt(0, 20)])
        // 200 m along the first leg but 11 m off it — the return leg (9 m away) is closer.
        var precise = RouteProgressTracker(route: u)
        _ = precise.update(with: fix(0))
        // Window [−30, 150]: the windowed match is ~51 m away → whole-route search picks the closer return leg.
        XCTAssertEqual(precise.update(with: fix(200, 11, accuracy: 5)).distanceAlong, 420, accuracy: 1)

        var coarse = RouteProgressTracker(route: u)
        _ = coarse.update(with: fix(0))
        // Accuracy 80 m → window [−30, 240] contains the true position 11 m away; no fallback.
        XCTAssertEqual(coarse.update(with: fix(200, 11, accuracy: 80)).distanceAlong, 200, accuracy: 1)
    }

    func testOverlappingOutAndBackUsesCourseThenProgress() {
        // Spur: east 100 m, north 60 m and back the same way, then east 200 m.
        let spur = route([pt(0), pt(100), pt(100, 60), pt(100, 0), pt(300)])
        var tracker = RouteProgressTracker(route: spur)
        _ = tracker.update(with: fix(90))
        // Entering the spur: both passes are 0 m away; the one nearest the current progress wins.
        XCTAssertEqual(tracker.update(with: fix(100, 20)).distanceAlong, 120, accuracy: 1)
        XCTAssertEqual(tracker.update(with: fix(100, 50)).distanceAlong, 150, accuracy: 1)

        // Turning back before the tip while heading south: the course selects the return pass.
        var southbound = tracker
        XCTAssertEqual(southbound.update(with: fix(100, 45, course: 180)).distanceAlong, 175, accuracy: 1)
        XCTAssertEqual(southbound.update(with: fix(100, 20, course: 180)).distanceAlong, 200, accuracy: 1)
        XCTAssertEqual(southbound.update(with: fix(150, 0, course: 90)).distanceAlong, 270, accuracy: 1)

        // Still heading north: stays on the outbound pass (passes ≤ 10 m apart along the route aren't told apart).
        var northbound = tracker
        XCTAssertEqual(northbound.update(with: fix(100, 52, course: 0)).distanceAlong, 152, accuracy: 1)
    }

    // MARK: - Jitter

    func testProgressNeverFallsMoreThan15MetresBehind() {
        var tracker = RouteProgressTracker(route: straight(1000))
        _ = tracker.update(with: fix(0))
        _ = tracker.update(with: fix(150))
        XCTAssertEqual(tracker.update(with: fix(300)).distanceAlong, 300, accuracy: 0.5)
        // Small jitter back is accepted.
        XCTAssertEqual(tracker.update(with: fix(290)).distanceAlong, 290, accuracy: 0.5)
        // Further back snaps to 15 m behind the furthest point and reads as distance from the route.
        let p = tracker.update(with: fix(250))
        XCTAssertEqual(p.distanceAlong, 285, accuracy: 0.5)
        XCTAssertEqual(p.distanceFromRoute, 35, accuracy: 0.5)
        XCTAssertLessThan(GeoMath.distance(p.snappedCoordinate, pt(285)), 0.5)
        // Moving forward again resumes normally.
        XCTAssertEqual(tracker.update(with: fix(320)).distanceAlong, 320, accuracy: 0.5)
    }

    // MARK: - Off-route

    func testOffRouteAfterThreeConsecutiveFarFixes() {
        var tracker = RouteProgressTracker(route: straight(1000))
        _ = tracker.update(with: fix(100))
        XCTAssertFalse(tracker.update(with: fix(110, 40, accuracy: 25)).isOffRoute)
        XCTAssertFalse(tracker.update(with: fix(120, 40, accuracy: 25)).isOffRoute)
        let third = tracker.update(with: fix(130, 40, accuracy: 25))
        XCTAssertTrue(third.isOffRoute)
        XCTAssertEqual(third.distanceFromRoute, 40, accuracy: 0.5)
        XCTAssertTrue(tracker.update(with: fix(135, 45, accuracy: 25)).isOffRoute)
        // Back within 35 m clears it.
        XCTAssertFalse(tracker.update(with: fix(140, 5)).isOffRoute)
        // The counter restarts.
        XCTAssertFalse(tracker.update(with: fix(150, 40, accuracy: 25)).isOffRoute)
    }

    func testFarFixResetsWhenBackOnRouteBetween() {
        var tracker = RouteProgressTracker(route: straight(1000))
        _ = tracker.update(with: fix(100))
        _ = tracker.update(with: fix(110, 40, accuracy: 25))
        _ = tracker.update(with: fix(120, 40, accuracy: 25))
        _ = tracker.update(with: fix(125, 10, accuracy: 25))
        XCTAssertFalse(tracker.update(with: fix(130, 40, accuracy: 25)).isOffRoute)
        XCTAssertFalse(tracker.update(with: fix(140, 40, accuracy: 25)).isOffRoute)
        XCTAssertTrue(tracker.update(with: fix(150, 40, accuracy: 25)).isOffRoute)
    }

    func testImmediateOffRouteOnlyWithGoodAccuracy() {
        var precise = RouteProgressTracker(route: straight(1000))
        _ = precise.update(with: fix(100))
        XCTAssertTrue(precise.update(with: fix(110, 90, accuracy: 10)).isOffRoute)

        var coarse = RouteProgressTracker(route: straight(1000))
        _ = coarse.update(with: fix(100))
        XCTAssertFalse(coarse.update(with: fix(110, 90, accuracy: 30)).isOffRoute)
        XCTAssertFalse(coarse.update(with: fix(115, 90, accuracy: 30)).isOffRoute)
        XCTAssertTrue(coarse.update(with: fix(120, 90, accuracy: 30)).isOffRoute)
    }

    func testInaccurateAndInvalidFixesAreIgnoredForOffRoute() {
        var tracker = RouteProgressTracker(route: straight(1000))
        _ = tracker.update(with: fix(100))
        _ = tracker.update(with: fix(110, 40, accuracy: 10))
        // > 100 m accuracy: progress still moves, the far-fix counter neither grows nor resets.
        let coarse = tracker.update(with: fix(120, 40, accuracy: 150))
        XCTAssertEqual(coarse.distanceAlong, 120, accuracy: 0.5)
        XCTAssertFalse(coarse.isOffRoute)
        // Negative accuracy: no usable position, nothing changes.
        let invalid = tracker.update(with: fix(600, 0, accuracy: -1))
        XCTAssertEqual(invalid.distanceAlong, 120, accuracy: 0.5)
        XCTAssertFalse(invalid.isOffRoute)
        XCTAssertFalse(tracker.update(with: fix(130, 40, accuracy: 10)).isOffRoute)
        XCTAssertTrue(tracker.update(with: fix(140, 40, accuracy: 10)).isOffRoute)
        // An inaccurate fix back on the route doesn't clear it either.
        XCTAssertTrue(tracker.update(with: fix(145, 0, accuracy: 120)).isOffRoute)
        XCTAssertFalse(tracker.update(with: fix(150, 0, accuracy: 10)).isOffRoute)
    }

    func testInvalidCoordinateIsIgnored() {
        var tracker = RouteProgressTracker(route: straight(1000))
        _ = tracker.update(with: fix(100))
        _ = tracker.update(with: fix(200))
        let bad = LocationFix(coordinate: GeoCoordinate(latitude: .nan, longitude: 200), horizontalAccuracy: 5)
        let p = tracker.update(with: bad)
        XCTAssertEqual(p.distanceAlong, 200, accuracy: 0.5)
        XCTAssertFalse(p.isOffRoute)
    }

    // MARK: - Arrival

    func testArrivesWithin20MetresOfDestination() {
        var tracker = RouteProgressTracker(route: straight(500))
        _ = tracker.update(with: fix(400))
        XCTAssertFalse(tracker.update(with: fix(470)).hasArrived) // 30 m away, 94 %
        // An inaccurate fix doesn't decide arrival.
        XCTAssertFalse(tracker.update(with: fix(482, 0, accuracy: 150)).hasArrived)
        let p = tracker.update(with: fix(482)) // 18 m away, 96.4 %
        XCTAssertTrue(p.hasArrived)
        XCTAssertLessThan(p.fractionCompleted, 0.98)
        // Sticky, and never off route afterwards.
        let later = tracker.update(with: fix(400, 200, accuracy: 5))
        XCTAssertTrue(later.hasArrived)
        XCTAssertFalse(later.isOffRoute)
    }

    func testArrivesAt98PercentProgress() {
        var tracker = RouteProgressTracker(route: straight(2000))
        _ = tracker.update(with: fix(1900))
        XCTAssertFalse(tracker.update(with: fix(1950)).hasArrived) // 97.5 %
        let p = tracker.update(with: fix(1965, 10)) // 98.25 %, ~36 m from the destination
        XCTAssertTrue(p.hasArrived)
    }

    // MARK: - Maneuvers

    func testNextManeuverSkipsPassedOnes() {
        let maneuvers = [
            Maneuver(kind: .depart, streetName: nil, distanceFromStart: 0, coordinate: pt(0)),
            Maneuver(kind: .left, streetName: "Elm", distanceFromStart: 400, coordinate: pt(400)),
            Maneuver(kind: .arrive, streetName: nil, distanceFromStart: 1000, coordinate: pt(1000)),
            Maneuver(kind: .right, streetName: "Oak", distanceFromStart: 700, coordinate: pt(700)),
        ]
        var tracker = RouteProgressTracker(route: straight(1000, maneuvers: maneuvers))
        var p = tracker.update(with: fix(100))
        XCTAssertEqual(p.nextManeuver?.kind, .left)
        XCTAssertEqual(p.distanceToNextManeuver ?? -1, 300, accuracy: 0.5)
        p = tracker.update(with: fix(397))
        XCTAssertEqual(p.nextManeuver?.kind, .left)
        XCTAssertEqual(p.distanceToNextManeuver ?? -1, 3, accuracy: 0.5)
        p = tracker.update(with: fix(399))
        XCTAssertEqual(p.nextManeuver?.kind, .right)
        XCTAssertEqual(p.distanceToNextManeuver ?? -1, 301, accuracy: 0.5)
        p = tracker.update(with: fix(550))
        p = tracker.update(with: fix(700))
        XCTAssertEqual(p.nextManeuver?.kind, .arrive)
    }

    func testNoManeuversGivesNil() {
        var tracker = RouteProgressTracker(route: straight(300))
        let p = tracker.update(with: fix(10))
        XCTAssertNil(p.nextManeuver)
        XCTAssertNil(p.distanceToNextManeuver)
    }

    // MARK: - Shade

    func testShadeStateAlongRoute() {
        let segments: [(Double, Bool)] = [(200, true), (150, false), (350, true), (300, false)]
        var tracker = RouteProgressTracker(route: straight(1000, segments: segments))

        var p = tracker.update(with: fix(100))
        XCTAssertTrue(p.isInShade)
        XCTAssertEqual(p.distanceToNextSun ?? -1, 100, accuracy: 0.5)
        XCTAssertEqual(p.nextSunLength ?? -1, 150, accuracy: 0.5)
        XCTAssertEqual(p.remainingShadedDistance, 450, accuracy: 0.5)
        XCTAssertEqual(p.remainingSunnyDistance, 450, accuracy: 0.5)

        p = tracker.update(with: fix(240))
        XCTAssertFalse(p.isInShade)
        XCTAssertEqual(p.distanceToNextSun ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(p.nextSunLength ?? -1, 110, accuracy: 0.5) // rest of the current sunny run
        XCTAssertEqual(p.remainingShadedDistance, 350, accuracy: 0.5)
        XCTAssertEqual(p.remainingSunnyDistance, 410, accuracy: 0.5)

        p = tracker.update(with: fix(380))
        p = tracker.update(with: fix(500))
        XCTAssertTrue(p.isInShade)
        XCTAssertEqual(p.distanceToNextSun ?? -1, 200, accuracy: 0.5)
        XCTAssertEqual(p.nextSunLength ?? -1, 300, accuracy: 0.5)

        p = tracker.update(with: fix(620))
        p = tracker.update(with: fix(750))
        p = tracker.update(with: fix(800))
        XCTAssertFalse(p.isInShade)
        XCTAssertEqual(p.nextSunLength ?? -1, 200, accuracy: 0.5)
        XCTAssertEqual(p.remainingShadedDistance, 0, accuracy: 0.5)
        XCTAssertEqual(p.remainingSunnyDistance, 200, accuracy: 0.5)
    }

    func testNoSunAheadGivesNil() {
        var tracker = RouteProgressTracker(route: straight(500, segments: [(200, false), (300, true)]))
        _ = tracker.update(with: fix(100))
        let p = tracker.update(with: fix(250))
        XCTAssertTrue(p.isInShade)
        XCTAssertNil(p.distanceToNextSun)
        XCTAssertNil(p.nextSunLength)
        XCTAssertEqual(p.remainingSunnyDistance, 0, accuracy: 0.001)
        XCTAssertEqual(p.remainingShadedDistance, 250, accuracy: 0.5)
    }

    func testShadeRunsMergeAndScaleToPolylineLength() {
        // Segment lengths sum to 500 m on a 1000 m polyline: runs are scaled ×2 and adjacent shaded runs merged.
        let r = straight(1000, segments: [(100, true), (100, true), (0, false), (300, false)])
        let runs = RouteShadeRuns(route: r)
        XCTAssertEqual(runs.runs.count, 2)
        XCTAssertEqual(runs.runs[0].end, 400, accuracy: 0.5)
        XCTAssertTrue(runs.runs[0].isShaded)
        XCTAssertEqual(runs.runs[1].end, runs.totalLength, accuracy: 1e-9)
        XCTAssertEqual(runs.runIndex(at: 400), 1)
        XCTAssertEqual(runs.runIndex(at: 399.9), 0)
        XCTAssertEqual(runs.runIndex(at: -5), 0)
        XCTAssertEqual(runs.runIndex(at: 5000), 1)
        let state = runs.state(at: 600)
        XCTAssertFalse(state.isInShade)
        XCTAssertEqual(state.nextSunLength ?? -1, 400, accuracy: 0.5)
    }

    func testShadeWithoutSegmentsFallsBackToSunAndShadeFraction() {
        let night = route([pt(0), pt(300)], sunUp: false, shadeFraction: 0)
        let nightState = RouteShadeRuns(route: night).state(at: 100)
        XCTAssertTrue(nightState.isInShade)
        XCTAssertNil(nightState.distanceToNextSun)
        XCTAssertEqual(nightState.remainingShadedDistance, 200, accuracy: 0.5)

        let sunny = route([pt(0), pt(300)], shadeFraction: 0.2)
        let sunnyState = RouteShadeRuns(route: sunny).state(at: 100)
        XCTAssertFalse(sunnyState.isInShade)
        XCTAssertEqual(sunnyState.nextSunLength ?? -1, 200, accuracy: 0.5)
    }

    // MARK: - Degenerate routes

    func testEmptyRouteIsArrivedWithoutCrashing() {
        var tracker = RouteProgressTracker(route: route([]))
        let p = tracker.update(with: fix(10))
        XCTAssertTrue(p.hasArrived)
        XCTAssertEqual(p.distanceAlong, 0)
        XCTAssertEqual(p.remainingDistance, 0)
        XCTAssertEqual(p.fractionCompleted, 1)
        XCTAssertNil(p.nextManeuver)
    }

    func testSingleCoordinateRoute() {
        var tracker = RouteProgressTracker(route: route([pt(0)]))
        let p = tracker.update(with: fix(30))
        XCTAssertEqual(p.distanceAlong, 0)
        XCTAssertEqual(p.distanceFromRoute, 30, accuracy: 0.5)
        XCTAssertEqual(p.fractionCompleted, 1)
        XCTAssertTrue(p.hasArrived)
    }

    func testDuplicateVerticesAreHandled() {
        var tracker = RouteProgressTracker(route: route([pt(0), pt(0), pt(100), pt(100), pt(100), pt(200)]))
        XCTAssertEqual(tracker.totalLength, 200, accuracy: 0.5)
        XCTAssertEqual(tracker.update(with: fix(50, 2)).distanceAlong, 50, accuracy: 0.5)
        XCTAssertEqual(tracker.update(with: fix(100, 2)).distanceAlong, 100, accuracy: 0.5)
        XCTAssertEqual(tracker.update(with: fix(150, 2)).distanceAlong, 150, accuracy: 0.5)
    }

    func testCustomConfiguration() {
        var config = RouteProgressTracker.Configuration()
        config.offRouteFixCount = 1
        config.offRouteDistance = 10
        var tracker = RouteProgressTracker(route: straight(1000), configuration: config)
        _ = tracker.update(with: fix(100))
        XCTAssertTrue(tracker.update(with: fix(110, 12, accuracy: 30)).isOffRoute)
        XCTAssertEqual(tracker.configuration, config)
    }
}
