import Foundation

/// NOAA solar position algorithm. See SPEC §4.2.
public enum SolarCalculator {
    /// Apparent sun position (refraction-corrected) at `date` for `coordinate`.
    public static func position(at date: Date, coordinate: GeoCoordinate) -> SunPosition {
        fatalError("STUB: solar-transit module")
    }

    /// Sunrise, sunset (elevation −0.833°) and solar noon for the calendar day containing `day` in `timeZone`.
    public static func sunTimes(on day: Date, coordinate: GeoCoordinate, timeZone: TimeZone) -> SunTimes {
        fatalError("STUB: solar-transit module")
    }
}
