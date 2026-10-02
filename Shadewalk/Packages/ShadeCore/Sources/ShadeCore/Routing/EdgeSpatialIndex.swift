import Foundation

/// Uniform grid over every segment of every edge geometry (projected metres). Answers "nearest point on the
/// network" queries by visiting cells in rings around the query point, so snapping never scans all edges.
struct EdgeSpatialIndex: Sendable {
    /// Closest point on the network to a query point.
    struct Hit: Hashable, Sendable {
        var edge: Int
        /// Segment `[segment, segment + 1]` of the edge geometry.
        var segment: Int
        /// Fraction along that segment, `[0, 1]`.
        var fraction: Double
        var point: Point2D
        var distance: Double
    }

    private struct SegmentRef: Hashable, Sendable {
        var edge: Int32
        var segment: Int32
    }

    let cellSize: Double
    /// Projected geometry of all edges, flattened: edge `e` owns `points[pointStart[e] ..< pointStart[e + 1]]`.
    let points: [Point2D]
    let pointStart: [Int]
    private let cells: [Int64: [SegmentRef]]

    /// Cells further than this from the origin are clamped (protects `Int` conversion from absurd coordinates).
    private static let maxCellIndex = 1_000_000_000.0
    /// Segments covering more cells than this are not indexed (corrupt geometry spanning continents).
    private static let maxCellsPerSegment = 200_000

    /// - Parameter geometries: projected polyline per edge id.
    init(geometries: [[Point2D]], cellSize: Double = 50) {
        self.cellSize = cellSize
        var pts: [Point2D] = []
        var starts: [Int] = []
        starts.reserveCapacity(geometries.count + 1)
        for g in geometries {
            starts.append(pts.count)
            pts.append(contentsOf: g)
        }
        starts.append(pts.count)
        points = pts
        pointStart = starts

        var grid: [Int64: [SegmentRef]] = [:]
        for e in geometries.indices {
            let lo = starts[e], hi = starts[e + 1]
            guard hi - lo >= 2 else { continue }
            for i in lo..<(hi - 1) {
                let ref = SegmentRef(edge: Int32(e), segment: Int32(i - lo))
                Self.forEachCell(covering: pts[i], pts[i + 1], cellSize: cellSize) { key in
                    grid[key, default: []].append(ref)
                }
            }
        }
        cells = grid
    }

    /// Segment `segment` of `edge` as projected end points.
    func segment(_ edge: Int, _ segment: Int) -> (Point2D, Point2D) {
        let base = pointStart[edge] + segment
        return (points[base], points[base + 1])
    }

    /// Projected length of `edge`'s geometry.
    func projectedLength(of edge: Int) -> Double {
        let lo = pointStart[edge], hi = pointStart[edge + 1]
        guard hi - lo >= 2 else { return 0 }
        var total = 0.0
        for i in lo..<(hi - 1) { total += points[i].distance(to: points[i + 1]) }
        return total
    }

    /// Projected distance from the start of `edge` to the point at (`segment`, `fraction`).
    func distanceAlong(edge: Int, segment: Int, fraction: Double) -> Double {
        let lo = pointStart[edge]
        var total = 0.0
        for i in 0..<segment { total += points[lo + i].distance(to: points[lo + i + 1]) }
        let (a, b) = self.segment(edge, segment)
        return total + a.distance(to: b) * fraction
    }

