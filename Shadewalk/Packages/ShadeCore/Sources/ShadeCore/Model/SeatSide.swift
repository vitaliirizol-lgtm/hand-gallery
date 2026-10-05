import Foundation

public enum VehicleKind: String, Codable, Sendable, CaseIterable, Hashable {
    case bus, tram, train

    /// Factor applied to a car ETA to approximate this vehicle's travel time.
    public var travelTimeFactor: Double {
        switch self {
        case .bus: 1.35
        case .tram: 1.3
        case .train: 0.9
        }
    }
}

public enum SeatSide: String, Codable, Sendable, Hashable {
    case left, right, either
}

/// Where the sun is relative to the direction of travel.
public enum SunSide: String, Codable, Sendable, Hashable {
    case left, right, ahead, behind, none
}

public enum SeatSideReason: String, Codable, Sendable, Hashable {
    /// Sun mostly on the right → sit left.
    case sunMostlyOnRight
    /// Sun mostly on the left → sit right.
    case sunMostlyOnLeft
    /// Both sides get similar sun.
    case balanced
    /// Sun below the horizon for the whole trip.
    case sunDown
    /// Cloud cover ≥ 85 %.
    case overcast
}

public struct SeatSideSample: Hashable, Codable, Sendable {
    /// Position along the trip, `[0, 1]`.
    public var fraction: Double
    public var time: Date
    public var sunSide: SunSide
    /// Exposure weight `|sin(rel)| · cos(elevation)` (0 when no side sun).
    public var intensity: Double

    public init(fraction: Double, time: Date, sunSide: SunSide, intensity: Double) {
        self.fraction = fraction
        self.time = time
        self.sunSide = sunSide
        self.intensity = intensity
    }
}

public struct SeatSideAdvice: Hashable, Codable, Sendable {
    public var recommendation: SeatSide
    public var reason: SeatSideReason
    /// Share of side-sun exposure on the left, `[0, 1]` (left + right = 1 when any side sun, else both 0).
    public var sunOnLeftShare: Double
    public var sunOnRightShare: Double
    /// Fraction of trip time with the sun below the horizon.
    public var sunDownFraction: Double
    public var timeline: [SeatSideSample]
    public var duration: TimeInterval

    public init(recommendation: SeatSide, reason: SeatSideReason, sunOnLeftShare: Double, sunOnRightShare: Double,
                sunDownFraction: Double, timeline: [SeatSideSample], duration: TimeInterval) {
        self.recommendation = recommendation
        self.reason = reason
        self.sunOnLeftShare = sunOnLeftShare
        self.sunOnRightShare = sunOnRightShare
        self.sunDownFraction = sunDownFraction
        self.timeline = timeline
        self.duration = duration
    }
}

/// Road path between two points (from MapKit directions in the app).
public struct DrivingPath: Hashable, Sendable {
    public var coordinates: [GeoCoordinate]
    /// Car ETA, seconds.
    public var expectedTravelTime: TimeInterval

    public init(coordinates: [GeoCoordinate], expectedTravelTime: TimeInterval) {
        self.coordinates = coordinates
        self.expectedTravelTime = expectedTravelTime
    }
}
