import Foundation

/// Tunable constants of the shade model (SPEC §4.3).
enum ShadeModel {
    /// Building shadow / ray-march length cap, metres.
    static let maxBuildingShadow = 400.0
    /// Tree crown shadow offset: `treeShadowFactor · height / tan(elevation)`, capped at `maxTreeOffset`.
    static let treeShadowFactor = 0.7
    static let maxTreeOffset = 60.0
    /// Canopy-area shadow offset: `canopyShadowFactor · height / tan(elevation)`, capped at `maxCanopyOffset`.
    static let canopyShadowFactor = 0.7
    static let maxCanopyOffset = 30.0
    /// Above this sun elevation (degrees) the unshifted canopy polygon also counts as shaded.
    static let unshiftedCanopyElevation = 60.0
    /// Underside height of roof-only structures without an explicit `minHeight`, metres.
    static let defaultRoofMinHeight = 2.5
    /// Height assumed for a roof-only structure with a missing/invalid height, metres.
    static let defaultRoofHeight = 4.0
    /// Sanity cap on tree crown radii (bad data would otherwise shade whole blocks), metres.
    static let maxCrownRadius = 30.0
    /// Target spatial-index cell size, metres.
    static let cellSize = 25.0
    /// Upper bound on index cells; the cell size grows for very large extents.
    static let maxCells = 1 << 20
    /// Upper bound on (object, cell) index entries; the cell size grows for pathologically large polygons.
    static let maxCellEntries = 1 << 23
    /// Default sample spacing along polylines, metres, and the smallest accepted spacing.
    static let defaultSpacing = 5.0
    static let minSpacing = 0.1
    /// Upper bound on samples taken along a single polyline.
    static let maxSamples = 1_000_000
}

/// Per-sun quantities shared by all queries for one sun position.
struct ShadeSun: Sendable {
    /// Unit vector towards the sun (x = east, y = north).
    let toSun: Point2D
    /// Unit vector in which shadows are cast.
    let shadowDir: Point2D
    /// `tan(elevation)`, strictly positive.
    let tanElevation: Double
    /// Degrees, in `(0, 90]`.
    let elevation: Double

    /// Nil when the sun is down (or its elevation is not a number).
    init?(_ sun: SunPosition) {
        guard sun.isUp else { return nil }
        let e = min(sun.elevation, 90)
        elevation = e
        tanElevation = max(tan(GeoMath.radians(e)), 1e-12)
        toSun = sun.azimuth.isFinite ? sun.directionToSun : .zero
        shadowDir = -toSun
    }

    /// Horizontal distance at which something `height` m tall stops shading, scaled by `factor`, capped.
    @inline(__always)
    func reach(height: Double, factor: Double = 1, cap: Double) -> Double {
        min(factor * max(height, 0) / tanElevation, cap)
    }

    /// Building shadow vector for `height` (capped at `ShadeModel.maxBuildingShadow`).
    func buildingShadowVector(height: Double) -> Point2D {
        shadowDir * reach(height: height, cap: ShadeModel.maxBuildingShadow)
    }

    func treeOffset(height: Double) -> Double {
        reach(height: height, factor: ShadeModel.treeShadowFactor, cap: ShadeModel.maxTreeOffset)
    }

    func canopyOffset(height: Double) -> Double {
        reach(height: height, factor: ShadeModel.canopyShadowFactor, cap: ShadeModel.maxCanopyOffset)
    }

    var countsUnshiftedCanopy: Bool { elevation > ShadeModel.unshiftedCanopyElevation }
}

/// Planar helpers over rings stored in a flat point array (`points[range]` is one open ring).
enum ShadowGeometry {
    /// Even-odd point-in-polygon test (same rule as `Geometry2D.contains`).
    @inline(__always)
    static func ringContains(_ points: [Point2D], _ range: Range<Int>, _ p: Point2D) -> Bool {
        guard range.count >= 3 else { return false }
        var inside = false
        var j = range.upperBound - 1
        for i in range {
            let pi = points[i], pj = points[j]
            if (pi.y > p.y) != (pj.y > p.y) {
                let xCross = (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Smallest and largest `t ≥ 0` at which the ray `origin + t·dir` crosses the ring boundary, or nil when it
    /// never does. Edges parallel to the ray are skipped (their endpoints are caught by the adjacent edges).
    @inline(__always)
    static func rayCrossings(_ points: [Point2D], _ range: Range<Int>, origin: Point2D, dir: Point2D)
        -> (first: Double, last: Double)? {
        guard range.count >= 2 else { return nil }
        var first = Double.infinity, last = -Double.infinity
        var j = range.upperBound - 1
        for i in range {
            let a = points[j], b = points[i]
            j = i
            let ex = b.x - a.x, ey = b.y - a.y
            let denom = dir.x * ey - dir.y * ex
            if abs(denom) < 1e-12 { continue }
            let ax = a.x - origin.x, ay = a.y - origin.y
            let t = (ax * ey - ay * ex) / denom
            if t < 0 { continue }
            let u = (ax * dir.y - ay * dir.x) / denom
            if u < 0 || u > 1 { continue }
            if t < first { first = t }
            if t > last { last = t }
        }
        return first <= last ? (first, last) : nil
    }
}
