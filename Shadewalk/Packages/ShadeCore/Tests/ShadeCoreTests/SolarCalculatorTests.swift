import XCTest
@testable import ShadeCore

/// Reference values come from independent Python libraries (generated once, offline):
/// * positions — pysolar 0.13 `get_azimuth` / `get_altitude` (SPA-style ephemeris with its own refraction model);
/// * sunrise / sunset / solar noon — astral 3.2 `sun.sunrise` / `sun.sunset` / `sun.noon` (events on the local date,
///   sun centre at 90.833° zenith; raises for polar day / night).
final class SolarCalculatorTests: XCTestCase {
    // MARK: - Fixtures

    struct Place {
        let name: String
        let latitude: Double
        let longitude: Double
        let timeZones: [String]
        var coordinate: GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }
    }

    static let seoul = Place(name: "Seoul", latitude: 37.5665, longitude: 126.9780, timeZones: ["Asia/Seoul"])
    static let kyiv = Place(name: "Kyiv", latitude: 50.4501, longitude: 30.5234, timeZones: ["Europe/Kyiv", "Europe/Kiev"])
    static let london = Place(name: "London", latitude: 51.5074, longitude: -0.1278, timeZones: ["Europe/London"])
    static let sydney = Place(name: "Sydney", latitude: -33.8688, longitude: 151.2093, timeZones: ["Australia/Sydney"])
    static let quito = Place(name: "Quito", latitude: -0.1807, longitude: -78.4678, timeZones: ["America/Guayaquil"])
    static let tromso = Place(name: "Tromsø", latitude: 69.6492, longitude: 18.9553, timeZones: ["Europe/Oslo"])
    static let reykjavik = Place(name: "Reykjavik", latitude: 64.1466, longitude: -21.9426, timeZones: ["Atlantic/Reykjavik"])
    static let honolulu = Place(name: "Honolulu", latitude: 21.3069, longitude: -157.8583, timeZones: ["Pacific/Honolulu"])
    static let auckland = Place(name: "Auckland", latitude: -36.8485, longitude: 174.7633, timeZones: ["Pacific/Auckland"])
    static let paris = Place(name: "Paris", latitude: 48.8566, longitude: 2.3522, timeZones: ["Europe/Paris"])
    static let newYork = Place(name: "New York", latitude: 40.7128, longitude: -74.0060, timeZones: ["America/New_York"])
    static let suva = Place(name: "Suva", latitude: -18.1248, longitude: 178.4501, timeZones: ["Pacific/Fiji"])
    static let northPole = Place(name: "North Pole", latitude: 90, longitude: 0, timeZones: ["UTC"])

    struct PositionCase {
        let label: String
        let place: Place
        let epoch: TimeInterval
        let azimuth: Double
        let elevation: Double
    }

    /// pysolar 0.13 azimuth (clockwise from north) / apparent altitude.
    static let positionCases: [PositionCase] = [
        PositionCase(label: "Seoul solstice 07:00 KST", place: seoul, epoch: 1_781_992_800, azimuth: 74.583, elevation: 19.047),
        PositionCase(label: "Seoul solstice 12:30 KST", place: seoul, epoch: 1_782_012_600, azimuth: 176.426, elevation: 75.851),
        PositionCase(label: "Seoul solstice 18:30 KST", place: seoul, epoch: 1_782_034_200, azimuth: 288.439, elevation: 14.818),
        PositionCase(label: "Seoul winter 12:00 KST", place: seoul, epoch: 1_797_822_000, azimuth: 172.174, elevation: 28.621),
        PositionCase(label: "Kyiv 2026-04-15 10:00", place: kyiv, epoch: 1_776_236_400, azimuth: 122.135, elevation: 35.392),
        PositionCase(label: "London 2026-07-01 15:00 BST", place: london, epoch: 1_782_914_400, azimuth: 229.007, elevation: 53.922),
        PositionCase(label: "London DST day 12:00 BST", place: london, epoch: 1_774_782_000, azimuth: 158.514, elevation: 40.087),
        PositionCase(label: "Sydney summer 12:00 AEDT", place: sydney, epoch: 1_768_438_800, azimuth: 52.304, elevation: 70.936),
        PositionCase(label: "Sydney winter 12:00 AEST", place: sydney, epoch: 1_782_007_200, azimuth: 359.146, elevation: 32.714),
        PositionCase(label: "Quito equinox 09:00", place: quito, epoch: 1_774_015_200, azimuth: 89.866, elevation: 39.703),
        PositionCase(label: "Tromsø midsummer 12:00", place: tromso, epoch: 1_782_036_000, azimuth: 165.461, elevation: 43.300),
        PositionCase(label: "Tromsø midnight sun 00:30", place: tromso, epoch: 1_781_994_600, azimuth: 356.359, elevation: 3.346),
        PositionCase(label: "Reykjavik solstice 13:30", place: reykjavik, epoch: 1_782_048_600, azimuth: 180.148, elevation: 49.304),
        PositionCase(label: "Honolulu 2026-08-10 15:00", place: honolulu, epoch: 1_786_410_000, azimuth: 266.130, elevation: 55.553),
        PositionCase(label: "Auckland 2026-01-01 08:00 (UTC Dec 31)", place: auckland, epoch: 1_767_207_600, azimuth: 104.029, elevation: 20.490),
        PositionCase(label: "Paris 1990-07-15 14:00", place: paris, epoch: 648_043_200, azimuth: 181.763, elevation: 62.666),
        PositionCase(label: "New York 2040-02-29 10:00", place: newYork, epoch: 2_214_140_400, azimuth: 140.902, elevation: 33.433),
        PositionCase(label: "Suva 2026-11-03 16:00", place: suva, epoch: 1_793_678_400, azimuth: 262.798, elevation: 30.265),
    ]

    struct SunTimesCase {
        let label: String
        let place: Place
        /// Local calendar date (year, month, day).
        let date: (Int, Int, Int)
        let sunrise: TimeInterval?
        let sunset: TimeInterval?
        let noon: TimeInterval
        var polarDay = false
        var polarNight = false
    }

    /// astral 3.2 sunrise / sunset / noon (epoch seconds).
    static let sunTimesCases: [SunTimesCase] = [
        SunTimesCase(label: "Seoul summer solstice", place: seoul, date: (2026, 6, 21),
                     sunrise: 1_781_986_274, sunset: 1_782_039_386, noon: 1_782_012_828),
        SunTimesCase(label: "Seoul winter solstice", place: seoul, date: (2026, 12, 21),
                     sunrise: 1_797_806_592, sunset: 1_797_841_005, noon: 1_797_823_795),
        SunTimesCase(label: "Kyiv spring", place: kyiv, date: (2026, 4, 15),
                     sunrise: 1_776_222_292, sunset: 1_776_271_925, noon: 1_776_247_083),
        SunTimesCase(label: "London spring-forward (23 h)", place: london, date: (2026, 3, 29),
                     sunrise: 1_774_762_987, sunset: 1_774_808_904, noon: 1_774_785_923),
        SunTimesCase(label: "London fall-back (25 h)", place: london, date: (2026, 10, 25),
                     sunrise: 1_792_910_512, sunset: 1_792_946_785, noon: 1_792_928_676),
        SunTimesCase(label: "Sydney summer", place: sydney, date: (2026, 1, 15),
                     sunrise: 1_768_417_183, sunset: 1_768_468_125, noon: 1_768_442_663),
        SunTimesCase(label: "Sydney DST end (25 h)", place: sydney, date: (2026, 4, 5),
                     sunrise: 1_775_333_411, sunset: 1_775_375_112, noon: 1_775_354_278),
        SunTimesCase(label: "Quito equinox", place: quito, date: (2026, 3, 20),
                     sunrise: 1_774_005_489, sunset: 1_774_049_059, noon: 1_774_027_287),
        SunTimesCase(label: "Reykjavik solstice (sunset 00:02 precedes sunrise)", place: reykjavik, date: (2026, 6, 21),
                     sunrise: 1_782_010_580, sunset: 1_782_000_158, noon: 1_782_048_569),
        SunTimesCase(label: "Reykjavik winter", place: reykjavik, date: (2026, 12, 21),
                     sunrise: 1_797_852_191, sunset: 1_797_866_913, noon: 1_797_859_535),
        SunTimesCase(label: "Tromsø midnight sun", place: tromso, date: (2026, 6, 21),
                     sunrise: nil, sunset: nil, noon: 1_782_038_753, polarDay: true),
        SunTimesCase(label: "Tromsø polar night", place: tromso, date: (2026, 12, 21),
                     sunrise: nil, sunset: nil, noon: 1_797_849_720, polarNight: true),
        SunTimesCase(label: "Honolulu summer", place: honolulu, date: (2026, 8, 10),
                     sunrise: 1_786_378_113, sunset: 1_786_424_680, noon: 1_786_401_413),
        SunTimesCase(label: "Auckland New Year (UTC still Dec 31)", place: auckland, date: (2026, 1, 1),
                     sunrise: 1_767_200_715, sunset: 1_767_253_387, noon: 1_767_227_056),
        SunTimesCase(label: "Paris 1990", place: paris, date: (1990, 7, 15),
                     sunrise: 648_014_579, sunset: 648_071_362, noon: 648_042_986),
        SunTimesCase(label: "New York 2040 leap day", place: newYork, date: (2040, 2, 29),
                     sunrise: 2_214_127_839, sunset: 2_214_168_399, noon: 2_214_148_109),
        SunTimesCase(label: "Suva near the antimeridian", place: suva, date: (2026, 11, 3),
                     sunrise: 1_793_640_375, sunset: 1_793_686_403, noon: 1_793_663_383),
    ]

    /// astral 3.2 `time_at_elevation(-0.833, with_refraction=False)`: the exact −0.833° geometric crossing from SPEC
    /// §4.2. (astral's `sunrise`/`sunset` above use a ≈ −0.79° horizon, hence their 10–70 s offset from ours.)
    static let exactHorizonCases: [(place: Place, date: (Int, Int, Int), sunrise: TimeInterval, sunset: TimeInterval)] = [
        (seoul, (2026, 6, 21), 1_781_986_258, 1_782_039_401),
        (seoul, (2026, 12, 21), 1_797_806_577, 1_797_841_021),
        (kyiv, (2026, 4, 15), 1_776_222_274, 1_776_271_942),
        (london, (2026, 3, 29), 1_774_762_970, 1_774_808_921),
        (london, (2026, 10, 25), 1_792_910_494, 1_792_946_803),
        (sydney, (2026, 1, 15), 1_768_417_169, 1_768_468_139),
        (sydney, (2026, 4, 5), 1_775_333_399, 1_775_375_125),
        (quito, (2026, 3, 20), 1_774_005_478, 1_774_049_069),
        (reykjavik, (2026, 6, 21), 1_782_010_508, 1_782_000_230),
        (reykjavik, (2026, 12, 21), 1_797_852_140, 1_797_866_964),
        (honolulu, (2026, 8, 10), 1_786_378_101, 1_786_424_692),
        (auckland, (2026, 1, 1), 1_767_200_700, 1_767_253_402),
        (paris, (1990, 7, 15), 648_014_560, 648_071_381),
        (newYork, (2040, 2, 29), 2_214_127_825, 2_214_168_413),
        (suva, (2026, 11, 3), 1_793_640_363, 1_793_686_415),
    ]

    // MARK: - Helpers

    func timeZone(_ place: Place, file: StaticString = #filePath, line: UInt = #line) throws -> TimeZone {
        let tz = place.timeZones.lazy.compactMap { TimeZone(identifier: $0) }.first
        return try XCTUnwrap(tz, "time zone for \(place.name)", file: file, line: line)
    }

    func localDate(_ y: Int, _ m: Int, _ d: Int, _ hour: Int = 12, _ minute: Int = 0, in tz: TimeZone) throws -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return try XCTUnwrap(cal.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute)))
    }

    func assertAngle(_ actual: Double, _ expected: Double, accuracy: Double, _ message: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(GeoMath.angleDifference(from: expected, to: actual), 0, accuracy: accuracy, message, file: file, line: line)
    }

    func assertTime(_ actual: Date?, _ expected: TimeInterval?, accuracy: TimeInterval, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) {
        switch (actual, expected) {
        case (nil, nil):
            break
        case let (a?, e?):
            XCTAssertEqual(a.timeIntervalSince1970, e, accuracy: accuracy, message, file: file, line: line)
        default:
            XCTFail("\(message): expected \(String(describing: expected)), got \(String(describing: actual))", file: file, line: line)
        }
    }

    // MARK: - Position

    func testPositionsMatchPysolarReference() {
        XCTAssertGreaterThanOrEqual(Self.positionCases.count, 12)
        for c in Self.positionCases {
            let p = SolarCalculator.position(at: Date(timeIntervalSince1970: c.epoch), coordinate: c.place.coordinate)
            // 0.2° above 5° elevation; refraction models diverge more near the horizon.
            let tolerance = c.elevation > 5 ? 0.2 : 0.35
            XCTAssertEqual(p.elevation, c.elevation, accuracy: tolerance, "elevation: \(c.label)")
            assertAngle(p.azimuth, c.azimuth, accuracy: tolerance, "azimuth: \(c.label)")
        }
    }

    func testNoonAzimuthByHemisphere() {
        // Sun due south at northern solar noon, due north in the southern mid-latitudes.
        let seoulNoon = SolarCalculator.position(at: Date(timeIntervalSince1970: 1_782_012_828), coordinate: Self.seoul.coordinate)
        assertAngle(seoulNoon.azimuth, 180, accuracy: 0.5, "Seoul noon")
        let sydneyNoon = SolarCalculator.position(at: Date(timeIntervalSince1970: 1_768_442_663), coordinate: Self.sydney.coordinate)
        assertAngle(sydneyNoon.azimuth, 0, accuracy: 0.5, "Sydney noon")
        XCTAssertGreaterThan(sydneyNoon.elevation, 75)
    }

    func testPolesAndRangeSweepNeverProduceNaN() {
        let latitudes: [Double] = [-90, -89.999, -66.56, -45, -23.44, 0, 23.44, 45, 66.56, 89.999, 90]
        let longitudes: [Double] = [-180, -179.999, -90, 0, 90, 179.999, 180]
        let start = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01T00:00Z
        for day in stride(from: 0, through: 365, by: 13) {
            for hour in stride(from: 0, to: 24, by: 5) {
                let date = start.addingTimeInterval(Double(day) * 86_400 + Double(hour) * 3600 + 17)
                for lat in latitudes {
                    for lon in longitudes {
                        let p = SolarCalculator.position(at: date, coordinate: GeoCoordinate(latitude: lat, longitude: lon))
                        XCTAssertTrue(p.azimuth.isFinite && p.elevation.isFinite, "\(lat),\(lon) @ \(date)")
                        XCTAssertGreaterThanOrEqual(p.azimuth, 0)
                        XCTAssertLessThan(p.azimuth, 360)
                        XCTAssertLessThanOrEqual(abs(p.elevation), 90)
                    }
                }
            }
        }
    }

    func testPoleElevationFollowsDeclination() {
        // pysolar 0.13: north pole, 2026-06-21T12:00Z → altitude 23.475°.
        let june = Date(timeIntervalSince1970: 1_782_043_200)
        let north = SolarCalculator.position(at: june, coordinate: Self.northPole.coordinate)
        XCTAssertEqual(north.elevation, 23.475, accuracy: 0.05)
        let south = SolarCalculator.position(at: june, coordinate: GeoCoordinate(latitude: -90, longitude: 0))
        XCTAssertEqual(south.elevation, -23.43, accuracy: 0.05)
        XCTAssertFalse(south.isUp)
    }

    func testAntimeridianContinuity() {
        let date = Date(timeIntervalSince1970: 1_793_678_400)
        let east = SolarCalculator.position(at: date, coordinate: GeoCoordinate(latitude: -16.8, longitude: 179.9999))
        let west = SolarCalculator.position(at: date, coordinate: GeoCoordinate(latitude: -16.8, longitude: -179.9999))
        let wrapped = SolarCalculator.position(at: date, coordinate: GeoCoordinate(latitude: -16.8, longitude: 540 - 0.0001))
        XCTAssertEqual(east.elevation, west.elevation, accuracy: 0.001)
        assertAngle(east.azimuth, west.azimuth, accuracy: 0.001, "±180")
        XCTAssertEqual(east.elevation, wrapped.elevation, accuracy: 0.001)
    }

    func testSubsolarPointIsNearZenith() {
        // Equinox 2026-03-20T14:46Z: the sun is overhead on the equator where true solar time is noon,
        // i.e. longitude = (720 − UTC minutes − EoT) / 4 with the almanac equation of time ≈ −7.4 min.
        let date = Date(timeIntervalSince1970: 1_774_017_960)
        let utcMinutes: Double = 14 * 60 + 46
        let lon: Double = (720 - utcMinutes + 7.4) / 4
        let p = SolarCalculator.position(at: date, coordinate: GeoCoordinate(latitude: 0, longitude: lon))
        XCTAssertGreaterThan(p.elevation, 89.5)
    }

    func testEphemerisAgainstAlmanac() {
        // June solstice 2026-06-21T08:24Z: declination ≈ +23.44°.
        let solstice = SolarCalculator.Ephemeris(date: Date(timeIntervalSince1970: 1_782_030_240))
        XCTAssertEqual(solstice.declination, 23.436, accuracy: 0.01)
        // Equation of time extremes: ≈ −14.2 min mid-February, ≈ +16.4 min early November.
        let feb = SolarCalculator.Ephemeris(date: Date(timeIntervalSince1970: 1_770_811_200)) // 2026-02-11T12:00Z
        XCTAssertEqual(feb.equationOfTime, -14.2, accuracy: 0.2)
        let nov = SolarCalculator.Ephemeris(date: Date(timeIntervalSince1970: 1_793_707_200)) // 2026-11-03T12:00Z
        XCTAssertEqual(nov.equationOfTime, 16.4, accuracy: 0.2)
    }

    func testRefractionModel() {
        XCTAssertEqual(SolarCalculator.refraction(forGeometricElevation: 90), 0)
        XCTAssertEqual(SolarCalculator.refraction(forGeometricElevation: 0), 1735.0 / 3600, accuracy: 1e-9)
        // Branches join smoothly at 5° and −0.575°.
        XCTAssertEqual(SolarCalculator.refraction(forGeometricElevation: 5.0001),
                       SolarCalculator.refraction(forGeometricElevation: 4.9999), accuracy: 0.01)
        XCTAssertEqual(SolarCalculator.refraction(forGeometricElevation: -0.5749),
                       SolarCalculator.refraction(forGeometricElevation: -0.5751), accuracy: 0.01)
        for e in stride(from: -90.0, through: 90, by: 0.5) {
            let r = SolarCalculator.refraction(forGeometricElevation: e)
            XCTAssertTrue(r.isFinite && r >= 0 && r < 0.6, "refraction at \(e)")
        }
    }

    func testInvalidInputDoesNotPropagateNaN() {
        let date = Date(timeIntervalSince1970: 1_782_012_600)
        let nanLat = SolarCalculator.position(at: date, coordinate: GeoCoordinate(latitude: .nan, longitude: 10))
        XCTAssertEqual(nanLat, SunPosition(azimuth: 0, elevation: -90))
        let infLon = SolarCalculator.position(at: date, coordinate: GeoCoordinate(latitude: 10, longitude: .infinity))
        XCTAssertFalse(infLon.isUp)
        let overPole = SolarCalculator.position(at: date, coordinate: GeoCoordinate(latitude: 95, longitude: 0))
        let pole = SolarCalculator.position(at: date, coordinate: GeoCoordinate(latitude: 90, longitude: 0))
        XCTAssertEqual(overPole.elevation, pole.elevation, accuracy: 1e-9)
        let times = SolarCalculator.sunTimes(on: date, coordinate: GeoCoordinate(latitude: .nan, longitude: 0),
                                             timeZone: TimeZone(secondsFromGMT: 0) ?? .current)
        XCTAssertNil(times.sunrise)
        XCTAssertNil(times.sunset)
    }

    // MARK: - Sun times

    func testSunTimesMatchAstralReference() throws {
        XCTAssertGreaterThanOrEqual(Self.sunTimesCases.count, 12)
        for c in Self.sunTimesCases {
            let tz = try timeZone(c.place)
            let (y, m, d) = c.date
            // Any instant in the local day selects the same day.
            for hour in [0, 12, 23] {
                let day = try localDate(y, m, d, hour, hour == 23 ? 59 : 1, in: tz)
                let times = SolarCalculator.sunTimes(on: day, coordinate: c.place.coordinate, timeZone: tz)
                assertTime(times.sunrise, c.sunrise, accuracy: 120, "sunrise: \(c.label) (\(hour)h)")
                assertTime(times.sunset, c.sunset, accuracy: 120, "sunset: \(c.label) (\(hour)h)")
                assertTime(times.solarNoon, c.noon, accuracy: 60, "noon: \(c.label) (\(hour)h)")
                XCTAssertEqual(times.isPolarDay, c.polarDay, "polar day: \(c.label)")
                XCTAssertEqual(times.isPolarNight, c.polarNight, "polar night: \(c.label)")
            }
        }
    }

    func testSunTimesMatchExactHorizonCrossings() throws {
        for c in Self.exactHorizonCases {
            let tz = try timeZone(c.place)
            let day = try localDate(c.date.0, c.date.1, c.date.2, in: tz)
            let times = SolarCalculator.sunTimes(on: day, coordinate: c.place.coordinate, timeZone: tz)
            assertTime(times.sunrise, c.sunrise, accuracy: 10, "exact sunrise: \(c.place.name) \(c.date)")
            assertTime(times.sunset, c.sunset, accuracy: 10, "exact sunset: \(c.place.name) \(c.date)")
        }
    }

    func testSunTimesLieInsideTheLocalDayAndHitTheHorizon() throws {
        for c in Self.sunTimesCases where !c.polarDay && !c.polarNight {
            let tz = try timeZone(c.place)
            let (y, m, d) = c.date
            let day = try localDate(y, m, d, in: tz)
            let (start, end) = SolarCalculator.localDayBounds(containing: day, timeZone: tz)
            let times = SolarCalculator.sunTimes(on: day, coordinate: c.place.coordinate, timeZone: tz)
            for event in [times.sunrise, times.sunset] {
                let t = try XCTUnwrap(event, c.label)
                XCTAssertTrue(t >= start && t < end, "\(c.label): event outside local day")
                let geo = try XCTUnwrap(SolarCalculator.geometricPosition(at: t, coordinate: c.place.coordinate))
                XCTAssertEqual(geo.elevation, SolarCalculator.horizonElevation, accuracy: 0.01, c.label)
            }
            // Solar noon is the elevation maximum.
            let noonElevation = SolarCalculator.position(at: times.solarNoon, coordinate: c.place.coordinate).elevation
            for offset in [-300.0, 300] {
                let near = SolarCalculator.position(at: times.solarNoon.addingTimeInterval(offset),
                                                    coordinate: c.place.coordinate).elevation
                XCTAssertGreaterThanOrEqual(noonElevation, near, c.label)
            }
        }
    }

    func testDSTDayLengths() throws {
        let london = try timeZone(Self.london)
        let spring = SolarCalculator.localDayBounds(containing: try localDate(2026, 3, 29, in: london), timeZone: london)
        XCTAssertEqual(spring.end.timeIntervalSince(spring.start), 23 * 3600)
        let autumn = SolarCalculator.localDayBounds(containing: try localDate(2026, 10, 25, in: london), timeZone: london)
        XCTAssertEqual(autumn.end.timeIntervalSince(autumn.start), 25 * 3600)
        let normal = SolarCalculator.localDayBounds(containing: try localDate(2026, 7, 1, in: london), timeZone: london)
        XCTAssertEqual(normal.end.timeIntervalSince(normal.start), 24 * 3600)
    }

    func testPolesHavePolarDayAndNight() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let june = Date(timeIntervalSince1970: 1_782_043_200)
        let december = Date(timeIntervalSince1970: 1_797_854_400)
        let north = GeoCoordinate(latitude: 90, longitude: 0)
        let south = GeoCoordinate(latitude: -90, longitude: 0)

        let nJune = SolarCalculator.sunTimes(on: june, coordinate: north, timeZone: utc)
        XCTAssertTrue(nJune.isPolarDay)
        XCTAssertFalse(nJune.isPolarNight)
        XCTAssertNil(nJune.sunrise)
        XCTAssertNil(nJune.sunset)
        XCTAssertTrue(SolarCalculator.sunTimes(on: june, coordinate: south, timeZone: utc).isPolarNight)
        XCTAssertTrue(SolarCalculator.sunTimes(on: december, coordinate: north, timeZone: utc).isPolarNight)
        XCTAssertTrue(SolarCalculator.sunTimes(on: december, coordinate: south, timeZone: utc).isPolarDay)
    }

    func testFarOffTimeZoneStillFindsEvents() throws {
        // London coordinates evaluated in a UTC+14 zone: the local day still contains one sunrise and one sunset.
        let kiritimati = try XCTUnwrap(TimeZone(identifier: "Pacific/Kiritimati"))
        let day = try localDate(2026, 6, 10, in: kiritimati)
        let times = SolarCalculator.sunTimes(on: day, coordinate: Self.london.coordinate, timeZone: kiritimati)
        let (start, end) = SolarCalculator.localDayBounds(containing: day, timeZone: kiritimati)
        let rise = try XCTUnwrap(times.sunrise)
        let set = try XCTUnwrap(times.sunset)
        XCTAssertTrue(rise >= start && rise < end)
        XCTAssertTrue(set >= start && set < end)
        XCTAssertTrue(times.solarNoon >= start && times.solarNoon < end)
    }
}
