import Foundation

/// OSM element kind as reported by Overpass.
public enum OSMElementType: String, Codable, Sendable, Hashable, CaseIterable, Comparable {
    case node, way, relation

    private var rank: Int {
        switch self { case .node: 0; case .way: 1; case .relation: 2 }
    }

    public static func < (a: OSMElementType, b: OSMElementType) -> Bool { a.rank < b.rank }
}

/// Relation member as returned by Overpass `out geom` (geometry present) or `out body` (no geometry).
public struct OSMMember: Hashable, Codable, Sendable {
    /// Member kind; members of unknown kinds are dropped when decoding.
    public var type: OSMElementType
    /// Id of the member element.
    public var ref: Int64
    /// `outer`, `inner`, … (empty when untagged).
    public var role: String
    /// Way members: inline geometry; `nil` entries are vertices Overpass omitted (outside the bbox).
    public var geometry: [GeoCoordinate?]?
    /// Node members: position.
    public var coordinate: GeoCoordinate?

    public init(type: OSMElementType, ref: Int64, role: String = "", geometry: [GeoCoordinate?]? = nil,
                coordinate: GeoCoordinate? = nil) {
        self.type = type
        self.ref = ref
        self.role = role
        self.geometry = geometry
        self.coordinate = coordinate
    }

    private enum CodingKeys: String, CodingKey { case type, ref, role, geometry, lat, lon }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(OSMElementType.self, forKey: .type)
        ref = try c.decode(Int64.self, forKey: .ref)
        role = (try? c.decodeIfPresent(String.self, forKey: .role)) ?? ""
        geometry = (try? c.decodeIfPresent([OSMOptionalCoordinate].self, forKey: .geometry))?.map(\.value)
        coordinate = OSMLatLon.coordinate(lat: try? c.decodeIfPresent(Double.self, forKey: .lat),
                                          lon: try? c.decodeIfPresent(Double.self, forKey: .lon))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(ref, forKey: .ref)
        try c.encode(role, forKey: .role)
        if let geometry { try c.encode(geometry.map { $0.map(OSMLatLon.init) }, forKey: .geometry) }
        if let coordinate {
            try c.encode(coordinate.latitude, forKey: .lat)
            try c.encode(coordinate.longitude, forKey: .lon)
        }
    }
}

/// One element of an Overpass JSON response. Decoding is lenient: missing or malformed optional fields become
/// `nil`/empty and unknown keys are ignored; only `type` and `id` are required.
public struct OSMElement: Hashable, Codable, Sendable {
    public var type: OSMElementType
    /// OSM id (unique per `type` only).
    public var id: Int64
    /// Node position (`lat`/`lon`).
    public var coordinate: GeoCoordinate?
    /// OSM tags; non-string values are stringified when decoding.
    public var tags: [String: String]
    /// Way node ids (`out body`/`out geom`).
    public var nodes: [Int64]?
    /// Way inline geometry (`out geom`), aligned with `nodes`; `nil` entries are vertices Overpass omitted.
    public var geometry: [GeoCoordinate?]?
    /// Way/relation centre (`out center`).
    public var center: GeoCoordinate?
    /// Relation members (`out body`/`out geom`).
    public var members: [OSMMember]?

    public init(type: OSMElementType, id: Int64, coordinate: GeoCoordinate? = nil, tags: [String: String] = [:],
                nodes: [Int64]? = nil, geometry: [GeoCoordinate?]? = nil, center: GeoCoordinate? = nil,
                members: [OSMMember]? = nil) {
        self.type = type
        self.id = id
        self.coordinate = coordinate
        self.tags = tags
        self.nodes = nodes
        self.geometry = geometry
        self.center = center
        self.members = members
    }

