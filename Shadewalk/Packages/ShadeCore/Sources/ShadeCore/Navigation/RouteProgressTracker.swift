import Foundation

public struct RouteProgress: Hashable, Sendable {
    /// Metres along the route.
    public var distanceAlong: Double
    public var remainingDistance: Double
    public var remainingDuration: TimeInterval
    /// Fraction `[0, 1]`.
    public var fractionCompleted: Double
    public var nextManeuver: Maneuver?
    public var distanceToNextManeuver: Double?
    /// Snapped position on the route.
    public var snappedCoordinate: GeoCoordinate
    /// Distance from the fix to the route, metres.
    public var distanceFromRoute: Double
    public var isInShade: Bool
    /// Metres until the next sunny run starts (0 if in sun now, nil if no more sun ahead).
    public var distanceToNextSun: Double?
    /// Length of the next (or current) sunny run, metres.
    public var nextSunLength: Double?
    /// Remaining shaded / sunny metres.
    public var remainingShadedDistance: Double
    public var remainingSunnyDistance: Double
    public var isOffRoute: Bool
    public var hasArrived: Bool

    public init(distanceAlong: Double, remainingDistance: Double, remainingDuration: TimeInterval, fractionCompleted: Double,
                nextManeuver: Maneuver?, distanceToNextManeuver: Double?, snappedCoordinate: GeoCoordinate,
                distanceFromRoute: Double, isInShade: Bool, distanceToNextSun: Double?, nextSunLength: Double?,
                remainingShadedDistance: Double, remainingSunnyDistance: Double, isOffRoute: Bool, hasArrived: Bool) {
        self.distanceAlong = distanceAlong
        self.remainingDistance = remainingDistance
        self.remainingDuration = remainingDuration
        self.fractionCompleted = fractionCompleted
        self.nextManeuver = nextManeuver
        self.distanceToNextManeuver = distanceToNextManeuver
        self.snappedCoordinate = snappedCoordinate
        self.distanceFromRoute = distanceFromRoute
        self.isInShade = isInShade
        self.distanceToNextSun = distanceToNextSun
        self.nextSunLength = nextSunLength
        self.remainingShadedDistance = remainingShadedDistance
        self.remainingSunnyDistance = remainingSunnyDistance
        self.isOffRoute = isOffRoute
        self.hasArrived = hasArrived
    }
}

/// Tracks progress of a user along a `WalkRoute`. See SPEC §4.7.
public struct RouteProgressTracker: Sendable {
    public let route: WalkRoute

    public init(route: WalkRoute) {
        fatalError("STUB: features module")
    }

    public mutating func update(with fix: LocationFix) -> RouteProgress {
        fatalError("STUB: features module")
    }
}
