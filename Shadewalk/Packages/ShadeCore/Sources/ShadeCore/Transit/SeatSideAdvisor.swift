import Foundation

/// Which side of a vehicle to sit on to avoid the sun. See SPEC §4.6.
public enum SeatSideAdvisor {
    /// - Parameters:
    ///   - path: vehicle path (≥ 2 points).
    ///   - departure: departure time.
    ///   - duration: trip duration in seconds (> 0).
    ///   - cloudCover: percent 0–100, nil if unknown.
    public static func advise(path: [GeoCoordinate], departure: Date, duration: TimeInterval, cloudCover: Double?) -> SeatSideAdvice {
        fatalError("STUB: solar-transit module")
    }
}
