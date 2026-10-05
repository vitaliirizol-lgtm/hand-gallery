import Foundation

/// Building footprint extruded to `height`.
public struct Building: Hashable, Codable, Sendable, Identifiable {
    /// OSM way id; rings from multipolygon relations get negative synthetic ids.
    public var id: Int64
    /// Outer ring, open (first vertex is not repeated), at least 3 vertices.
    public var footprint: [GeoCoordinate]
    /// Roof-top height above ground, metres.
    public var height: Double
    /// Height of the underside above ground (overhangs, bridges, roofs on pillars), metres. 0 = solid to the ground.
    public var minHeight: Double
    /// `building=roof`, carports, canopies: open structure — the area beneath is shaded.
    public var isRoofOnly: Bool

    public init(id: Int64, footprint: [GeoCoordinate], height: Double, minHeight: Double = 0, isRoofOnly: Bool = false) {
        self.id = id
        self.footprint = footprint
        self.height = height
        self.minHeight = minHeight
        self.isRoofOnly = isRoofOnly
    }
}

/// Single tree (or a sample along a tree row).
public struct Tree: Hashable, Codable, Sendable, Identifiable {
    /// OSM node id; samples along tree rows get negative synthetic ids.
    public var id: Int64
    public var coordinate: GeoCoordinate
    /// Total height, metres (default 8).
    public var height: Double
    /// Crown radius, metres (default 4).
    public var crownRadius: Double

    public init(id: Int64, coordinate: GeoCoordinate, height: Double = 8, crownRadius: Double = 4) {
        self.id = id
        self.coordinate = coordinate
        self.height = height
        self.crownRadius = crownRadius
    }
}

/// Continuous tree canopy area (woods, forest).
public struct CanopyArea: Hashable, Codable, Sendable, Identifiable {
    /// OSM way id; rings from multipolygon relations get negative synthetic ids.
    public var id: Int64
    /// Outer ring, open.
    public var ring: [GeoCoordinate]
    public var height: Double

    public init(id: Int64, ring: [GeoCoordinate], height: Double = 12) {
        self.id = id
        self.ring = ring
        self.height = height
    }
}

public enum CoolSpotKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// Drinking fountains / water points.
    case drinkingWater
    /// Air-conditioned public interiors: libraries, malls, community centres.
    case indoorCool
    /// Shelters (`amenity=shelter`).
    case shelter
    /// Parks.
    case park
}

/// A place to cool down or refill water.
public struct CoolSpot: Hashable, Codable, Sendable, Identifiable {
    /// OSM node id; spots mapped as ways / relations get negative synthetic ids so they never collide with nodes.
    public var id: Int64
    public var kind: CoolSpotKind
    public var name: String?
    public var coordinate: GeoCoordinate
    /// Raw OSM `opening_hours`, if any.
    public var openingHours: String?

    public init(id: Int64, kind: CoolSpotKind, name: String?, coordinate: GeoCoordinate, openingHours: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.coordinate = coordinate
        self.openingHours = openingHours
    }
}

/// Everything known about an area: shade casters, walk network and cool spots.
public struct AreaData: Sendable {
    public var bbox: BoundingBox
    public var buildings: [Building]
    public var trees: [Tree]
    public var canopies: [CanopyArea]
    public var graph: WalkGraph
    public var coolSpots: [CoolSpot]
    public var fetchedAt: Date

    public init(bbox: BoundingBox, buildings: [Building], trees: [Tree], canopies: [CanopyArea],
                graph: WalkGraph, coolSpots: [CoolSpot], fetchedAt: Date) {
        self.bbox = bbox
        self.buildings = buildings
        self.trees = trees
        self.canopies = canopies
        self.graph = graph
        self.coolSpots = coolSpots
        self.fetchedAt = fetchedAt
    }
}

/// Shadow polygons for map display.
public struct ShadeOverlay: Sendable {
    /// Each polygon is an open ring.
    public var polygons: [[GeoCoordinate]]
    public var sun: SunPosition
    public var date: Date

    public init(polygons: [[GeoCoordinate]], sun: SunPosition, date: Date) {
        self.polygons = polygons
        self.sun = sun
        self.date = date
    }
}
