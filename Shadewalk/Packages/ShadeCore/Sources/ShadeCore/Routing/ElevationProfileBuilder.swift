import Foundation

public enum ElevationProfileBuilder {
    /// Up to `maxSamples` evenly spaced points along the route (always includes both ends when count ≥ 2).
    public static func samplePoints(along coordinates: [GeoCoordinate], maxSamples: Int = 60) -> [GeoCoordinate] {
        fatalError("STUB: routing module")
    }

    /// Profile from elevations sampled evenly along a route of `totalDistance` metres.
    public static func profile(elevations: [Double], totalDistance: Double, binCount: Int = 12) -> ElevationProfile {
        fatalError("STUB: routing module")
    }
}