    private enum CodingKeys: String, CodingKey { case type, id, lat, lon, tags, nodes, geometry, center, members }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(OSMElementType.self, forKey: .type)
        id = try c.decode(Int64.self, forKey: .id)
        coordinate = OSMLatLon.coordinate(lat: try? c.decodeIfPresent(Double.self, forKey: .lat),
                                          lon: try? c.decodeIfPresent(Double.self, forKey: .lon))
        let rawTags = (try? c.decodeIfPresent([String: OSMTagValue].self, forKey: .tags)) ?? nil
        tags = rawTags?.compactMapValues(\.string) ?? [:]
        nodes = (try? c.decodeIfPresent([Int64].self, forKey: .nodes)) ?? nil
        geometry = (try? c.decodeIfPresent([OSMOptionalCoordinate].self, forKey: .geometry))?.map(\.value)
        center = ((try? c.decodeIfPresent(OSMLatLon.self, forKey: .center)) ?? nil)?.coordinate
        members = (try? c.decodeIfPresent([OSMLossy<OSMMember>].self, forKey: .members))?.compactMap(\.value)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(id, forKey: .id)
        if let coordinate {
            try c.encode(coordinate.latitude, forKey: .lat)
            try c.encode(coordinate.longitude, forKey: .lon)
        }
        if !tags.isEmpty { try c.encode(tags, forKey: .tags) }
        try c.encodeIfPresent(nodes, forKey: .nodes)
        if let geometry { try c.encode(geometry.map { $0.map(OSMLatLon.init) }, forKey: .geometry) }
        try c.encodeIfPresent(center.map(OSMLatLon.init), forKey: .center)
        try c.encodeIfPresent(members, forKey: .members)
    }

    /// Fills fields missing here from `other` (another copy of the same element, e.g. printed once with
    /// `out geom` and once with `out center`). Existing values win; geometry with more known vertices wins.
    public mutating func merge(_ other: OSMElement) {
        coordinate = coordinate ?? other.coordinate
        for (key, value) in other.tags where tags[key] == nil { tags[key] = value }
        if nodes == nil || (nodes?.isEmpty == true && other.nodes?.isEmpty == false) { nodes = other.nodes }
        if let theirs = other.geometry {
            let mine = geometry?.reduce(0) { $0 + ($1 == nil ? 0 : 1) } ?? -1
            if theirs.reduce(0, { $0 + ($1 == nil ? 0 : 1) }) > mine { geometry = theirs }
        }
        center = center ?? other.center
        if let theirs = other.members {
            let mineHasGeometry = members?.contains { $0.geometry != nil || $0.coordinate != nil } ?? false
            let theirsHasGeometry = theirs.contains { $0.geometry != nil || $0.coordinate != nil }
            if members == nil || (!mineHasGeometry && theirsHasGeometry) { members = theirs }
        }
    }

    /// Merges duplicates by `(type, id)` and returns the elements sorted by type (node, way, relation) then id.
    public static func merged<S: Sequence>(_ elements: S) -> [OSMElement] where S.Element == OSMElement {
        var index: [Key: Int] = [:]
        var out: [OSMElement] = []
        for e in elements {
            let key = Key(type: e.type, id: e.id)
            if let i = index[key] {
                out[i].merge(e)
            } else {
                index[key] = out.count
                out.append(e)
            }
        }
        out.sort { $0.type == $1.type ? $0.id < $1.id : $0.type < $1.type }
        return out
    }

    private struct Key: Hashable {
        let type: OSMElementType
        let id: Int64
    }
}

// MARK: - Lenient decoding helpers

/// `{"lat": …, "lon": …}` object.
struct OSMLatLon: Codable, Hashable, Sendable {
    var lat: Double
    var lon: Double

    init(_ c: GeoCoordinate) {
        lat = c.latitude
        lon = c.longitude
    }

    /// Valid coordinate, or nil.
    var coordinate: GeoCoordinate? { Self.coordinate(lat: lat, lon: lon) }

    static func coordinate(lat: Double??, lon: Double??) -> GeoCoordinate? {
        guard let lat = lat ?? nil, let lon = lon ?? nil else { return nil }
        let c = GeoCoordinate(latitude: lat, longitude: lon)
        return c.isValid ? c : nil
    }
}

/// Geometry entry that may be `null` or malformed (decoded as nil instead of failing the array).
struct OSMOptionalCoordinate: Decodable {
    var value: GeoCoordinate?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            value = nil
        } else {
            value = (try? c.decode(OSMLatLon.self))?.coordinate
        }
    }
}

/// Tag value; numbers and booleans are stringified, anything else is dropped.
struct OSMTagValue: Decodable {
    var string: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            string = s
        } else if let i = try? c.decode(Int64.self) {
            string = String(i)
        } else if let d = try? c.decode(Double.self) {
            string = String(d)
        } else if let b = try? c.decode(Bool.self) {
            string = b ? "yes" : "no"
        } else {
            string = nil
        }
    }
}

/// Array element that decodes to nil instead of failing the whole array.
struct OSMLossy<T: Decodable>: Decodable {
    var value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
