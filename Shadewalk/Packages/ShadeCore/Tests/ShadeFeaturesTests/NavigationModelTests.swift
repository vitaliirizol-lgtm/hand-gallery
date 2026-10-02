import XCTest
@testable import ShadeFeatures

final class NavigationModelTests: XCTestCase {
    /// 600 m east: shade 0–100, sun 100–300, shade 300–600; left turn at 200 m.
    private static func walk(profile: RouteProfile = .shadiest) -> WalkRoute {
        Fixtures.route(id: "walk", profile: profile, length: 600, segments: [(100, true), (200, false), (300, true)],
                       maneuvers: [(.depart, 0), (.left, 200), (.arrive, 600)])
    }

    /// Alternatives starting at the point `(x, y)`.
    private static func detourPlan(fromX x: Double, y: Double) -> RoutePlan {
        Fixtures.plan([
            Fixtures.route(id: "re-shady", profile: .shadiest, length: 500, startX: x, startY: y),
            Fixtures.route(id: "re-balanced", profile: .balanced, length: 500, startX: x, startY: y),
            Fixtures.route(id: "re-fast", profile: .fastest, length: 450, startX: x, startY: y),
        ])
    }

    private func describe(_ events: [NavigationEvent]) -> [String] {
        events.map { event in
            switch event {
            case let .approachingManeuver(maneuver): return "approach:\(maneuver.kind.rawValue)"
            case let .enteredSun(length): return "sun:\(Int(length.rounded()))"
            case .enteredShade: return "shade"
            case .offRoute: return "offRoute"
            case let .rerouted(route): return "rerouted:\(route.id)"
            case .arrived: return "arrived"
            }
        }
    }

    @MainActor private func makeModel(location: FakeLocationProvider? = nil,
                                      planner: FakeRoutePlanner = FakeRoutePlanner(plan: Fixtures.plan([])),
                                      clock: TestClock = TestClock()) -> NavigationModel {
        NavigationModel(location: location ?? FakeLocationProvider(), planner: planner, now: { clock.now })
    }

    /// Walks to 90 m (still in the shade), then three fixes 50 m north of the route (accuracy 25 m) → off route.
    @MainActor private func driveOffRoute(_ model: NavigationModel) {
        model.handle(Fixtures.fix(0))
        model.handle(Fixtures.fix(90))
        model.handle(Fixtures.fix(110, 50, accuracy: 25))
        model.handle(Fixtures.fix(115, 50, accuracy: 25))
        model.handle(Fixtures.fix(120, 50, accuracy: 25))
    }

    // MARK: - Events

    @MainActor func testEventSequenceAlongSyntheticRoute() async {
        let location = FakeLocationProvider()
        let model = makeModel(location: location)
        model.start(route: Self.walk())
        XCTAssertEqual(model.status, .navigating)
        XCTAssertTrue(model.isActive)
        XCTAssertEqual(location.subscriptionCount, 1)

        for x in [0.0, 50, 105, 165, 170, 190, 250, 320, 450, 565, 590] {
            model.handle(Fixtures.fix(x))
        }
        let expected = ["sun:195", "approach:left", "shade", "approach:arrive", "arrived"]
        XCTAssertEqual(describe(model.eventLog), expected)
        XCTAssertEqual(model.lastEvent, .arrived)
        XCTAssertEqual(model.status, .arrived)
        XCTAssertFalse(model.isActive)
        XCTAssertEqual(model.progress?.hasArrived, true)
        XCTAssertEqual(model.route?.id, "walk")

        // The same events reach the stream, in order.
        var iterator = model.events.makeAsyncIterator()
        var streamed: [NavigationEvent] = []
        for _ in expected.indices {
            if let event = await iterator.next() { streamed.append(event) }
        }
        XCTAssertEqual(describe(streamed), expected)

        // Arrival ends the location subscription; later fixes are ignored.
        await waitUntil { location.terminationCount == 1 }
        let final = model.progress
        model.handle(Fixtures.fix(300))
        XCTAssertEqual(model.progress, final)
    }

    @MainActor func testProgressIsPublished() async {
        let model = makeModel()
        model.start(route: Self.walk())
        XCTAssertNil(model.progress)
        model.handle(Fixtures.fix(150, 3))
        XCTAssertEqual(model.progress?.distanceAlong ?? -1, 150, accuracy: 0.5)
        XCTAssertEqual(model.progress?.nextManeuver?.kind, .left)
        XCTAssertEqual(model.progress?.isInShade, false)
        XCTAssertEqual(model.lastFix, Fixtures.fix(150, 3))
    }