    /// Nearest point on any indexed segment within `maxDistance` metres of `p`, or nil.
    /// Ties (within 1e-9 m) resolve to the lowest `(edge, segment)` so results are deterministic.
    func nearest(to p: Point2D, within maxDistance: Double) -> Hit? {
        guard p.x.isFinite, p.y.isFinite, maxDistance.isFinite, maxDistance >= 0 else { return nil }
        let cx = cellIndex(p.x), cy = cellIndex(p.y)
        let maxRing = Int((maxDistance / cellSize).rounded(.up)) + 1
        var best: Hit?
        for r in 0...maxRing {
            // Every point in a ring-r cell is at least (r - 1) cells away from p.
            if let b = best, Double(r - 1) * cellSize > b.distance { break }
            forEachCell(inRing: r, cx: cx, cy: cy) { key in
                guard let refs = cells[key] else { return }
                for ref in refs {
                    let e = Int(ref.edge), s = Int(ref.segment)
                    let (a, b) = segment(e, s)
                    let (t, q) = Geometry2D.closestPointOnSegment(p, a, b)
                    let d = q.distance(to: p)
                    if let cur = best {
                        if d > cur.distance + 1e-9 { continue }
                        if d >= cur.distance - 1e-9 && (e, s) >= (cur.edge, cur.segment) { continue }
                    }
                    best = Hit(edge: e, segment: s, fraction: t, point: q, distance: d)
                }
            }
        }
        guard let hit = best, hit.distance <= maxDistance else { return nil }
        return hit
    }

    // MARK: - Grid helpers

    private func cellIndex(_ v: Double) -> Int {
        Self.cellIndex(v, cellSize: cellSize)
    }

    private static func cellIndex(_ v: Double, cellSize: Double) -> Int {
        let c = (v / cellSize).rounded(.down)
        return Int(max(-maxCellIndex, min(maxCellIndex, c)))
    }

    private static func key(_ ix: Int, _ iy: Int) -> Int64 {
        (Int64(ix) << 32) | Int64(UInt32(truncatingIfNeeded: iy))
    }

    private func forEachCell(inRing r: Int, cx: Int, cy: Int, _ body: (Int64) -> Void) {
        if r == 0 {
            body(Self.key(cx, cy))
            return
        }
        for ix in (cx - r)...(cx + r) {
            body(Self.key(ix, cy - r))
            body(Self.key(ix, cy + r))
        }
        for iy in (cy - r + 1)..<(cy + r) {
            body(Self.key(cx - r, iy))
            body(Self.key(cx + r, iy))
        }
    }

    /// Calls `body` for every cell the segment `ab` passes through (column-wise supercover, padded by 1 mm so
    /// segments lying exactly on a cell border land in both cells).
    private static func forEachCell(covering a: Point2D, _ b: Point2D, cellSize: Double, _ body: (Int64) -> Void) {
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return }
        let eps = 1e-3
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let minY = min(a.y, b.y), maxY = max(a.y, b.y)
        let ix0 = cellIndex(minX - eps, cellSize: cellSize), ix1 = cellIndex(maxX + eps, cellSize: cellSize)
        let iyLo = cellIndex(minY - eps, cellSize: cellSize), iyHi = cellIndex(maxY + eps, cellSize: cellSize)
        // A straight segment touches about (columns + rows) cells.
        let cellEstimate = (ix1 - ix0 + 1) + (iyHi - iyLo + 1)
        guard cellEstimate <= maxCellsPerSegment else { return }
        let dx = b.x - a.x
        for ix in ix0...ix1 {
            var y0 = minY, y1 = maxY
            if abs(dx) >= 1e-9 {
                // y-range of the segment inside this column, clamped so steep segments cannot overshoot.
                let xs = min(maxX, max(minX, Double(ix) * cellSize))
                let xe = min(maxX, max(minX, Double(ix + 1) * cellSize))
                let ys = a.y + (b.y - a.y) * (xs - a.x) / dx
                let ye = a.y + (b.y - a.y) * (xe - a.x) / dx
                y0 = max(minY, min(ys, ye)); y1 = min(maxY, max(ys, ye))
            }
            let iy0 = cellIndex(y0 - eps, cellSize: cellSize), iy1 = cellIndex(y1 + eps, cellSize: cellSize)
            guard iy0 <= iy1 else { continue }
            for iy in iy0...iy1 { body(key(ix, iy)) }
        }
    }
}
