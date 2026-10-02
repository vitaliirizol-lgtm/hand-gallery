import Foundation

/// Builds Overpass QL. See SPEC §4.4.
public enum OverpassQueryBuilder {
    /// One query returning walk network, crossings, buildings, trees/canopy and cool spots for `bbox`.
    public static func areaQuery(for bbox: BoundingBox, timeout: Int = 90) -> String {
        fatalError("STUB: osm module")
    }

    /// Cool-spot POIs only, within `radius` metres of `center`.
    public static func coolSpotQuery(near center: GeoCoordinate, radius: Double, timeout: Int = 30) -> String {
        fatalError("STUB: osm module")
    }
}