    @MainActor func testConsumesFixesFromLocationStream() async {
        let location = FakeLocationProvider()
        let model = makeModel(location: location)
        model.start(route: Self.walk())
        location.send(Fixtures.fix(0))
        await waitUntil { model.progress != nil }
        location.send(Fixtures.fix(105))
        await waitUntil { model.lastEvent != nil }
        XCTAssertEqual(describe(model.eventLog), ["sun:195"])

        model.stop()
        XCTAssertEqual(model.status, .idle)
        XCTAssertNil(model.route)
        XCTAssertNil(model.progress)
        await waitUntil { location.terminationCount == 1 }
        location.send(Fixtures.fix(320))
        await settle()
        XCTAssertNil(model.progress)
        XCTAssertEqual(model.eventLog.count, 1)
    }

    @MainActor func testStartReplacesRunningSession() async {
        let location = FakeLocationProvider()
        let model = makeModel(location: location)
        model.start(route: Self.walk())
        model.handle(Fixtures.fix(105))
        model.start(route: Fixtures.route(id: "other", length: 300))
        XCTAssertEqual(model.route?.id, "other")
        XCTAssertNil(model.progress)
        XCTAssertEqual(location.subscriptionCount, 2)
        await waitUntil { location.terminationCount == 1 }
        location.send(Fixtures.fix(10))
        await waitUntil { model.progress != nil }
        XCTAssertEqual(model.progress?.distanceAlong ?? -1, 10, accuracy: 0.5)
    }

    @MainActor func testShadeEventsAreNotEmittedWhileOffRoute() async {
        let model = makeModel(planner: FakeRoutePlanner { _, _ in throw ShadeError.noRouteFound })
        model.start(route: Self.walk())
        model.handle(Fixtures.fix(50))
        model.handle(Fixtures.fix(60, 90, accuracy: 10)) // > 80 m with good accuracy: off route at once
        model.handle(Fixtures.fix(150, 90, accuracy: 10)) // would be "entered sun" on the route
        XCTAssertEqual(model.progress?.isOffRoute, true)
        XCTAssertEqual(describe(model.eventLog), ["offRoute"])
    }

    @MainActor func testNoAnnouncementsWhileDriftingAway() async {
        let model = makeModel()
        model.start(route: Self.walk())
        model.handle(Fixtures.fix(90))
        // 50 m off the route (not yet "off route"): the snapped point is in the sun and near the turn — stay quiet.
        model.handle(Fixtures.fix(170, 50, accuracy: 25))
        XCTAssertEqual(model.progress?.isOffRoute, false)
        XCTAssertTrue(model.eventLog.isEmpty)
        // Back on the route: the pending announcements fire.
        model.handle(Fixtures.fix(175, 3))
        XCTAssertEqual(describe(model.eventLog), ["approach:left", "sun:125"])
    }

    // MARK: - Rerouting

