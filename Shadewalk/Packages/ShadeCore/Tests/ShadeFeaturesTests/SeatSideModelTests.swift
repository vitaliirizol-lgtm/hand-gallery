import XCTest
@testable import ShadeFeatures

final class SeatSideModelTests: XCTestCase {
    private struct AdviceCall: Equatable {
        var path: [GeoCoordinate]
        var departure: Date
        var duration: TimeInterval
        var cloudCover: Double?
    }

    private static let path = DrivingPath(coordinates: [Fixtures.point(0), Fixtures.point(2000), Fixtures.point(2000, 3000)],
                                          expectedTravelTime: 600)

    private static func advice(_ side: SeatSide = .left) -> SeatSideAdvice {
        SeatSideAdvice(recommendation: side, reason: .sunMostlyOnRight, sunOnLeftShare: 0.2, sunOnRightShare: 0.8,
                       sunDownFraction: 0, timeline: [], duration: 600)
    }

    @MainActor private func makeModel(paths: FakeDrivingPathProvider, weather: FakeWeatherProvider? = nil,
                                      calls: Locked<[AdviceCall]>) -> SeatSideModel {
        let model = SeatSideModel(drivingPaths: paths, weather: weather, now: { Fixtures.departure },
                                  advise: { path, departure, duration, cloud in
                                      calls.mutate { $0.append(AdviceCall(path: path, departure: departure,
                                                                          duration: duration, cloudCover: cloud)) }
                                      return Self.advice()
                                  })
        model.from = Fixtures.place("from", 0, 0)
        model.to = Fixtures.place("to", 2000, 3000)
        return model
    }

    @MainActor func testComputeScalesDurationAndUsesCloudCover() async {
        let calls = Locked<[AdviceCall]>([])
        let paths = FakeDrivingPathProvider { _, _ in Self.path }
        let weather = FakeWeatherProvider { _, _ in Fixtures.forecast(cloudCover: 40) }
        let model = makeModel(paths: paths, weather: weather, calls: calls)
        XCTAssertEqual(model.departure, Fixtures.departure)
        XCTAssertTrue(model.canCompute)
        model.vehicle = .tram
        model.departure = Fixtures.departure.addingTimeInterval(3600)
        await model.compute()

        XCTAssertEqual(model.state, .loaded(Self.advice()))
        XCTAssertEqual(paths.recorder.requests.first?.from, Fixtures.point(0, 0))
        XCTAssertEqual(paths.recorder.requests.first?.to, Fixtures.point(2000, 3000))
        XCTAssertEqual(weather.recorder.requests, [Fixtures.point(0, 0)])
        XCTAssertEqual(calls.current, [AdviceCall(path: Self.path.coordinates,
                                                  departure: Fixtures.departure.addingTimeInterval(3600),
                                                  duration: 600 * 1.3, cloudCover: 40)])
        XCTAssertEqual(model.path, Self.path)
        XCTAssertEqual(model.tripDuration ?? 0, 780, accuracy: 1e-9)
        XCTAssertEqual(model.cloudCover, 40)
    }

    @MainActor func testWeatherIsOptionalAndFailuresAreIgnored() async {
        let calls = Locked<[AdviceCall]>([])
        let paths = FakeDrivingPathProvider { _, _ in Self.path }
        let noWeather = makeModel(paths: paths, calls: calls)
        noWeather.vehicle = .train
        await noWeather.compute()
        XCTAssertEqual(calls.current.last?.cloudCover, nil)
        XCTAssertEqual(calls.current.last?.duration ?? 0, 540, accuracy: 1e-9)

        let failing = makeModel(paths: paths, weather: FakeWeatherProvider { _, _ in throw TestError() }, calls: calls)
        await failing.compute()
        XCTAssertNotNil(failing.state.value)
        XCTAssertNil(calls.current.last?.cloudCover)
        XCTAssertEqual(calls.current.last?.duration ?? 0, 600 * 1.35, accuracy: 1e-9) // bus is the default
    }

