import XCTest
@testable import ShadeFeatures

final class DepartureTimeModelTests: XCTestCase {
    // Fixtures.departure is 2025-06-27 13:53:20 in UTC+9.
    private func seoulTime() throws -> TimeZone {
        try XCTUnwrap(TimeZone(secondsFromGMT: 9 * 3600))
    }

    private func dayStart(_ tz: TimeZone, of date: Date = Fixtures.departure) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return calendar.startOfDay(for: date)
    }

    /// Sun times at `rise` / `set` minutes after local midnight.
    private func times(_ tz: TimeZone, rise: Double?, set: Double?, polarDay: Bool = false,
                       polarNight: Bool = false) -> SunTimes {
        let start = dayStart(tz)
        return SunTimes(sunrise: rise.map { start.addingTimeInterval($0 * 60) },
                        sunset: set.map { start.addingTimeInterval($0 * 60) },
                        solarNoon: start.addingTimeInterval(12.5 * 3600), isPolarDay: polarDay, isPolarNight: polarNight)
    }

    @MainActor func testRangeRunsFromSunriseToSunsetRoundedInwards() async throws {
        let tz = try seoulTime()
        let clock = TestClock()
        let calls = Locked(0)
        let model = DepartureTimeModel(coordinate: Fixtures.origin, timeZone: tz, now: { clock.now },
                                       sunTimes: { _, _, _ in
                                           calls.mutate { $0 += 1 }
                                           return self.times(tz, rise: 5 * 60 + 47, set: 19 * 60 + 52)
                                       })
        XCTAssertEqual(model.range, 360...1185) // 06:00 – 19:45
        XCTAssertFalse(model.usesFallbackRange)
        XCTAssertNotNil(model.sunTimes)
        XCTAssertEqual(model.step, 15)
        XCTAssertEqual(model.day, dayStart(tz))
        XCTAssertEqual(model.hourMarks.first, 360)
        XCTAssertEqual(model.hourMarks.last, 1140)
        XCTAssertEqual(model.hourMarks.count, 14)
        XCTAssertEqual(calls.current, 1)
    }

    @MainActor func testFallbackRangeWithoutCoordinate() async throws {
        let tz = try seoulTime()
        let model = DepartureTimeModel(timeZone: tz, now: { Fixtures.departure },
                                       sunTimes: { _, _, _ in
                                           XCTFail("Sun times must not be computed without a coordinate")
                                           return SunTimes(sunrise: nil, sunset: nil, solarNoon: Fixtures.departure)
                                       })
        XCTAssertEqual(model.range, DepartureTimeModel.fallbackRange)
        XCTAssertEqual(model.range, 360...1260)
        XCTAssertTrue(model.usesFallbackRange)
        XCTAssertNil(model.sunTimes)
    }

    @MainActor func testFallbackRangeForPolarAndUnknownSunTimes() async throws {
        let tz = try seoulTime()
        let cases: [SunTimes] = [
            times(tz, rise: nil, set: nil, polarDay: true),
            times(tz, rise: nil, set: nil, polarNight: true),
            times(tz, rise: 300, set: nil),
            times(tz, rise: 700, set: 650), // sunset before sunrise
            times(tz, rise: 600, set: 610), // shorter than one step
        ]
        for sunTimes in cases {
            let model = DepartureTimeModel(coordinate: Fixtures.origin, timeZone: tz, now: { Fixtures.departure },
                                           sunTimes: { _, _, _ in sunTimes })
            XCTAssertEqual(model.range, 360...1260)
            XCTAssertTrue(model.usesFallbackRange)
        }
    }

    @MainActor func testSunsetAfterMidnightCapsAtLastStep() async throws {
        let tz = try seoulTime()
        let model = DepartureTimeModel(coordinate: Fixtures.origin, timeZone: tz, now: { Fixtures.departure },
                                       sunTimes: { _, _, _ in self.times(tz, rise: 200, set: 24 * 60 + 30) })
        XCTAssertEqual(model.range, 210...1425)
    }

    @MainActor func testSliderValueAndDateMapping() async throws {
        let tz = try seoulTime()
        let clock = TestClock()
        let model = DepartureTimeModel(coordinate: Fixtures.origin, timeZone: tz, now: { clock.now },
                                       sunTimes: { _, _, _ in self.times(tz, rise: 347, set: 1192) })
        let start = dayStart(tz)
        // "Now" reads as the current time.
        XCTAssertTrue(model.departure.isNow)
        XCTAssertEqual(model.sliderValue, 13 * 60 + 53 + 20.0 / 60, accuracy: 1e-6)
        XCTAssertEqual(model.nowValue, model.sliderValue, accuracy: 1e-9)
        XCTAssertEqual(model.resolvedDate, clock.now)

        // Writing snaps to 15 minutes.
        model.sliderValue = 900.4
        XCTAssertEqual(model.departure, .at(start.addingTimeInterval(15 * 3600)))
        XCTAssertEqual(model.sliderValue, 900)
        XCTAssertEqual(model.resolvedDate, start.addingTimeInterval(15 * 3600))
        model.sliderValue = 908
        XCTAssertEqual(model.sliderValue, 915)

        // Round trip.
        XCTAssertEqual(model.date(forValue: 615), start.addingTimeInterval(615 * 60))
        XCTAssertEqual(model.value(for: start.addingTimeInterval(615 * 60)), 615)
        XCTAssertEqual(model.value(for: start.addingTimeInterval(-60)), 0)
        XCTAssertEqual(model.value(for: start.addingTimeInterval(86_400 + 60)), 1440)

        // Clamped to the daylight range.
        model.sliderValue = 100
        XCTAssertEqual(model.sliderValue, 360)
        model.sliderValue = 1430
        XCTAssertEqual(model.sliderValue, 1185)
        model.sliderValue = .nan
        XCTAssertEqual(model.sliderValue, 1185)

        model.select(start.addingTimeInterval(10 * 3600 + 8 * 60))
        XCTAssertEqual(model.sliderValue, 615)

        model.selectNow()
        XCTAssertEqual(model.departure, .now)
    }

    @MainActor func testNowOutsideDaylightIsClamped() async throws {
        let tz = try seoulTime()
        let clock = TestClock(dayStart(try seoulTime()).addingTimeInterval(22 * 3600))
        let model = DepartureTimeModel(coordinate: Fixtures.origin, timeZone: tz, now: { clock.now },
                                       sunTimes: { _, _, _ in self.times(tz, rise: 347, set: 1192) })
        XCTAssertEqual(model.sliderValue, 1185)
        XCTAssertEqual(model.resolvedDate, clock.now) // "Now" itself is not clamped
    }

    @MainActor func testRefreshOnNewDayRevertsToNow() async throws {
        let tz = try seoulTime()
        let clock = TestClock()
        let calls = Locked<[Date]>([])
        let model = DepartureTimeModel(coordinate: Fixtures.origin, timeZone: tz, now: { clock.now },
                                       sunTimes: { day, _, _ in
                                           calls.mutate { $0.append(day) }
                                           return self.times(tz, rise: 347, set: 1192)
                                       })
        model.sliderValue = 600
        XCTAssertFalse(model.departure.isNow)
        // Same day: the selection survives.
        model.refresh()
        XCTAssertEqual(model.sliderValue, 600)

        clock.advance(86_400)
        model.refresh()
        XCTAssertTrue(model.departure.isNow)
        XCTAssertEqual(model.day, dayStart(tz, of: clock.now))
        XCTAssertEqual(calls.current.count, 3)
    }

    @MainActor func testCoordinateChangeRecomputesRange() async throws {
        let tz = try seoulTime()
        let model = DepartureTimeModel(timeZone: tz, now: { Fixtures.departure },
                                       sunTimes: { _, c, _ in
                                           c.latitude > 50 ? self.times(tz, rise: 240, set: 1320)
                                               : self.times(tz, rise: 347, set: 1192)
                                       })
        XCTAssertTrue(model.usesFallbackRange)
        model.coordinate = Fixtures.origin
        XCTAssertEqual(model.range, 360...1185)
        model.coordinate = GeoCoordinate(latitude: 60, longitude: 25)
        XCTAssertEqual(model.range, 240...1320)
        model.coordinate = nil
        XCTAssertTrue(model.usesFallbackRange)
    }

    @MainActor func testSelectionOutsideNewRangeIsClampedOnRefresh() async throws {
        let tz = try seoulTime()
        let sunrise = Locked<Double>(347)
        let model = DepartureTimeModel(coordinate: Fixtures.origin, timeZone: tz, now: { Fixtures.departure },
                                       sunTimes: { _, _, _ in self.times(tz, rise: sunrise.current, set: 1192) })
        model.sliderValue = 360
        sunrise.mutate { $0 = 500 }
        model.refresh()
        XCTAssertEqual(model.range.lowerBound, 510)
        XCTAssertEqual(model.departure, .at(dayStart(tz).addingTimeInterval(510 * 60)))
    }

    func testDepartureOption() {
        let date = Fixtures.departure
        XCTAssertEqual(DepartureOption.now.date(now: date), date)
        XCTAssertEqual(DepartureOption.at(date.addingTimeInterval(60)).date(now: date), date.addingTimeInterval(60))
        XCTAssertTrue(DepartureOption.now.isNow)
        XCTAssertFalse(DepartureOption.at(date).isNow)
    }
}
