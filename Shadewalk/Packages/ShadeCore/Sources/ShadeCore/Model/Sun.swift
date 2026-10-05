import Foundation

/// Apparent position of the sun.
public struct SunPosition: Hashable, Codable, Sendable {
    /// Degrees clockwise from true north, `[0, 360)`.
    public var azimuth: Double
    /// Degrees above the horizon (refraction-corrected). Negative when below.
    public var elevation: Double

    public init(azimuth: Double, elevation: Double) {
        self.azimuth = azimuth
        self.elevation = elevation
    }

    /// Sun is above the horizon.
    public var isUp: Bool { elevation > 0 }

    /// Unit vector pointing *towards* the sun in the local plane (x = east, y = north).
    public var directionToSun: Point2D {
        let a = GeoMath.radians(azimuth)
        return Point2D(x: sin(a), y: cos(a))
    }

    /// Unit vector in which shadows are cast (away from the sun).
    public var shadowDirection: Point2D { -directionToSun }

    /// Horizontal shadow length cast by an object of `height` metres; `.infinity` when the sun is down.
    public func shadowLength(forHeight height: Double) -> Double {
        guard isUp else { return .infinity }
        return height / tan(GeoMath.radians(elevation))
    }
}

/// Sunrise / sunset for a day at a location.
public struct SunTimes: Hashable, Codable, Sendable {
    /// First rise / last set within the local calendar day. Nil during polar night or midnight sun, and also on
    /// high-latitude transition days when the event falls outside the day (then `sunset` may even precede
    /// `sunrise`, e.g. Reykjavik in late June). UI ranges should fall back to the day's start / end.
    public var sunrise: Date?
    public var sunset: Date?
    public var solarNoon: Date
    /// True when the sun never sets that day (midnight sun).
    public var isPolarDay: Bool
    /// True when the sun never rises that day (polar night).
    public var isPolarNight: Bool

    public init(sunrise: Date?, sunset: Date?, solarNoon: Date, isPolarDay: Bool = false, isPolarNight: Bool = false) {
        self.sunrise = sunrise
        self.sunset = sunset
        self.solarNoon = solarNoon
        self.isPolarDay = isPolarDay
        self.isPolarNight = isPolarNight
    }
}
