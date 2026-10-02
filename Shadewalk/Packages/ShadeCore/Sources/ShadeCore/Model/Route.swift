import Foundation

public enum RouteProfile: String, Codable, Sendable, CaseIterable, Hashable {
    case shadiest, balanced, fastest
}

public struct RoutingPreferences: Hashable, Codable, Sendable {
    /// Walking speed, m/s (slow 1.1, normal 1.35, fast 1.6).
    public var walkingSpeed: Double
    /// Max extra length accepted for a shadier route, as a fraction of the fastest route (0.25 = +25 %).
    public var maxDetourFraction: Double
    public var avoidStairs: Bool
    /// Metres per step, used for the step counter.
    public var strideLength: Double

    public init(walkingSpeed: Double = 1.35, maxDetourFraction: Double = 0.25, avoidStairs: Bool = false,
                strideLength: Double = 0.74) {
        self.walkingSpeed = walkingSpeed
        self.maxDetourFraction = maxDetourFraction
        self.avoidStairs = avoidStairs
        self.strideLength = strideLength
    }

    public static let `default` = RoutingPreferences()
}

/// A run of consecutive route geometry that is either in shade or in sun.
public struct RouteSegment: Hashable, Codable, Sendable {
    public var coordinates: [GeoCoordinate]
    /// Metres.
    public var length: Double
    public var isShaded: Bool

    public init(coordinates: [GeoCoordinate], length: Double, isShaded: Bool) {
        self.coordinates = coordinates
        self.length = length
        self.isShaded = isShaded
    }
}

public enum ManeuverKind: String, Codable, Sendable, Hashable {
    case depart, continueStraight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uTurn
    case crossStreet, takeStairs, enterUnderpass, arrive
}

public struct Maneuver: Hashable, Codable, Sendable {
    public var kind: ManeuverKind
    /// Name of the way taken after the maneuver, if known.
    public var streetName: String?
    /// Metres from route start.
    public var distanceFromStart: Double
    public var coordinate: GeoCoordinate

    public init(kind: ManeuverKind, streetName: String?, distanceFromStart: Double, coordinate: GeoCoordinate) {
        self.kind = kind
        self.streetName = streetName
        self.distanceFromStart = distanceFromStart
        self.coordinate = coordinate
    }
}

public enum SlopeCategory: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case flat, gentle, moderate, steep

    /// |grade| thresholds: flat < 1.5 %, gentle < 4 %, moderate < 8 %, steep ≥ 8 %.
    public init(grade: Double) {
        let g = abs(grade)
        if g < 0.015 { self = .flat } else if g < 0.04 { self = .gentle } else if g < 0.08 { self = .moderate } else { self = .steep }
    }

    private var rank: Int {
        switch self { case .flat: 0; case .gentle: 1; case .moderate: 2; case .steep: 3 }
    }

    public static func < (a: SlopeCategory, b: SlopeCategory) -> Bool { a.rank < b.rank }
}

public struct SlopeBin: Hashable, Codable, Sendable {
    /// Signed grade (rise / run) over the bin; positive = uphill.
    public var grade: Double
    public var category: SlopeCategory

    public init(grade: Double) {
        self.grade = grade
        self.category = SlopeCategory(grade: grade)
    }
}

public struct ElevationProfile: Hashable, Codable, Sendable {
    /// Elevations (metres) at evenly spaced samples from start to end.
    public var elevations: [Double]
    /// Distance between consecutive samples, metres.
    public var sampleSpacing: Double
    public var ascent: Double
    public var descent: Double
    /// Max |grade| over any bin, as a fraction.
    public var maxGrade: Double
    /// Typically 12 bins from start to arrival.
    public var bins: [SlopeBin]

    public init(elevations: [Double], sampleSpacing: Double, ascent: Double, descent: Double, maxGrade: Double, bins: [SlopeBin]) {
        self.elevations = elevations
        self.sampleSpacing = sampleSpacing
        self.ascent = ascent
        self.descent = descent
        self.maxGrade = maxGrade
        self.bins = bins
    }

