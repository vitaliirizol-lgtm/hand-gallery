import Foundation

/// Spherical-earth helpers on `GeoCoordinate`s.
public enum GeoMath {
    /// Mean earth radius (IUGG), metres.
    public static let earthRadius = 6_371_008.8
    public static let metersPerDegreeLatitude = earthRadius * .pi / 180

    public static func metersPerDegreeLongitude(at latitude: Double) -> Double {
        metersPerDegreeLatitude * cos(latitude * .pi / 180)
    }

    @inlinable public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    @inlinable public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Normalises an angle in degrees to `[0, 360)`.
    public static func normalizeDegrees(_ d: Double) -> Double {
        let r = d.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    /// Signed smallest difference `b − a` in degrees, in `(-180, 180]`.
    public static func angleDifference(from a: Double, to b: Double) -> Double {
        var d = normalizeDegrees(b - a)
        if d > 180 { d -= 360 }
        return d
    }

    /// Great-circle distance in metres (haversine).
    public static func distance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let φ1 = radians(a.latitude), φ2 = radians(b.latitude)
        let dφ = φ2 - φ1, dλ = radians(b.longitude - a.longitude)
        let h = sin(dφ / 2) * sin(dφ / 2) + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * asin(min(1, h.squareRoot()))
    }

    /// Initial bearing from `a` to `b`, degrees clockwise from true north, `[0, 360)`.
    public static func bearing(from a: GeoCoordinate, to b: GeoCoordinate) -> Double {
        let φ1 = radians(a.latitude), φ2 = radians(b.latitude)
        let dλ = radians(b.longitude - a.longitude)
        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return normalizeDegrees(degrees(atan2(y, x)))
    }

    /// Point reached by travelling `distance` metres from `start` on initial `bearing` (degrees).
    public static func destination(from start: GeoCoordinate, bearing: Double, distance: Double) -> GeoCoordinate {
        let δ = distance / earthRadius, θ = radians(bearing)
        let φ1 = radians(start.latitude), λ1 = radians(start.longitude)
        let φ2 = asin(sin(φ1) * cos(δ) + cos(φ1) * sin(δ) * cos(θ))
        let λ2 = λ1 + atan2(sin(θ) * sin(δ) * cos(φ1), cos(δ) - sin(φ1) * sin(φ2))
        var lon = degrees(λ2)
        lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return GeoCoordinate(latitude: degrees(φ2), longitude: lon)
    }

