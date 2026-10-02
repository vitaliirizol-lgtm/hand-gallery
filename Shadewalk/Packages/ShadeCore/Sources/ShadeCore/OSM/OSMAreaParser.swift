import Foundation

/// Converts an Overpass JSON response into `AreaData`. See SPEC §4.4.
///
/// Synthetic ids (all negative, so they never collide with real OSM ids of the same kind):
/// buildings/canopies from multipolygon relations `-(relationID << 12 | ringIndex)`; tree-row samples
/// `-(wayID << 20 | sampleIndex)`; cool spots from ways `-2·wayID`, from relations `-(2·relationID + 1)`
/// (cool spots from nodes keep the node id).
public enum OSMAreaParser {
    /// Parses an `OverpassQueryBuilder.areaQuery` response. `bbox` and `fetchedAt` are stored as given; features
    /// reaching outside `bbox` are kept whole.
    /// - Throws: `ShadeError.decodingFailed` (see `decodeElements`).
    public static func parse(_ data: Data, bbox: BoundingBox, fetchedAt: Date) throws -> AreaData {
        areaData(from: try decodeElements(data), bbox: bbox, fetchedAt: fetchedAt)
    }

    /// Parses only cool spots (for `coolSpotQuery` responses).
    public static func parseCoolSpots(_ data: Data) throws -> [CoolSpot] {
        coolSpots(from: try decodeElements(data))
    }