    @MainActor func testMissingEndsStayIdle() async {
        let calls = Locked<[AdviceCall]>([])
        let paths = FakeDrivingPathProvider { _, _ in Self.path }
        let model = makeModel(paths: paths, calls: calls)
        model.to = nil
        XCTAssertFalse(model.canCompute)
        await model.compute()
        XCTAssertTrue(model.state.isIdle)
        XCTAssertEqual(paths.recorder.callCount, 0)
        XCTAssertTrue(calls.current.isEmpty)
    }

    @MainActor func testPathErrorsMapToFailedState() async {
        let calls = Locked<[AdviceCall]>([])
        let model = makeModel(paths: FakeDrivingPathProvider { _, _ in throw ShadeError.noRouteFound }, calls: calls)
        await model.compute()
        XCTAssertEqual(model.state.shadeError, .noRouteFound)
        XCTAssertTrue(calls.current.isEmpty)
    }

    @MainActor func testDegeneratePathFails() async {
        let calls = Locked<[AdviceCall]>([])
        for path in [DrivingPath(coordinates: [Fixtures.point(0)], expectedTravelTime: 600),
                     DrivingPath(coordinates: Self.path.coordinates, expectedTravelTime: 0),
                     DrivingPath(coordinates: Self.path.coordinates, expectedTravelTime: .infinity)] {
            let model = makeModel(paths: FakeDrivingPathProvider { _, _ in path }, calls: calls)
            await model.compute()
            XCTAssertEqual(model.state.shadeError, .noRouteFound)
        }
        XCTAssertTrue(calls.current.isEmpty)
    }

    @MainActor func testStaleComputationIsIgnored() async {
        let gate = AsyncGate()
        let calls = Locked<[AdviceCall]>([])
        let paths = FakeDrivingPathProvider { _, index in
            if index == 0 { await gate.wait() }
            return Self.path
        }
        let model = makeModel(paths: paths, calls: calls)
        let first = Task { await model.compute() }
        await waitUntil { paths.recorder.callCount == 1 }
        model.vehicle = .train
        await model.compute()
        await gate.open()
        await first.value
        XCTAssertEqual(calls.current.count, 1)
        XCTAssertEqual(calls.current.first?.duration ?? 0, 540, accuracy: 1e-9)
        XCTAssertEqual(model.tripDuration ?? 0, 540, accuracy: 1e-9)
    }

    @MainActor func testChangingInputsInvalidatesAdvice() async {
        let calls = Locked<[AdviceCall]>([])
        let model = makeModel(paths: FakeDrivingPathProvider { _, _ in Self.path }, calls: calls)
        await model.compute()
        XCTAssertNotNil(model.state.value)
        model.vehicle = .bus // unchanged
        XCTAssertNotNil(model.state.value)
        model.vehicle = .tram
        XCTAssertTrue(model.state.isIdle)
        XCTAssertNil(model.path)
        XCTAssertNil(model.tripDuration)

        await model.compute()
        model.departure = model.departure.addingTimeInterval(60)
        XCTAssertTrue(model.state.isIdle)
        await model.compute()
        model.to = Fixtures.place("elsewhere", 10, 10)
        XCTAssertTrue(model.state.isIdle)
    }

    @MainActor func testInputChangeDropsInFlightResult() async {
        let gate = AsyncGate()
        let calls = Locked<[AdviceCall]>([])
        let paths = FakeDrivingPathProvider { _, _ in
            await gate.wait()
            return Self.path
        }
        let model = makeModel(paths: paths, calls: calls)
        let running = Task { await model.compute() }
        await waitUntil { paths.recorder.callCount == 1 }
        model.from = Fixtures.place("moved", 5, 5)
        await gate.open()
        await running.value
        XCTAssertTrue(model.state.isIdle)
        XCTAssertTrue(calls.current.isEmpty)
    }

    @MainActor func testSwap() async {
        let calls = Locked<[AdviceCall]>([])
        let model = makeModel(paths: FakeDrivingPathProvider { _, _ in Self.path }, calls: calls)
        model.swap()
        XCTAssertEqual(model.from?.id, "to")
        XCTAssertEqual(model.to?.id, "from")
    }
}
