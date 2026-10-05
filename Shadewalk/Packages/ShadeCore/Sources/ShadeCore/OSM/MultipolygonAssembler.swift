import Foundation

/// Builds polygon rings from OSM ways and multipolygon relations.
public enum MultipolygonAssembler {
    /// Coordinates closer than this (degrees, ≈ 1 cm) are treated as the same vertex.
    static let tolerance = 1e-7

    /// Normalises a closed ring: drops consecutive duplicates and the repeated closing vertex.
    /// Returns nil unless at least 3 distinct vertices remain.
    public static func openRing(_ coordinates: [GeoCoordinate]) -> [GeoCoordinate]? {
        var ring: [GeoCoordinate] = []
        ring.reserveCapacity(coordinates.count)
        for c in coordinates where ring.last.map({ !same($0, c) }) ?? true {
            ring.append(c)
        }
        while ring.count > 1, let first = ring.first, let last = ring.last, same(first, last) {
            ring.removeLast()
        }
        guard ring.count >= 3, Set(ring).count >= 3 else { return nil }
        return ring
    }

    /// Ring of a closed way (first node id == last node id, or first coordinate == last when ids are missing).
    /// `nil` geometry entries (vertices outside the requested bbox) are skipped. Nil for open or degenerate ways.
    public static func ring(ofWay way: OSMElement, nodeCoordinates: [Int64: GeoCoordinate] = [:]) -> [GeoCoordinate]? {
        guard let geometry = coordinates(ofWay: way, nodeCoordinates: nodeCoordinates) else { return nil }
        let closed: Bool
        if let ids = way.nodes, ids.count >= 2, ids.count == geometry.count {
            closed = ids.first == ids.last
        } else if let first = geometry.first ?? nil, let last = geometry.last ?? nil {
            closed = geometry.count >= 4 && same(first, last)
        } else {
            closed = false
        }
        guard closed else { return nil }
        return openRing(geometry.compactMap { $0 })
    }

    /// Outer rings of a multipolygon relation: members with role `outer` (or no role) are joined end to end.
    /// Inner rings are ignored (v1). Requires member geometry (`out geom`).
    public static func outerRings(ofRelation relation: OSMElement) -> [[GeoCoordinate]] {
        let segments: [[GeoCoordinate]] = (relation.members ?? []).compactMap { m in
            guard m.type == .way, m.role == "outer" || m.role.isEmpty, let g = m.geometry else { return nil }
            let coords = g.compactMap { $0 }
            return coords.count >= 2 ? coords : nil
        }
        return assembleRings(segments)
    }

    /// Joins polylines into closed rings, reversing pieces where needed. Pieces that cannot be closed are dropped.
    /// Rings are returned open (closing vertex removed) and in input order of their first piece.
    public static func assembleRings(_ segments: [[GeoCoordinate]]) -> [[GeoCoordinate]] {
        let pool = segments.filter { $0.count >= 2 }
        var used = Array(repeating: false, count: pool.count)
        var rings: [[GeoCoordinate]] = []
        for start in pool.indices where !used[start] {
            used[start] = true
            var ring = pool[start]
            while let first = ring.first, let last = ring.last, !same(first, last) {
                var extended = false
                for j in pool.indices where !used[j] {
                    let piece = pool[j]
                    guard let head = piece.first, let tail = piece.last else { continue }
                    if same(head, last) {
                        ring.append(contentsOf: piece.dropFirst())
                    } else if same(tail, last) {
                        ring.append(contentsOf: piece.reversed().dropFirst())
                    } else {
                        continue
                    }
                    used[j] = true
                    extended = true
                    break
                }
                if !extended { break }
            }
            guard let first = ring.first, let last = ring.last, ring.count >= 4, same(first, last),
                  let open = openRing(ring) else { continue }
            rings.append(open)
        }
        return rings
    }

    /// Way geometry from inline `geometry`, else from node positions. Nil when neither is available.
    static func coordinates(ofWay way: OSMElement, nodeCoordinates: [Int64: GeoCoordinate]) -> [GeoCoordinate?]? {
        if let g = way.geometry { return g }
        guard let ids = way.nodes, !nodeCoordinates.isEmpty else { return nil }
        return ids.map { nodeCoordinates[$0] }
    }

    static func same(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Bool {
        abs(a.latitude - b.latitude) <= tolerance && abs(a.longitude - b.longitude) <= tolerance
    }
}
