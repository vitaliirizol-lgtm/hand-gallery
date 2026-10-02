import Foundation

/// Builds Overpass QL. See SPEC §4.4.
public enum OverpassQueryBuilder {
    /// `amenity=` values returned as cool spots.
    public static let coolSpotAmenities = ["drinking_water", "water_point", "library", "community_centre", "shelter"]
    /// `shop=` values returned as cool spots.
    public static let coolSpotShops = ["mall", "department_store"]

    /// One query returning walk network, crossings, buildings, trees/canopy and cool spots for `bbox`.
    ///
    /// Ways use `out geom` (node ids plus inline geometry), tagged nodes use `out`, and cool spots use
    /// `out center`; a way matching several statements is printed once per statement and merged by the parser.
    public static func areaQuery(for bbox: BoundingBox, timeout: Int = 90) -> String {
        let walkable = regex(WalkGraphBuilder.walkableHighwayValues)
        let footOnly = regex(WalkGraphBuilder.footRestrictedHighwayValues)
        return """
        [out:json][timeout:\(max(1, timeout))][bbox:\(bbox.overpassString)];
        (
          way["highway"~"\(walkable)"];
          way["highway"~"\(footOnly)"]["foot"~"^(yes|designated)$"];
        );
        out geom qt;
        (
          node["highway"="crossing"];
          node["crossing"];
          node["highway"="traffic_signals"];
        );
        out qt;
        (
          way["building"];
          relation["building"]["type"="multipolygon"];
        );
        out geom qt;
        node["natural"="tree"];
        out qt;
        way["natural"="tree_row"];
        out geom qt;
        (
          way["natural"="wood"];
          way["landuse"="forest"];
          relation["natural"="wood"]["type"="multipolygon"];
          relation["landuse"="forest"]["type"="multipolygon"];
        );
        out geom qt;
        (
        \(coolSpotStatements(filter: ""))
        );
        out center qt;
        """
    }

    /// Cool-spot POIs only, within `radius` metres of `center`.
    public static func coolSpotQuery(near center: GeoCoordinate, radius: Double, timeout: Int = 30) -> String {
        let r = radius.isFinite ? Int(min(50_000, max(1, radius.rounded()))) : 1_000
        let around = "(around:\(r)," + String(format: "%.6f,%.6f", center.latitude, center.longitude) + ")"
        return """
        [out:json][timeout:\(max(1, timeout))];
        (
        \(coolSpotStatements(filter: around))
        );
        out center qt;
        """
    }

    /// Node, way and relation statements for every cool-spot tag, each followed by `filter`.
    private static func coolSpotStatements(filter: String) -> String {
        let selectors = [
            "[\"amenity\"~\"\(regex(coolSpotAmenities))\"]",
            "[\"shop\"~\"\(regex(coolSpotShops))\"]",
            "[\"leisure\"=\"park\"]",
        ]
        return selectors.flatMap { selector in
            ["node", "way", "relation"].map { "  \($0)\(selector)\(filter);" }
        }.joined(separator: "\n")
    }

    /// Anchored alternation, e.g. `^(a|b)$`.
    private static func regex(_ values: [String]) -> String {
        "^(" + values.joined(separator: "|") + ")$"
    }
}