    /// Linear interpolation between two coordinates (fine for short distances).
    public static func interpolate(_ a: GeoCoordinate, _ b: GeoCoordinate, fraction t: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Total length of a polyline in metres.
    public static func length(of polyline: [GeoCoordinate]) -> Double {
        guard polyline.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<polyline.count { total += distance(polyline[i - 1], polyline[i]) }
        return total
    }

    /// Cumulative distances along a polyline; `result[0] == 0`, `result.last == length`.
    public static func cumulativeDistances(of polyline: [GeoCoordinate]) -> [Double] {
        guard !polyline.isEmpty else { return [] }
        var out = [0.0]
        out.reserveCapacity(polyline.count)
        for i in 1..<polyline.count { out.append(out[i - 1] + distance(polyline[i - 1], polyline[i])) }
        return out
    }

    /// Coordinate at `distance` metres along the polyline (clamped to its ends).
    public static func coordinate(along polyline: [GeoCoordinate], atDistance d: Double) -> GeoCoordinate? {
        guard let first = polyline.first else { return nil }
        if d <= 0 || polyline.count == 1 { return first }
        var walked = 0.0
        for i in 1..<polyline.count {
            let seg = distance(polyline[i - 1], polyline[i])
            if walked + seg >= d {
                let t = seg > 0 ? (d - walked) / seg : 0
                return interpolate(polyline[i - 1], polyline[i], fraction: t)
            }
            walked += seg
        }
        return polyline.last
    }

    /// Points every `spacing` metres along the polyline, always including both ends.
    public static func resample(_ polyline: [GeoCoordinate], spacing: Double) -> [GeoCoordinate] {
        guard polyline.count > 1, spacing > 0 else { return polyline }
        let total = length(of: polyline)
        guard total > 0 else { return [polyline[0]] }
        // Tolerance keeps e.g. 200.0001 m / 10 m at 20 intervals.
        let n = max(1, Int((total / spacing - 1e-6).rounded(.up)))
        var out: [GeoCoordinate] = []
        out.reserveCapacity(n + 1)
        // Walk once through the segments instead of calling coordinate(along:) n times.
        var segIndex = 1
        var segStart = 0.0
        var segLen = distance(polyline[0], polyline[1])
        for k in 0...n {
            let target = total * Double(k) / Double(n)
            while segIndex < polyline.count - 1 && segStart + segLen < target {
                segStart += segLen
                segIndex += 1
                segLen = distance(polyline[segIndex - 1], polyline[segIndex])
            }
            let t = segLen > 0 ? min(1, max(0, (target - segStart) / segLen)) : 0
            out.append(interpolate(polyline[segIndex - 1], polyline[segIndex], fraction: t))
        }
        return out
    }

    /// Result of projecting a point onto a polyline.
    public struct PolylineProjection: Hashable, Sendable {
        /// Closest point on the polyline.
        public var coordinate: GeoCoordinate
        /// Distance from the query point to `coordinate`, metres.
        public var distanceToLine: Double
        /// Distance along the polyline from its start to `coordinate`, metres.
        public var distanceAlong: Double
        /// Index `i` of the segment `[i, i+1]` that contains `coordinate`.
        public var segmentIndex: Int
        /// Fraction along that segment, `[0, 1]`.
        public var segmentFraction: Double
    }

    /// Projects `point` onto `polyline` (planar approximation around the point).
    /// Only segments whose start lies within `[minDistanceAlong, maxDistanceAlong]` (cumulative distance) are
    /// considered, which lets navigation search a window ahead of the current progress.
    public static func project(_ point: GeoCoordinate, onto polyline: [GeoCoordinate],
                               minDistanceAlong: Double = -.infinity,
                               maxDistanceAlong: Double = .infinity) -> PolylineProjection? {
        guard !polyline.isEmpty else { return nil }
        let proj = LocalProjection(origin: point)
        if polyline.count == 1 {
            let d = distance(point, polyline[0])
            return PolylineProjection(coordinate: polyline[0], distanceToLine: d, distanceAlong: 0,
                                      segmentIndex: 0, segmentFraction: 0)
        }
        var best: PolylineProjection?
        var walked = 0.0
        for i in 0..<(polyline.count - 1) {
            let segLen = distance(polyline[i], polyline[i + 1])
            defer { walked += segLen }
            if walked + segLen < minDistanceAlong { continue }
            if walked > maxDistanceAlong { break }
            let a = proj.project(polyline[i]), b = proj.project(polyline[i + 1])
            let (t, closest) = Geometry2D.closestPointOnSegment(.zero, a, b)
            let d = closest.length
            if best == nil || d < best!.distanceToLine {
                best = PolylineProjection(coordinate: proj.unproject(closest), distanceToLine: d,
                                          distanceAlong: walked + segLen * t, segmentIndex: i, segmentFraction: t)
            }
        }
        return best
    }

    /// Splits a polyline at `distance` metres; returns (head, tail) sharing the split point.
    public static func split(_ polyline: [GeoCoordinate], atDistance d: Double) -> ([GeoCoordinate], [GeoCoordinate]) {
        guard polyline.count > 1 else { return (polyline, polyline) }
        var walked = 0.0
        for i in 1..<polyline.count {
            let seg = distance(polyline[i - 1], polyline[i])
            if walked + seg >= d {
                let t = seg > 0 ? max(0, min(1, (d - walked) / seg)) : 0
                let p = interpolate(polyline[i - 1], polyline[i], fraction: t)
                let head = Array(polyline[0..<i]) + [p]
                let tail = [p] + Array(polyline[i...])
                return (head, tail)
            }
            walked += seg
        }
        return (polyline, [polyline[polyline.count - 1]])
    }
}