    /// Decodes the `elements` of an Overpass JSON response, merging duplicates by `(type, id)` and sorting by
    /// type then id. Malformed individual elements are skipped.
    /// - Throws: `ShadeError.decodingFailed` for invalid JSON, a missing `elements` array, or an Overpass
    ///   `runtime error` remark (timeout / out of memory: the element list is incomplete).
    public static func decodeElements(_ data: Data) throws -> [OSMElement] {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ShadeError.decodingFailed("invalid Overpass JSON")
        }
        if let remark = response.remark, remark.contains("runtime error") {
            throw ShadeError.decodingFailed("Overpass \(remark.prefix(160))")
        }
        guard let elements = response.elements else {
            throw ShadeError.decodingFailed("missing elements")
        }
        return OSMElement.merged(elements.compactMap(\.value))
    }

    /// Assembles `AreaData` from decoded elements.
    public static func areaData(from elements: [OSMElement], bbox: BoundingBox, fetchedAt: Date) -> AreaData {
        let sorted = OSMElement.merged(elements)
        let nodeCoordinates = nodePositions(sorted)
        return AreaData(bbox: bbox,
                        buildings: buildings(from: sorted, nodeCoordinates: nodeCoordinates),
                        trees: trees(from: sorted, nodeCoordinates: nodeCoordinates),
                        canopies: canopies(from: sorted, nodeCoordinates: nodeCoordinates),
                        graph: WalkGraphBuilder.build(from: sorted),
                        coolSpots: coolSpots(from: sorted),
                        fetchedAt: fetchedAt)
    }

    // MARK: Buildings

    /// `building=` values that are not (or no longer) standing structures.
    static let ignoredBuildingValues: Set<String> = ["no", "proposed", "demolished", "destroyed", "razed"]

    /// Buildings from closed `building=*` ways and the outer rings of `building=*` multipolygon relations
    /// (one `Building` per ring; inner rings are ignored).
    public static func buildings(from elements: [OSMElement],
                                 nodeCoordinates: [Int64: GeoCoordinate] = [:]) -> [Building] {
        var out: [Building] = []
        for e in elements {
            guard let value = e.tags["building"], !ignoredBuildingValues.contains(value) else { continue }
            let heights = OSMBuildingHeights(tags: e.tags)
            func make(_ id: Int64, _ ring: [GeoCoordinate]) -> Building {
                Building(id: id, footprint: ring, height: heights.height, minHeight: heights.minHeight,
                         isRoofOnly: heights.isRoofOnly)
            }
            switch e.type {
            case .way:
                if let ring = MultipolygonAssembler.ring(ofWay: e, nodeCoordinates: nodeCoordinates) {
                    out.append(make(e.id, ring))
                }
            case .relation where e.tags["type"] == "multipolygon":
                for (k, ring) in MultipolygonAssembler.outerRings(ofRelation: e).enumerated() {
                    out.append(make(syntheticID(e.id, index: k, bits: 12), ring))
                }
            default:
                continue
            }
        }
        return out
    }

    // MARK: Trees & canopy

    /// Tree height without a usable `height` tag, metres.
    public static let defaultTreeHeight = 8.0
    /// Crown radius without `diameter_crown` or `circumference`, metres.
    public static let defaultCrownRadius = 4.0
    /// Spacing of synthetic trees along `natural=tree_row`, metres.
    public static let treeRowSpacing = 8.0
    /// Canopy height of woods/forests without a usable `height` tag, metres.
    public static let defaultCanopyHeight = 12.0

    /// Single trees (`natural=tree` nodes) and trees sampled every ≤ 8 m along `natural=tree_row` ways.
    public static func trees(from elements: [OSMElement], nodeCoordinates: [Int64: GeoCoordinate] = [:]) -> [Tree] {
        var out: [Tree] = []
        for e in elements {
            let natural = e.tags["natural"]
            if e.type == .node, natural == "tree", let c = e.coordinate {
                out.append(Tree(id: e.id, coordinate: c, height: treeHeight(e.tags), crownRadius: crownRadius(e.tags)))
            } else if e.type == .way, natural == "tree_row",
                      let geometry = MultipolygonAssembler.coordinates(ofWay: e, nodeCoordinates: nodeCoordinates) {
                let height = treeHeight(e.tags), radius = crownRadius(e.tags)
                var index = 0
                for piece in pieces(of: geometry) {
                    for c in GeoMath.resample(piece, spacing: treeRowSpacing) {
                        out.append(Tree(id: syntheticID(e.id, index: index, bits: 20), coordinate: c,
                                        height: height, crownRadius: radius))
                        index += 1
                    }
                }
            }
        }
        return out
    }

    /// Woods and forests (`natural=wood`, `landuse=forest`) as closed ways or multipolygon outer rings.
    public static func canopies(from elements: [OSMElement],
                                nodeCoordinates: [Int64: GeoCoordinate] = [:]) -> [CanopyArea] {
        var out: [CanopyArea] = []
        for e in elements where e.tags["natural"] == "wood" || e.tags["landuse"] == "forest" {
            let height = OSMValueParser.length(e.tags["height"]).flatMap { (2...60).contains($0) ? $0 : nil }
                ?? defaultCanopyHeight
            switch e.type {
            case .way:
                if let ring = MultipolygonAssembler.ring(ofWay: e, nodeCoordinates: nodeCoordinates) {
                    out.append(CanopyArea(id: e.id, ring: ring, height: height))
                }
            case .relation where e.tags["type"] == "multipolygon":
                for (k, ring) in MultipolygonAssembler.outerRings(ofRelation: e).enumerated() {
                    out.append(CanopyArea(id: syntheticID(e.id, index: k, bits: 12), ring: ring, height: height))
                }
            default:
                continue
            }
        }
        return out
    }

    /// `height` tag (clamped to `[2, 60]`), else 8 m.
    static func treeHeight(_ tags: [String: String]) -> Double {
        guard let h = OSMValueParser.length(tags["height"]), h > 0 else { return defaultTreeHeight }
        return min(60, max(2, h))
    }

    /// `diameter_crown / 2`, else estimated from trunk `circumference` (crown ≈ 25 × trunk diameter), else 4 m.
    static func crownRadius(_ tags: [String: String]) -> Double {
        if let d = OSMValueParser.length(tags["diameter_crown"]), d > 0 {
            return min(20, max(0.5, d / 2))
        }
        if var c = OSMValueParser.length(tags["circumference"]), c > 0 {
            if c > 20 { c /= 100 } // almost certainly centimetres
            return min(12, max(1, 12.5 * c / .pi))
        }
        return defaultCrownRadius
    }

    // MARK: Cool spots

    /// Cool spots from nodes (own position) and ways/relations (`center`, else mean of known geometry).
    /// Elements with `access=private|no` are skipped.
    public static func coolSpots(from elements: [OSMElement]) -> [CoolSpot] {
        var out: [CoolSpot] = []
        for e in elements {
            guard let kind = coolSpotKind(e.tags), e.tags["access"] != "private", e.tags["access"] != "no",
                  let coordinate = position(of: e) else { continue }
            let id: Int64
            switch e.type {
            case .node: id = e.id
            case .way: id = 0 &- (e.id &* 2)
            case .relation: id = 0 &- (e.id &* 2 &+ 1)
            }
            let name = [e.tags["name"], e.tags["name:en"]].lazy.compactMap { $0 }
                .map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
            let hours = e.tags["opening_hours"].flatMap { $0.isEmpty ? nil : $0 }
            out.append(CoolSpot(id: id, kind: kind, name: name, coordinate: coordinate, openingHours: hours))
        }
        return out
    }

    /// Cool-spot kind for tags, or nil.
    public static func coolSpotKind(_ tags: [String: String]) -> CoolSpotKind? {
        switch tags["amenity"] {
        case "drinking_water", "water_point": return .drinkingWater
        case "library", "community_centre": return .indoorCool
        default: break
        }
        if let shop = tags["shop"], shop == "mall" || shop == "department_store" { return .indoorCool }
        if tags["amenity"] == "shelter" { return .shelter }
        if tags["leisure"] == "park" { return .park }
        return nil
    }

    // MARK: Helpers

    private struct Response: Decodable {
        var elements: [OSMLossy<OSMElement>]?
        var remark: String?
    }

    static func nodePositions(_ elements: [OSMElement]) -> [Int64: GeoCoordinate] {
        var out: [Int64: GeoCoordinate] = [:]
        for e in elements where e.type == .node {
            if let c = e.coordinate { out[e.id] = c }
        }
        return out
    }

    /// Node position, else `center`, else mean of the known way/member geometry.
    static func position(of e: OSMElement) -> GeoCoordinate? {
        if let c = e.coordinate ?? e.center { return c }
        var points = (e.geometry ?? []).compactMap { $0 }
        if points.isEmpty, let members = e.members {
            points = members.flatMap { m in (m.geometry ?? []).compactMap { $0 } + [m.coordinate].compactMap { $0 } }
        }
        guard !points.isEmpty else { return nil }
        let n = Double(points.count)
        return GeoCoordinate(latitude: points.reduce(0) { $0 + $1.latitude } / n,
                             longitude: points.reduce(0) { $0 + $1.longitude } / n)
    }

    /// Splits geometry at `nil` entries into polylines of ≥ 2 points.
    static func pieces(of geometry: [GeoCoordinate?]) -> [[GeoCoordinate]] {
        var out: [[GeoCoordinate]] = []
        var current: [GeoCoordinate] = []
        for c in geometry {
            if let c {
                current.append(c)
            } else {
                if current.count >= 2 { out.append(current) }
                current = []
            }
        }
        if current.count >= 2 { out.append(current) }
        return out
    }

    /// Negative id `-(base << bits | index)`; wrapping arithmetic keeps hostile ids from trapping.
    static func syntheticID(_ base: Int64, index: Int, bits: Int64) -> Int64 {
        let low = Int64(truncatingIfNeeded: index) & ((1 << bits) - 1)
        return 0 &- ((base &<< bits) | low)
    }
}
