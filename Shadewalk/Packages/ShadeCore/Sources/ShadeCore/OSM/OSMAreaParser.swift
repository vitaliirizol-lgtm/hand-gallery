import Foundation

/// Converts an Overpass JSON response into `AreaData`. See SPEC §4.4.
public enum OSMAreaParser {
    public static func parse(_ data: Data, bbox: BoundingBox, fetchedAt: Date) throws -> AreaData {
        fatalError("STUB: osm module")
    }

    /// Parses only cool spots (for `coolSpotQuery` responses).
    public static func parseCoolSpots(_ data: Data) throws -> [CoolSpot] {
        fatalError("STUB: osm module")
    }
}
