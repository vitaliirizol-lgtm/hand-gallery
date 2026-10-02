import XCTest
@testable import ShadeFeatures

final class RoutePlannerModelTests: XCTestCase {
    private let home = Fixtures.place("home", 0, 0)
    private let park = Fixtures.place("park", 600, 0)
    private let cafe = Fixtures.place("cafe", 0, 400)

    private static func alternatives(_ tag: String = "") -> [WalkRoute] {
        [Fixtures.route(id: "shady\(tag)", profile: .shadiest),
         Fixtures.route(id: "balanced\(tag)", profile: .balanced),
         Fixtures.route(id: "fast\(tag)", profile: .fastest)]
    }

    @MainActor private func makeModel(_ planner: FakeRoutePlanner, clock: TestClock = TestClock()) -> RoutePlannerModel {
        RoutePlannerModel(planner: planner, debounceInterval: 0, now: { clock.now })
    }

    @MainActor func testDoesNotPlanUntilBothEndsAreSet() async {
        let planner = FakeRoutePlanner(plan: Fixtures.plan(Self.alternatives()))
        let model = makeModel(planner)
        model.origin = home
        await settle()
        XCTAssertEqual(planner.recorder.callCount, 0)
        XCTAssertTrue(model.state.isIdle)
        XCTAssertFalse(model.canPlan)
        XCTAssertNil(model.selectedRoute)
        await model.planNow()
        XCTAssertEqual(planner.recorder.callCount, 0)
    }

    @MainActor func testPlansAutomaticallyWhenBothEndsAreSet() async {
        let clock = TestClock()
        let weather = Fixtures.snapshot(Fixtures.departure)
        let spot = CoolSpot(id: 1, kind: .drinkingWater, name: "Fountain", coordinate: Fixtures.point(10, 10))
        let planner = FakeRoutePlanner(plan: Fixtures.plan(Self.alternatives(), weather: weather, coolSpots: [spot]))
        let model = makeModel(planner, clock: clock)
        model.origin = home
        model.destination = park
        XCTAssertTrue(model.state.isLoading)
        await model.pendingTask?.value

        XCTAssertEqual(planner.recorder.callCount, 1)
        let request = planner.requests[0]
        XCTAssertEqual(request.origin, home.coordinate)
        XCTAssertEqual(request.destination, park.coordinate)
        XCTAssertEqual(request.departure, clock.now)
        XCTAssertEqual(request.preferences, .default)

        XCTAssertNotNil(model.state.value)
        XCTAssertEqual(model.routes.map(\.id), ["shady", "balanced", "fast"])
        XCTAssertEqual(model.selectedRouteID, "shady")
        XCTAssertEqual(model.selectedRoute?.profile, .shadiest)
        XCTAssertEqual(model.sun, Fixtures.sun)
        XCTAssertEqual(model.weather, weather)
        XCTAssertEqual(model.coolSpots, [spot])
    }

    @MainActor func testRapidChangesCoalesceIntoOneRequest() async {
        let planner = FakeRoutePlanner(plan: Fixtures.plan(Self.alternatives()))
        let model = makeModel(planner)
        let later = Fixtures.departure.addingTimeInterval(3600)
        model.origin = home
        model.destination = cafe
        model.destination = park
        model.departure = .at(later)
        model.preferences = RoutingPreferences(walkingSpeed: 1.6)
        await model.pendingTask?.value
        await settle()
        XCTAssertEqual(planner.recorder.callCount, 1)
        XCTAssertEqual(planner.requests.first?.destination, park.coordinate)
        XCTAssertEqual(planner.requests.first?.departure, later)
        XCTAssertEqual(planner.requests.first?.preferences.walkingSpeed, 1.6)
    }

    @MainActor func testDebounceDelaysTheRequest() async {
        let planner = FakeRoutePlanner(plan: Fixtures.plan(Self.alternatives()))
        let model = RoutePlannerModel(planner: planner, debounceInterval: 0.03)
        model.origin = home
        model.destination = park
        await Task.yield()
        XCTAssertEqual(planner.recorder.callCount, 0)
        XCTAssertTrue(model.state.isLoading)
        await model.pendingTask?.value
        XCTAssertEqual(planner.recorder.callCount, 1)
        XCTAssertNotNil(model.state.value)
    }

    @MainActor func testStaleResultIsIgnored() async {
        let gate = AsyncGate()
        let planner = FakeRoutePlanner { request, index in
            if index == 0 {
                await gate.wait()
                return Fixtures.plan([Fixtures.route(id: "stale")])
            }
            return Fixtures.plan([Fixtures.route(id: "fresh")])
        }
        let model = makeModel(planner)
        model.origin = home
        model.destination = cafe
        await waitUntil { planner.recorder.callCount == 1 }
        model.destination = park
        await model.pendingTask?.value
        XCTAssertEqual(model.routes.map(\.id), ["fresh"])

        await gate.open()
        await waitUntil { planner.recorder.completedCount == 2 }
        await settle()
        XCTAssertEqual(model.routes.map(\.id), ["fresh"])
        XCTAssertEqual(model.state.value?.routes.map(\.id), ["fresh"])
    }

    @MainActor func testErrorsMapToFailedState() async {
        let planner = FakeRoutePlanner { _, _ in throw ShadeError.originTooFarFromNetwork }
        let model = makeModel(planner)
        model.origin = home
        model.destination = park
        await model.pendingTask?.value
        XCTAssertEqual(model.state.shadeError, .originTooFarFromNetwork)
        XCTAssertEqual(model.state.errorMessage, ShadeError.originTooFarFromNetwork.errorDescription)
        XCTAssertTrue(model.routes.isEmpty)

        planner.recorder.setHandler { _, _ in throw TestError(message: "Offline") }
        model.retry()
        await model.pendingTask?.value
        XCTAssertEqual(model.state.errorMessage, "Offline")
        XCTAssertNil(model.state.shadeError)
    }