    /// Overall category = steepest bin category.
    public var overallCategory: SlopeCategory { bins.map(\.category).max() ?? .flat }
}

/// A computed walking route.
public struct WalkRoute: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    /// Primary profile shown in the UI.
    public var profile: RouteProfile
    /// All profiles this route satisfies (e.g. `[.shadiest, .fastest]` when they coincide).
    public var profiles: [RouteProfile]
    public var coordinates: [GeoCoordinate]
    public var segments: [RouteSegment]
    /// Metres.
    public var distance: Double
    /// Seconds.
    public var duration: TimeInterval
    public var stepCount: Int
    /// Length-weighted shade fraction `[0, 1]`.
    public var shadeFraction: Double
    public var shadedDistance: Double
    public var sunnyDistance: Double
    public var shadedDuration: TimeInterval
    public var sunnyDuration: TimeInterval
    public var crossingCount: Int
    public var stairsCount: Int
    public var underpassCount: Int
    public var maneuvers: [Maneuver]
    /// Cool spots within ~40 m of the route.
    public var coolSpotIDs: [Int64]
    public var elevation: ElevationProfile?
    public var departure: Date
    public var sun: SunPosition

    public init(id: String, profile: RouteProfile, profiles: [RouteProfile], coordinates: [GeoCoordinate],
                segments: [RouteSegment], distance: Double, duration: TimeInterval, stepCount: Int,
                shadeFraction: Double, shadedDistance: Double, sunnyDistance: Double,
                shadedDuration: TimeInterval, sunnyDuration: TimeInterval, crossingCount: Int, stairsCount: Int,
                underpassCount: Int, maneuvers: [Maneuver], coolSpotIDs: [Int64] = [], elevation: ElevationProfile? = nil,
                departure: Date, sun: SunPosition) {
        self.id = id
        self.profile = profile
        self.profiles = profiles
        self.coordinates = coordinates
        self.segments = segments
        self.distance = distance
        self.duration = duration
        self.stepCount = stepCount
        self.shadeFraction = shadeFraction
        self.shadedDistance = shadedDistance
        self.sunnyDistance = sunnyDistance
        self.shadedDuration = shadedDuration
        self.sunnyDuration = sunnyDuration
        self.crossingCount = crossingCount
        self.stairsCount = stairsCount
        self.underpassCount = underpassCount
        self.maneuvers = maneuvers
        self.coolSpotIDs = coolSpotIDs
        self.elevation = elevation
        self.departure = departure
        self.sun = sun
    }

    public var arrival: Date { departure.addingTimeInterval(duration) }
    public var origin: GeoCoordinate? { coordinates.first }
    public var destination: GeoCoordinate? { coordinates.last }
}

/// Input to route planning.
public struct RouteRequest: Hashable, Sendable {
    public var origin: GeoCoordinate
    public var destination: GeoCoordinate
    public var departure: Date
    public var preferences: RoutingPreferences

    public init(origin: GeoCoordinate, destination: GeoCoordinate, departure: Date, preferences: RoutingPreferences = .default) {
        self.origin = origin
        self.destination = destination
        self.departure = departure
        self.preferences = preferences
    }
}

/// Output of route planning.
public struct RoutePlan: Sendable {
    /// Ordered for display: shadiest first, then balanced, then fastest.
    public var routes: [WalkRoute]
    public var sun: SunPosition
    public var departure: Date
    public var weather: WeatherSnapshot?
    /// Cool spots in the planned area (for the map layer).
    public var coolSpots: [CoolSpot]

    public init(routes: [WalkRoute], sun: SunPosition, departure: Date, weather: WeatherSnapshot?, coolSpots: [CoolSpot]) {
        self.routes = routes
        self.sun = sun
        self.departure = departure
        self.weather = weather
        self.coolSpots = coolSpots
    }

    public var isSunUp: Bool { sun.isUp }
}
