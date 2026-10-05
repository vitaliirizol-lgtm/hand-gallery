import Foundation
import ShadeFeatures

// Pure geometry for the Walk map and follow mode. No MapKit here: views convert with `.clCoordinates` when drawing.

/// A shaded or sunny stretch of a route, ready to draw.
struct ShadeRunPath: Hashable, Identifiable {
    let id: Int
    let coordinates: [GeoCoordinate]
    /// Metres.
    let length: Double
    let isShaded: Bool
}

enum WalkGeometry {
    /// Where to pin the label of the `index`-th route. Labels sit at different fractions of their routes so the pills
    /// of routes that share streets don't stack on top of each other.
    static func labelCoordinate(for route: WalkRoute, index: Int) -> GeoCoordinate? {
        let fractions: [Double] = [0.5, 0.34, 0.66]
        let slot = ((index % fractions.count) + fractions.count) % fractions.count
        let length = GeoMath.length(of: route.coordinates)
        return GeoMath.coordinate(along: route.coordinates, atDistance: length * fractions[slot])
    }

    /// Shaded / sunny runs of `route` from its segments. Without usable segments the whole route is one run, shaded
    /// when the sun is down or most of it is in shade.
    static func runs(of route: WalkRoute) -> [ShadeRunPath] {
        let segments = route.segments.filter { $0.coordinates.count >= 2 }
        guard !segments.isEmpty else {
            guard route.coordinates.count >= 2 else { return [] }
            let shaded = !route.sun.isUp || route.shadeFraction >= 0.5
            return [ShadeRunPath(id: 0, coordinates: route.coordinates, length: route.distance, isShaded: shaded)]
        }
        return segments.enumerated().map { index, segment in
            ShadeRunPath(id: index, coordinates: segment.coordinates, length: segment.length, isShaded: segment.isShaded)
        }
    }

    /// Distance along `route` to the point closest to `coordinate`, metres.
    static func distanceAlong(_ route: WalkRoute, to coordinate: GeoCoordinate) -> Double? {
        GeoMath.project(coordinate, onto: route.coordinates)?.distanceAlong
    }

    /// Effective walking speed of a route (including crossing and stairs delays), m/s.
    static func averageSpeed(of route: WalkRoute) -> Double {
        guard route.distance.isFinite, route.duration.isFinite, route.distance > 0, route.duration > 0 else {
            return RoutingPreferences.default.walkingSpeed
        }
        return route.distance / route.duration
    }

    /// Seconds needed to walk `meters` at the route's average speed.
    static func walkingTime(_ meters: Double, on route: WalkRoute) -> TimeInterval {
        guard meters.isFinite, meters > 0 else { return 0 }
        return meters / averageSpeed(of: route)
    }
}

/// The part of a route already walked and the shaded / sunny runs still ahead (follow mode).
struct FollowRouteGeometry {
    /// Geometry from the start to the current position.
    let passed: [GeoCoordinate]
    /// Geometry from the current position to the destination.
    let remaining: [GeoCoordinate]
    /// Shaded / sunny runs from the current position on.
    let runs: [ShadeRunPath]

    /// - Parameters:
    ///   - route: route being followed.
    ///   - distanceAlong: progress along the route's polyline, metres.
    init(route: WalkRoute, distanceAlong: Double) {
        let coordinates = route.coordinates
        let cumulative = GeoMath.cumulativeDistances(of: coordinates)
        let total = cumulative.last ?? 0
        let along = distanceAlong.isFinite ? min(max(distanceAlong, 0), total) : 0
        passed = FollowRouteGeometry.slice(coordinates, cumulative: cumulative, from: 0, to: along)
        remaining = FollowRouteGeometry.slice(coordinates, cumulative: cumulative, from: along, to: total)

        var runs: [ShadeRunPath] = []
        for run in RouteShadeRuns(route: route, totalLength: total).runs {
            let start = max(run.start, along)
            guard run.end - start > 0.5 else { continue }
            let path = FollowRouteGeometry.slice(coordinates, cumulative: cumulative, from: start, to: run.end)
            guard path.count >= 2 else { continue }
            runs.append(ShadeRunPath(id: runs.count, coordinates: path, length: run.end - start,
                                     isShaded: run.isShaded))
        }
        self.runs = runs
    }

    /// Remaining runs as segments (lengths only), e.g. for a `ShadeBar`.
    var remainingSegments: [RouteSegment] {
        runs.map { RouteSegment(coordinates: [], length: $0.length, isShaded: $0.isShaded) }
    }

    /// The polyline between `start` and `end` metres along it (both ends interpolated).
    static func slice(_ coordinates: [GeoCoordinate], cumulative: [Double], from start: Double,
                      to end: Double) -> [GeoCoordinate] {
        guard coordinates.count >= 2, coordinates.count == cumulative.count, end > start else { return [] }
        var out: [GeoCoordinate] = []
        if let first = point(coordinates, cumulative: cumulative, at: start) { out.append(first) }
        for index in coordinates.indices where cumulative[index] > start && cumulative[index] < end {
            out.append(coordinates[index])
        }
        if let last = point(coordinates, cumulative: cumulative, at: end) { out.append(last) }
        return out
    }

    /// The point `distance` metres along the polyline (clamped to its ends).
    static func point(_ coordinates: [GeoCoordinate], cumulative: [Double], at distance: Double) -> GeoCoordinate? {
        guard let first = coordinates.first else { return nil }
        guard coordinates.count >= 2, coordinates.count == cumulative.count, distance > 0 else { return first }
        let lastIndex = coordinates.count - 1
        if distance >= cumulative[lastIndex] { return coordinates[lastIndex] }
        // Smallest index whose cumulative distance reaches `distance`.
        var low = 1
        var high = lastIndex
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] >= distance { high = mid } else { low = mid + 1 }
        }
        let length = cumulative[low] - cumulative[low - 1]
        let t = length > 0 ? (distance - cumulative[low - 1]) / length : 0
        return GeoMath.interpolate(coordinates[low - 1], coordinates[low], fraction: min(max(t, 0), 1))
    }
}
