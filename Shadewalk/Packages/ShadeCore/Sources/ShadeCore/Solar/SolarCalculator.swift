import Foundation

/// NOAA solar position algorithm. See SPEC §4.2.
///
/// Implements the formulas of the NOAA Solar Calculator spreadsheet (after Meeus, *Astronomical Algorithms*):
/// Julian century → geometric mean longitude/anomaly → equation of centre → apparent longitude → declination and
/// equation of time → true solar time → hour angle → zenith/azimuth, plus NOAA's atmospheric-refraction correction.
/// Valid for any date, both hemispheres, longitudes ±180 and the poles (inputs to `acos`/`asin` are clamped).
public enum SolarCalculator {
    /// Geometric elevation of the sun's centre at sunrise/sunset, degrees
    /// (34′ standard refraction + 16′ solar semi-diameter below the horizon).
    public static let horizonElevation = -0.833

    /// Apparent sun position (refraction-corrected) at `date` for `coordinate`.
    ///
    /// Latitudes outside `[-90, 90]` are clamped. Non-finite inputs yield a sun far below the horizon
    /// (`azimuth 0`, `elevation -90`) so callers treat it as night instead of propagating NaNs.
    public static func position(at date: Date, coordinate: GeoCoordinate) -> SunPosition {
        guard let geo = geometricPosition(at: date, coordinate: coordinate) else {
            return SunPosition(azimuth: 0, elevation: -90)
        }
        let apparent = geo.elevation + refraction(forGeometricElevation: geo.elevation)
        return SunPosition(azimuth: geo.azimuth, elevation: min(90, max(-90, apparent)))
    }

    /// Sunrise, sunset (elevation −0.833°) and solar noon for the calendar day containing `day` in `timeZone`.
    ///
    /// Events are those that happen *within* that local day, found numerically (10-minute scan of the geometric
    /// elevation, extra samples at the meridian transits, bisection to < 1 s), so 23/25-hour DST days work.
    /// `sunrise` is the day's first upward crossing and `sunset` its last downward crossing; near the polar-day
    /// transition the evening sunset can fall after midnight, so the day's `sunset` may precede its `sunrise`.
    /// Either is nil when no such crossing happens that day. `solarNoon` is the upper meridian transit (maximum
    /// elevation) nearest the middle of the local day.
    public static func sunTimes(on day: Date, coordinate: GeoCoordinate, timeZone: TimeZone) -> SunTimes {
        guard day.timeIntervalSinceReferenceDate.isFinite,
              coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            return SunTimes(sunrise: nil, sunset: nil, solarNoon: day)
        }
        let (start, end) = localDayBounds(containing: day, timeZone: timeZone)
        let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        let noon = transit(near: middle, longitude: coordinate.longitude, hourAngle: 0)

        // Sample times: every 10 min plus the meridian transits, where elevation peaks/bottoms out, so brief
        // grazing rises/sets between two scan points are not missed.
        let step: TimeInterval = 600
        var times: [Date] = []
        var t = start
        while t < end {
            times.append(t)
            t = t.addingTimeInterval(step)
        }
        times.append(end)
        let extremes = [
            noon,
            transit(near: noon.addingTimeInterval(-86_400), longitude: coordinate.longitude, hourAngle: 0),
            transit(near: noon.addingTimeInterval(86_400), longitude: coordinate.longitude, hourAngle: 0),
            transit(near: noon.addingTimeInterval(-43_200), longitude: coordinate.longitude, hourAngle: 180),
            transit(near: noon.addingTimeInterval(43_200), longitude: coordinate.longitude, hourAngle: 180),
        ]
        times.append(contentsOf: extremes.filter { $0 > start && $0 < end })
        times.sort()

        func altitude(_ date: Date) -> Double {
            (geometricPosition(at: date, coordinate: coordinate)?.elevation ?? -90) - horizonElevation
        }