    @MainActor func testRetryAfterFailureLoads() async {
        let planner = FakeRoutePlanner { _, _ in throw ShadeError.networkUnavailable }
        let model = makeModel(planner)
        model.origin = home
        model.destination = park
        await model.pendingTask?.value
        XCTAssertTrue(model.state.isFailed)

        planner.recorder.setHandler { _, _ in Fixtures.plan(Self.alternatives()) }
        model.retry()
        XCTAssertTrue(model.state.isLoading)
        await model.pendingTask?.value
        XCTAssertEqual(model.routes.count, 3)
        XCTAssertEqual(planner.recorder.callCount, 2)
    }

    @MainActor func testSwapPlansOnceWithSwappedEnds() async {
        let planner = FakeRoutePlanner(plan: Fixtures.plan(Self.alternatives()))
        let model = makeModel(planner)
        model.origin = home
        model.destination = park
        await model.pendingTask?.value
        model.swap()
        XCTAssertEqual(model.origin, park)
        XCTAssertEqual(model.destination, home)
        await model.pendingTask?.value
        await settle()
        XCTAssertEqual(planner.recorder.callCount, 2)
        XCTAssertEqual(planner.requests.last?.origin, park.coordinate)
        XCTAssertEqual(planner.requests.last?.destination, home.coordinate)
    }

    @MainActor func testClearCancelsAndResets() async {
        let gate = AsyncGate()
        let planner = FakeRoutePlanner { _, _ in
            await gate.wait()
            return Fixtures.plan([Fixtures.route(id: "late")])
        }
        let model = makeModel(planner)
        model.origin = home
        model.destination = park
        await waitUntil { planner.recorder.callCount == 1 }
        model.clear()
        XCTAssertNil(model.origin)
        XCTAssertNil(model.destination)
        XCTAssertTrue(model.state.isIdle)
        await gate.open()
        await waitUntil { planner.recorder.completedCount == 1 }
        await settle()
        XCTAssertTrue(model.state.isIdle)
        XCTAssertTrue(model.routes.isEmpty)
    }

    @MainActor func testRemovingAnEndCancelsAndGoesIdle() async {
        let planner = FakeRoutePlanner(plan: Fixtures.plan(Self.alternatives()))
        let model = makeModel(planner)
        model.origin = home
        model.destination = park
        await model.pendingTask?.value
        XCTAssertEqual(model.routes.count, 3)
        model.destination = nil
        XCTAssertTrue(model.state.isIdle)
        XCTAssertTrue(model.routes.isEmpty)
        XCTAssertNil(model.selectedRoute)
    }

    @MainActor func testSelectionSurvivesReplanByProfile() async {
        let planner = FakeRoutePlanner { _, index in Fixtures.plan(Self.alternatives("-\(index)")) }
        let model = makeModel(planner)
        model.origin = home
        model.destination = park
        await model.pendingTask?.value
        model.select(model.routes[1])
        XCTAssertEqual(model.selectedRoute?.profile, .balanced)

        // New departure → new route ids; the balanced profile stays selected and the old plan stays visible meanwhile.
        model.departure = .at(Fixtures.departure.addingTimeInterval(1800))
        XCTAssertEqual(model.routes.count, 3)
        await model.pendingTask?.value
        XCTAssertEqual(model.selectedRouteID, "balanced-1")
        XCTAssertEqual(model.selectedRoute?.profile, .balanced)
    }

    @MainActor func testSelectionFallsBackToFirstRouteWhenProfileDisappears() async {
        let planner = FakeRoutePlanner { _, index in
            index == 0 ? Fixtures.plan(Self.alternatives())
                : Fixtures.plan([Fixtures.route(id: "merged", profile: .shadiest, profiles: [.shadiest, .fastest])])
        }
        let model = makeModel(planner)
        model.origin = home
        model.destination = park
        await model.pendingTask?.value
        model.selectedRouteID = "fast"
        model.preferences = RoutingPreferences(maxDetourFraction: 0.1)
        await model.pendingTask?.value
        // The fastest profile now lives in the merged route.
        XCTAssertEqual(model.selectedRouteID, "merged")

        model.selectedRouteID = "unknown"
        XCTAssertEqual(model.selectedRoute?.id, "merged")
    }

    @MainActor func testUnchangedInputsDoNotReplan() async {
        let planner = FakeRoutePlanner(plan: Fixtures.plan(Self.alternatives()))
        let model = makeModel(planner)
        model.origin = home
        model.destination = park
        await model.pendingTask?.value
        model.origin = home
        model.preferences = .default
        model.departure = .now
        await settle()
        XCTAssertEqual(planner.recorder.callCount, 1)
        XCTAssertNotNil(model.state.value)
    }

    @MainActor func testPlanNowUsesResolvedDeparture() async {
        let clock = TestClock()
        let planner = FakeRoutePlanner(plan: Fixtures.plan(Self.alternatives()))
        let model = makeModel(planner, clock: clock)
        model.origin = home
        model.destination = park
        await model.pendingTask?.value
        clock.advance(120)
        XCTAssertEqual(model.departureDate, clock.now)
        await model.planNow()
        XCTAssertEqual(planner.requests.last?.departure, clock.now)
        XCTAssertEqual(planner.recorder.callCount, 2)
    }
}