    @MainActor func testOffRouteReroutesKeepingProfile() async throws {
        let clock = TestClock()
        let planner = FakeRoutePlanner(plan: Self.detourPlan(fromX: 120, y: 50))
        let model = makeModel(planner: planner, clock: clock)
        model.preferences = RoutingPreferences(walkingSpeed: 1.1)
        let original = Self.walk(profile: .balanced)
        model.start(route: original)
        driveOffRoute(model)

        XCTAssertEqual(describe(model.eventLog), ["offRoute"])
        XCTAssertEqual(model.status, .rerouting)
        await waitUntil { planner.recorder.callCount == 1 }
        let request = try XCTUnwrap(planner.requests.first)
        XCTAssertEqual(request.origin, Fixtures.point(120, 50))
        XCTAssertEqual(request.destination, original.destination)
        XCTAssertEqual(request.departure, clock.now)
        XCTAssertEqual(request.preferences.walkingSpeed, 1.1)

        await model.rerouteTask?.value
        XCTAssertEqual(model.route?.id, "re-balanced")
        XCTAssertEqual(describe(model.eventLog), ["offRoute", "rerouted:re-balanced"])
        XCTAssertEqual(model.status, .navigating)
        XCTAssertEqual(model.rerouteCount, 1)
        XCTAssertNil(model.rerouteErrorMessage)
        // Progress is recomputed on the new route from the latest fix.
        XCTAssertEqual(model.progress?.distanceAlong ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(model.progress?.isOffRoute, false)

        model.handle(Fixtures.fix(220, 50))
        XCTAssertEqual(model.progress?.distanceAlong ?? -1, 100, accuracy: 0.5)
    }

    @MainActor func testRerouteFallsBackToFirstRouteWhenProfileMissing() async {
        let planner = FakeRoutePlanner(plan: Fixtures.plan([
            Fixtures.route(id: "only-fast", profile: .fastest, length: 400, startX: 120, startY: 50),
        ]))
        let model = makeModel(planner: planner)
        model.start(route: Self.walk(profile: .shadiest))
        driveOffRoute(model)
        await model.rerouteTask?.value
        XCTAssertEqual(model.route?.id, "only-fast")
    }

    @MainActor func testReroutesAreThrottled() async {
        let clock = TestClock()
        let planner = FakeRoutePlanner { _, _ in throw ShadeError.networkUnavailable }
        let model = makeModel(planner: planner, clock: clock)
        model.start(route: Self.walk())
        driveOffRoute(model)
        await model.rerouteTask?.value
        XCTAssertEqual(planner.recorder.callCount, 1)
        XCTAssertEqual(model.status, .offRoute)
        XCTAssertEqual(model.rerouteErrorMessage, ShadeError.networkUnavailable.errorDescription)
        XCTAssertEqual(model.route?.id, "walk")

        model.handle(Fixtures.fix(125, 50, accuracy: 25))
        clock.advance(9)
        model.handle(Fixtures.fix(130, 50, accuracy: 25))
        XCTAssertEqual(planner.recorder.callCount, 1)

        clock.advance(1.5)
        // Off route but too inaccurate to plan from.
        model.handle(Fixtures.fix(135, 50, accuracy: 150))
        XCTAssertEqual(planner.recorder.callCount, 1)
        model.handle(Fixtures.fix(140, 50, accuracy: 25))
        XCTAssertEqual(model.status, .rerouting)
        await model.rerouteTask?.value
        XCTAssertEqual(planner.recorder.callCount, 2)
        XCTAssertEqual(planner.requests.last?.origin, Fixtures.point(140, 50))

        // Still one `.offRoute` event for the whole excursion.
        XCTAssertEqual(describe(model.eventLog), ["offRoute"])
    }

    @MainActor func testOneRerouteInFlightAtATime() async {
        let gate = AsyncGate()
        let clock = TestClock()
        let planner = FakeRoutePlanner { _, _ in
            await gate.wait()
            return Self.detourPlan(fromX: 120, y: 50)
        }
        let model = makeModel(planner: planner, clock: clock)
        model.start(route: Self.walk())
        driveOffRoute(model)
        clock.advance(30)
        model.handle(Fixtures.fix(125, 50, accuracy: 25))
        await waitUntil { planner.recorder.callCount == 1 }
        await settle()
        XCTAssertEqual(planner.recorder.callCount, 1)
        XCTAssertEqual(model.status, .rerouting)
        await gate.open()
        await model.rerouteTask?.value
        XCTAssertEqual(model.route?.id, "re-shady")
    }

    @MainActor func testStaleRerouteIsIgnoredAfterStop() async {
        let gate = AsyncGate()
        let planner = FakeRoutePlanner { _, _ in
            await gate.wait()
            return Self.detourPlan(fromX: 120, y: 50)
        }
        let model = makeModel(planner: planner)
        model.start(route: Self.walk())
        driveOffRoute(model)
        XCTAssertEqual(model.status, .rerouting)
        model.stop()
        await gate.open()
        await waitUntil { planner.recorder.completedCount == 1 }
        await settle()
        XCTAssertNil(model.route)
        XCTAssertEqual(model.status, .idle)
        XCTAssertEqual(describe(model.eventLog), ["offRoute"])
    }

    @MainActor func testReturningToRouteCancelsReroute() async {
        let gate = AsyncGate()
        let planner = FakeRoutePlanner { _, _ in
            await gate.wait()
            return Self.detourPlan(fromX: 120, y: 50)
        }
        let model = makeModel(planner: planner)
        model.start(route: Self.walk())
        driveOffRoute(model)
        model.handle(Fixtures.fix(130, 2))
        XCTAssertEqual(model.status, .navigating)
        XCTAssertEqual(model.progress?.isOffRoute, false)
        await gate.open()
        await waitUntil { planner.recorder.completedCount == 1 }
        await settle()
        XCTAssertEqual(model.route?.id, "walk")
        XCTAssertEqual(model.rerouteCount, 0)
        XCTAssertFalse(model.eventLog.contains { if case .rerouted = $0 { return true } else { return false } })
    }

    @MainActor func testEmptyReroutePlanReportsError() async {
        let model = makeModel(planner: FakeRoutePlanner(plan: Fixtures.plan([])))
        model.start(route: Self.walk())
        driveOffRoute(model)
        await model.rerouteTask?.value
        XCTAssertEqual(model.status, .offRoute)
        XCTAssertEqual(model.rerouteErrorMessage, ShadeError.noRouteFound.errorDescription)
        XCTAssertEqual(model.route?.id, "walk")
    }

    @MainActor func testHandleWithoutSessionIsIgnored() async {
        let model = makeModel()
        model.handle(Fixtures.fix(10))
        XCTAssertNil(model.progress)
        XCTAssertEqual(model.status, .idle)
        XCTAssertTrue(model.eventLog.isEmpty)
    }
}
