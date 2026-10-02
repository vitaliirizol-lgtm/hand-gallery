import Foundation

/// Planar geometry on `Point2D` (metres).
public enum Geometry2D {
    /// Closest point to `p` on segment `ab`; returns the segment parameter `t ∈ [0, 1]` and the point.
    public static func closestPointOnSegment(_ p: Point2D, _ a: Point2D, _ b: Point2D) -> (t: Double, point: Point2D) {
        let ab = b - a
        let len2 = ab.lengthSquared
        guard len2 > 0 else { return (0, a) }
        let t = max(0, min(1, (p - a).dot(ab) / len2))
        return (t, a + ab * t)
    }

    public static func distanceToSegment(_ p: Point2D, _ a: Point2D, _ b: Point2D) -> Double {
        closestPointOnSegment(p, a, b).point.distance(to: p)
    }

    /// Even-odd point-in-polygon test. `ring` may be open or closed.
    public static func contains(_ ring: [Point2D], _ p: Point2D) -> Bool {
        let n = ring.count
        guard n >= 3 else { return false }
        var inside = false
        var j = n - 1
        for i in 0..<n {
            let pi = ring[i], pj = ring[j]
            if (pi.y > p.y) != (pj.y > p.y) {
                let xCross = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Parameter `t ≥ 0` where the ray `origin + t·dir` hits segment `ab`, or nil.
    /// `dir` need not be normalised; `t` is in units of `dir`.
    public static func raySegmentIntersection(origin: Point2D, dir: Point2D, a: Point2D, b: Point2D) -> Double? {
        let e = b - a
        let denom = dir.cross(e)
        if abs(denom) < 1e-12 { return nil } // parallel (collinear overlap ignored)
        let ao = a - origin
        let t = ao.cross(e) / denom
        let u = ao.cross(dir) / denom
        if t >= 0 && u >= 0 && u <= 1 { return t }
        return nil
    }

    /// Smallest `t ≥ 0` at which the ray crosses the polygon boundary, or 0 if `origin` is inside.
    /// Returns nil when the ray misses the polygon.
    public static func rayPolygonEntry(origin: Point2D, dir: Point2D, ring: [Point2D]) -> Double? {
        let n = ring.count
        guard n >= 3 else { return nil }
        if contains(ring, origin) { return 0 }
        var best: Double?
        var j = n - 1
        for i in 0..<n {
            if let t = raySegmentIntersection(origin: origin, dir: dir, a: ring[j], b: ring[i]) {
                if best == nil || t < best! { best = t }
            }
            j = i
        }
        return best
    }

    /// Signed area (positive = counter-clockwise).
    public static func signedArea(_ ring: [Point2D]) -> Double {
        let n = ring.count
        guard n >= 3 else { return 0 }
        var s = 0.0
        var j = n - 1
        for i in 0..<n {
            s += ring[j].x * ring[i].y - ring[i].x * ring[j].y
            j = i
        }
        return s / 2
    }

    /// Area-weighted centroid (falls back to vertex mean for degenerate rings).
    public static func centroid(_ ring: [Point2D]) -> Point2D {
        let n = ring.count
        guard n > 0 else { return .zero }
        let a = signedArea(ring)
        if abs(a) < 1e-9 {
            let sum = ring.reduce(Point2D.zero, +)
            return sum * (1 / Double(n))
        }
        var cx = 0.0, cy = 0.0
        var j = n - 1
        for i in 0..<n {
            let f = ring[j].x * ring[i].y - ring[i].x * ring[j].y
            cx += (ring[j].x + ring[i].x) * f
            cy += (ring[j].y + ring[i].y) * f
            j = i
        }
        return Point2D(x: cx / (6 * a), y: cy / (6 * a))
    }

    /// Convex hull (Andrew's monotone chain), counter-clockwise, no repeated first point.
    public static func convexHull(_ points: [Point2D]) -> [Point2D] {
        let pts = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count >= 3 else { return pts }
        func turn(_ o: Point2D, _ a: Point2D, _ b: Point2D) -> Double { (a - o).cross(b - o) }
        var lower: [Point2D] = []
        for p in pts {
            while lower.count >= 2 && turn(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [Point2D] = []
        for p in pts.reversed() {
            while upper.count >= 2 && turn(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    /// Regular polygon approximating a circle.
    public static func circle(center: Point2D, radius: Double, segments: Int = 12) -> [Point2D] {
        let n = max(3, segments)
        return (0..<n).map { k in
            let a = 2 * Double.pi * Double(k) / Double(n)
            return Point2D(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
        }
    }

    /// Removes a duplicated closing vertex, if present.
    public static func openRing(_ ring: [Point2D]) -> [Point2D] {
        guard ring.count > 1, ring.first == ring.last else { return ring }
        return Array(ring.dropLast())
    }

    /// Axis-aligned bounds `(min, max)` of a point set.
    public static func bounds(_ pts: [Point2D]) -> (min: Point2D, max: Point2D)? {
        guard let f = pts.first else { return nil }
        var lo = f, hi = f
        for p in pts.dropFirst() {
            lo.x = min(lo.x, p.x); lo.y = min(lo.y, p.y)
            hi.x = max(hi.x, p.x); hi.y = max(hi.y, p.y)
        }
        return (lo, hi)
    }
}