        var sunrise: Date?
        var sunset: Date?
        var previous = (time: times[0], value: altitude(times[0]))
        let firstIsUp = previous.value > 0
        var crossed = false
        for time in times.dropFirst() where time > previous.time {
            let current = (time: time, value: altitude(time))
            if (previous.value > 0) != (current.value > 0) {
                crossed = true
                let rising = current.value > 0
                let event = bisectCrossing(from: previous.time, to: current.time, upAtEnd: rising, altitude: altitude)
                if rising {
                    if sunrise == nil { sunrise = event }
                } else {
                    sunset = event
                }
            }
            previous = current
        }
        return SunTimes(sunrise: sunrise, sunset: sunset, solarNoon: noon,
                        isPolarDay: !crossed && firstIsUp, isPolarNight: !crossed && !firstIsUp)
    }

    // MARK: - NOAA formulas

    /// Time-dependent solar quantities (NOAA spreadsheet columns G–V).
    struct Ephemeris: Equatable {
        /// Sun declination, degrees.
        var declination: Double
        /// Equation of time, minutes.
        var equationOfTime: Double

        init(date: Date) {
            let jc = (julianDay(date) - 2_451_545) / 36_525
            let meanLong = GeoMath.normalizeDegrees(280.46646 + jc * (36_000.76983 + jc * 0.0003032))
            let meanAnom = 357.52911 + jc * (35_999.05029 - 0.0001537 * jc)
            let ecc = 0.016708634 - jc * (0.000042037 + 0.0000001267 * jc)
            let m = GeoMath.radians(meanAnom)
            let centre = sin(m) * (1.914602 - jc * (0.004817 + 0.000014 * jc))
                + sin(2 * m) * (0.019993 - 0.000101 * jc)
                + sin(3 * m) * 0.000289
            let trueLong = meanLong + centre
            let omega = GeoMath.radians(125.04 - 1934.136 * jc)
            let appLong = trueLong - 0.00569 - 0.00478 * sin(omega)
            let meanObliq = 23 + (26 + (21.448 - jc * (46.815 + jc * (0.00059 - jc * 0.001813))) / 60) / 60
            let obliq = GeoMath.radians(meanObliq + 0.00256 * cos(omega))
            declination = GeoMath.degrees(asin(clamp(sin(obliq) * sin(GeoMath.radians(appLong)))))
            let y = tan(obliq / 2) * tan(obliq / 2)
            let l0 = GeoMath.radians(meanLong)
            equationOfTime = 4 * GeoMath.degrees(
                y * sin(2 * l0) - 2 * ecc * sin(m) + 4 * ecc * y * sin(m) * cos(2 * l0)
                    - 0.5 * y * y * sin(4 * l0) - 1.25 * ecc * ecc * sin(2 * m))
        }
    }

    /// Julian day (UT) of `date`.
    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    /// Hour angle in degrees, `[-180, 180)`; 0 at solar noon, positive in the afternoon.
    static func hourAngle(at date: Date, longitude: Double, ephemeris: Ephemeris) -> Double {
        // True solar time in minutes = UTC minutes of day + equation of time + 4·longitude.
        let utcMinutes = (date.timeIntervalSince1970 / 60).truncatingRemainder(dividingBy: 1440)
        let trueSolarTime = utcMinutes + ephemeris.equationOfTime + 4 * longitude
        return normalizeSigned(trueSolarTime / 4 - 180)
    }

    /// Geometric (unrefracted) sun position; nil for non-finite inputs.
    static func geometricPosition(at date: Date, coordinate: GeoCoordinate)
        -> (azimuth: Double, elevation: Double, hourAngle: Double)? {
        guard date.timeIntervalSince1970.isFinite, coordinate.latitude.isFinite, coordinate.longitude.isFinite else {
            return nil
        }
        let eph = Ephemeris(date: date)
        let ha = hourAngle(at: date, longitude: coordinate.longitude, ephemeris: eph)
        let phi = GeoMath.radians(min(90, max(-90, coordinate.latitude)))
        let delta = GeoMath.radians(eph.declination)
        let h = GeoMath.radians(ha)
        let cosZenith = sin(phi) * sin(delta) + cos(phi) * cos(delta) * cos(h)
        let elevation = 90 - GeoMath.degrees(acos(clamp(cosZenith)))
        // Same angle as NOAA's acos-based azimuth, but atan2 stays defined at the poles and at the zenith.
        let y = sin(h) * cos(delta)
        let x = cos(h) * cos(delta) * sin(phi) - sin(delta) * cos(phi)
        let azimuth = GeoMath.normalizeDegrees(GeoMath.degrees(atan2(y, x)) + 180)
        return (azimuth, elevation, ha)
    }

    /// NOAA atmospheric refraction correction (degrees) for a geometric elevation in degrees.
    static func refraction(forGeometricElevation e: Double) -> Double {
        let arcseconds: Double
        if e > 85 {
            arcseconds = 0
        } else if e > 5 {
            let t = tan(GeoMath.radians(e))
            arcseconds = 58.1 / t - 0.07 / (t * t * t) + 0.000086 / (t * t * t * t * t)
        } else if e > -0.575 {
            arcseconds = 1735 + e * (-518.2 + e * (103.4 + e * (-12.79 + e * 0.711)))
        } else {
            arcseconds = -20.772 / tan(GeoMath.radians(e))
        }
        return arcseconds / 3600
    }

    // MARK: - Sun-times helpers

    /// `[start, end)` of the local calendar day containing `date` (23/25 h on DST changes).
    static func localDayBounds(containing date: Date, timeZone: TimeZone) -> (start: Date, end: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = calendar.startOfDay(for: date)
        // 36 h after the start always lies inside the next local day, whatever the DST shift.
        let end = calendar.startOfDay(for: start.addingTimeInterval(36 * 3600))
        guard end > start else { return (start, start.addingTimeInterval(86_400)) }
        return (start, end)
    }

    /// Time near `date` (within ±12 h) at which the sun's hour angle equals `target` degrees
    /// (0 = upper meridian transit / solar noon, 180 = lower transit / solar midnight).
    static func transit(near date: Date, longitude: Double, hourAngle target: Double) -> Date {
        var t = date
        // The hour angle advances ≈ 360° per 86 400 s; three Newton steps converge to well under a second.
        for _ in 0..<3 {
            let ha = hourAngle(at: t, longitude: longitude, ephemeris: Ephemeris(date: t))
            let diff = normalizeSigned(ha - target)
            t = t.addingTimeInterval(-diff / 360 * 86_400)
        }
        return t
    }

    /// Bisects a horizon crossing between `a` and `b` to better than half a second.
    private static func bisectCrossing(from a: Date, to b: Date, upAtEnd: Bool, altitude: (Date) -> Double) -> Date {
        var lo = a, hi = b
        while hi.timeIntervalSince(lo) > 0.5 {
            let mid = lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
            if (altitude(mid) > 0) == upAtEnd { hi = mid } else { lo = mid }
        }
        return lo.addingTimeInterval(hi.timeIntervalSince(lo) / 2)
    }

    // MARK: - Angle helpers

    private static func clamp(_ v: Double) -> Double { min(1, max(-1, v)) }

    /// Normalises to `[-180, 180)`.
    private static func normalizeSigned(_ d: Double) -> Double {
        let r = GeoMath.normalizeDegrees(d + 180) - 180
        return r >= 180 ? r - 360 : r
    }
}
