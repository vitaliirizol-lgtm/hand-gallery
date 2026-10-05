import XCTest
@testable import ShadeFeatures

final class WeatherModelTests: XCTestCase {
    @MainActor func testLoadPublishesForecast() async {
        let clock = TestClock()
        let provider = FakeWeatherProvider { _, _ in Fixtures.forecast(temperature: 31) }
        let model = WeatherModel(provider: provider, now: { clock.now })
        XCTAssertNil(model.current)
        await model.load(at: Fixtures.origin)
        XCTAssertEqual(model.state.value, Fixtures.forecast(temperature: 31))
        XCTAssertEqual(model.forecast, Fixtures.forecast(temperature: 31))
        XCTAssertEqual(model.forecastCoordinate, Fixtures.origin)
        XCTAssertEqual(model.lastUpdated, clock.now)
        XCTAssertEqual(model.current?.temperature, 31)
        XCTAssertEqual(model.snapshot(at: Fixtures.departure.addingTimeInterval(2 * 3600))?.time,
                       Fixtures.departure.addingTimeInterval(2 * 3600))
    }

    @MainActor func testNearbyReloadsAreThrottledForTenMinutes() async {
        let clock = TestClock()
        let provider = FakeWeatherProvider { _, _ in Fixtures.forecast() }
        let model = WeatherModel(provider: provider, now: { clock.now })
        await model.load(at: Fixtures.origin)
        clock.advance(300)
        await model.load(at: Fixtures.point(600, 0)) // 600 m away, 5 min later
        XCTAssertEqual(provider.recorder.callCount, 1)

        clock.advance(301) // > 10 min since the load
        await model.load(at: Fixtures.point(600, 0))
        XCTAssertEqual(provider.recorder.callCount, 2)

        await model.load(at: Fixtures.point(600, 0), force: true)
        XCTAssertEqual(provider.recorder.callCount, 3)
    }

    @MainActor func testDistantCoordinateLoadsAndClearsOldForecast() async {
        let gate = AsyncGate()
        let clock = TestClock()
        let provider = FakeWeatherProvider { _, index in
            if index == 1 { await gate.wait() }
            return Fixtures.forecast(temperature: index == 0 ? 25 : 18)
        }
        let model = WeatherModel(provider: provider, now: { clock.now })
        await model.load(at: Fixtures.origin)
        let far = Task { await model.load(at: Fixtures.point(5000, 0)) }
        await waitUntil { provider.recorder.callCount == 2 }
        XCTAssertNil(model.forecast) // the old area's forecast isn't shown for the new one
        XCTAssertTrue(model.state.isLoading)
        await gate.open()
        await far.value
        XCTAssertEqual(model.current?.temperature, 18)
        XCTAssertEqual(model.forecastCoordinate, Fixtures.point(5000, 0))
    }

    @MainActor func testFailureKeepsLastForecastForSameArea() async {
        let clock = TestClock()
        let provider = FakeWeatherProvider { _, index in
            if index == 0 { return Fixtures.forecast(temperature: 29) }
            throw ShadeError.networkUnavailable
        }
        let model = WeatherModel(provider: provider, now: { clock.now })
        await model.load(at: Fixtures.origin)
        clock.advance(700)
        await model.load(at: Fixtures.origin)
        XCTAssertEqual(model.state.shadeError, .networkUnavailable)
        XCTAssertEqual(model.forecast?.current.temperature, 29)

        // A failure doesn't start the throttle: the next call retries.
        await model.load(at: Fixtures.origin)
        XCTAssertEqual(provider.recorder.callCount, 3)
    }

    @MainActor func testConcurrentNearbyLoadsShareOneRequest() async {
        let gate = AsyncGate()
        let provider = FakeWeatherProvider { _, _ in
            await gate.wait()
            return Fixtures.forecast()
        }
        let model = WeatherModel(provider: provider)
        let first = Task { await model.load(at: Fixtures.origin) }
        await waitUntil { provider.recorder.callCount == 1 }
        let second = Task { await model.load(at: Fixtures.point(100, 100)) }
        await settle()
        XCTAssertEqual(provider.recorder.callCount, 1)
        await gate.open()
        await first.value
        await second.value
        XCTAssertEqual(provider.recorder.callCount, 1)
        XCTAssertNotNil(model.state.value)
    }
}
