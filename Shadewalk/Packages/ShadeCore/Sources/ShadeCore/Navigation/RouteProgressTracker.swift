import Foundation

public struct RouteProgress: Hashable, Sendable {
    /// Metres along the route.
    public var distanceAlong: Double
    public var remainingDistance: Double
    public var remainingDuration: TimeInterval
    /// Fraction `[0, 1]`.
    public var fractionCompleted: Double
    public var nextManeuver: Maneuver?
    public var distanceToNextManeuver: Double?
    /// Snapped position on the route.
    public var snappedCoordinate: GeoCoordinate
    /// Distance from the fix to the route, metres.
    public var distanceFromRoute: Double
    public var isInShade: Bool
    /// Metres until the next sunny run starts (0 if in sun now, nil if no more sun ahead).
    public var distanceToNextSun: Double?
    /// Length of the next (or current) sunny run, metres.
    public var nextSunLength: Double?
    /// Remaining shaded / sunny metres.
    public var remainingShadedDistance: Double
    public var remainingSunnyDistance: Double
    public var isOffRoute: Bool
    public var hasArrived: Bool

    public init(distanceAlong: Double, remainingDistance: Double, remainingDuration: TimeInterval, fractionCompleted: Double,
                nextManeuver: Maneuver?, distanceToNextManeuver: Double?, snappedCoordinate: GeoCoordinate,
                distanceFromRoute: Double, isInShade: Bool, distanceToNextSun: Double?, nextSunLength: Double?,
                remainingShadedDistance: Double, remainingSunnyDistance: Double, isOffRoute: Bool, hasArrived: Bool) {
        self.distanceAlong = distanceAlong
        self.remainingDistance = remainingDistance
        self.remainingDuration = remainingDuration
        self.fractionCompleted = fractionCompleted
        self.nextManeuver = nextManeuver
        self.distanceToNextManeuver = distanceToNextManeuver
        self.snappedCoordinate = snappedCoordinate
        self.distanceFromRoute = distanceFromRoute
        self.isInShade = isInShade
        self.distanceToNextSun = distanceToNextSun
        self.nextSunLength = nextSunLength
        self.remainingShadedDistance = remainingShadedDistance
        self.remainingSunnyDistance = remainingSunnyDistance
        self.isOffRoute = isOffRoute
        self.hasArrived = hasArrived
    }
}

/// Tracks progress of a user along a `WalkRoute`. See SPEC §4.7.
///
/// Each fix is projected onto the route polyline, first within a window around the last progress
/// (`[last − 30 m, last + max(150 m, 3 × accuracy)]`) so parallel legs and loops don't make progress jump, then over
/// the whole route if the windowed match is more than 50 m away. Progress never falls more than 15 m behind the
/// furthest point reached (GPS jitter); a fix further back snaps to that floor and so counts as being off the route.
///
/// Off-route and arrival decisions only use fixes with `0 ≤ horizontalAccuracy ≤ 100 m`. Fixes with a negative
/// accuracy carry no usable position and leave the state unchanged. Arrival is sticky.
public struct RouteProgressTracker: Sendable {
    /// Tuning constants; defaults follow SPEC §4.7.
    public struct Configuration: Hashable, Sendable {
        /// Search window behind the last progress, metres.
        public var windowBehind: Double
        /// Minimum search window ahead of the last progress, metres.
        public var minimumWindowAhead: Double
        /// The window ahead is at least this multiple of the fix accuracy.
        public var accuracyWindowFactor: Double
        /// Windowed matches further than this from the fix fall back to a whole-route search, metres.
        public var windowFallbackDistance: Double
        /// Max distance progress may fall behind the furthest point reached, metres.
        public var maxRegression: Double
        /// Fixes less accurate than this are ignored for off-route / arrival decisions, metres.
        public var maxDecisionAccuracy: Double
        /// Off-route when further than this from the route for `offRouteFixCount` consecutive fixes, metres.
        public var offRouteDistance: Double
        public var offRouteFixCount: Int
        /// Off-route at once when further than this with accuracy ≤ `immediateOffRouteMaxAccuracy`, metres.
        public var immediateOffRouteDistance: Double
        public var immediateOffRouteMaxAccuracy: Double
        /// Arrived when within this distance of the destination, metres.
        public var arrivalDistance: Double
        /// … or when this fraction of the route is completed.
        public var arrivalFraction: Double
        /// A maneuver counts as passed once progress is within this distance of it, metres.
        public var maneuverPassedTolerance: Double

        public init(windowBehind: Double = 30, minimumWindowAhead: Double = 150, accuracyWindowFactor: Double = 3,
                    windowFallbackDistance: Double = 50, maxRegression: Double = 15, maxDecisionAccuracy: Double = 100,
                    offRouteDistance: Double = 35, offRouteFixCount: Int = 3, immediateOffRouteDistance: Double = 80,
                    immediateOffRouteMaxAccuracy: Double = 20, arrivalDistance: Double = 20, arrivalFraction: Double = 0.98,
                    maneuverPassedTolerance: Double = 2) {
            self.windowBehind = windowBehind
            self.minimumWindowAhead = minimumWindowAhead
            self.accuracyWindowFactor = accuracyWindowFactor
            self.windowFallbackDistance = windowFallbackDistance
            self.maxRegression = maxRegression
            self.maxDecisionAccuracy = maxDecisionAccuracy
            self.offRouteDistance = offRouteDistance
            self.offRouteFixCount = offRouteFixCount
            self.immediateOffRouteDistance = immediateOffRouteDistance
            self.immediateOffRouteMaxAccuracy = immediateOffRouteMaxAccuracy
            self.arrivalDistance = arrivalDistance
            self.arrivalFraction = arrivalFraction
            self.maneuverPassedTolerance = maneuverPassedTolerance
        }

        public static let `default` = Configuration()
    }

    /// Route being tracked.
    public let route: WalkRoute
    /// Thresholds in use.
    public let configuration: Configuration
    /// Cumulative distance at each route coordinate (`[0] == 0`).
    public let cumulativeDistances: [Double]
    /// Shaded / sunny runs along the polyline.
    public let shadeRuns: RouteShadeRuns
    /// Most recent result of `update(with:)`, nil before the first fix.
    public private(set) var lastProgress: RouteProgress?

    private let maneuvers: [Maneuver]
    private var distanceAlong = 0.0
    private var furthestDistance = 0.0
    private var lastDistanceFromRoute = 0.0
    private var consecutiveFarFixes = 0
    private var isOffRoute = false
    private var hasArrived = false

    public init(route: WalkRoute) {
        self.init(route: route, configuration: .default)
    }

    public init(route: WalkRoute, configuration: Configuration) {
        self.route = route
        self.configuration = configuration
        let cumulative = GeoMath.cumulativeDistances(of: route.coordinates)
        cumulativeDistances = cumulative
        shadeRuns = RouteShadeRuns(route: route, totalLength: cumulative.last ?? 0)
        maneuvers = route.maneuvers
            .filter { $0.distanceFromStart.isFinite }
            .sorted { $0.distanceFromStart < $1.distanceFromStart }
        // A route without geometry has nothing left to walk.
        hasArrived = route.coordinates.isEmpty
    }

    /// Polyline length of the route, metres.
    public var totalLength: Double { cumulativeDistances.last ?? 0 }

    /// Feeds a location fix and returns the updated progress.
    public mutating func update(with fix: LocationFix) -> RouteProgress {
        let accuracy = fix.horizontalAccuracy
        guard accuracy >= 0, fix.coordinate.isValid, !route.coordinates.isEmpty else {
            // No usable position (or nothing to follow): report the current state again.
            let progress = makeProgress(snapped: coordinate(atDistance: distanceAlong) ?? fix.coordinate,
                                        distanceFromRoute: lastDistanceFromRoute)
            lastProgress = progress
            return progress
        }
        let canDecide = accuracy <= configuration.maxDecisionAccuracy

        // 1. Project within the window ahead of the last progress, then over the whole route if that is far off.
        //    Matches behind the regression floor snap to it, so walking back along the route reads as off-route.
        let reference = distanceAlong
        let ahead = max(configuration.minimumWindowAhead, configuration.accuracyWindowFactor * accuracy)
        var candidate = project(fix.coordinate, course: fix.course, from: reference - configuration.windowBehind,
                                to: reference + ahead, reference: reference)
            .map { applyRegressionFloor($0, fix: fix.coordinate) }
        if (candidate?.distance ?? .infinity) > configuration.windowFallbackDistance,
           let global = project(fix.coordinate, course: fix.course, from: -.infinity, to: .infinity, reference: reference)
               .map({ applyRegressionFloor($0, fix: fix.coordinate) }),
           global.distance < (candidate?.distance ?? .infinity) {
            candidate = global
        }
        guard let match = candidate else {
            let progress = makeProgress(snapped: coordinate(atDistance: distanceAlong) ?? fix.coordinate,
                                        distanceFromRoute: lastDistanceFromRoute)
            lastProgress = progress
            return progress
        }
        let along = min(max(match.distanceAlong, 0), totalLength)
        let distanceFromRoute = match.distance
        distanceAlong = along
        furthestDistance = max(furthestDistance, along)
        lastDistanceFromRoute = distanceFromRoute

        // 3. Off-route.
        if canDecide && !hasArrived {
            if distanceFromRoute > configuration.offRouteDistance {
                consecutiveFarFixes += 1
                if consecutiveFarFixes >= configuration.offRouteFixCount
                    || (distanceFromRoute > configuration.immediateOffRouteDistance
                        && accuracy <= configuration.immediateOffRouteMaxAccuracy) {
                    isOffRoute = true
                }
            } else {
                consecutiveFarFixes = 0
                isOffRoute = false
            }
        }

        // 4. Arrival.
        if canDecide && !hasArrived {
            let toDestination = route.coordinates.last.map { GeoMath.distance(fix.coordinate, $0) } ?? .infinity
            if toDestination <= configuration.arrivalDistance || fraction(at: along) >= configuration.arrivalFraction {
                hasArrived = true
                isOffRoute = false
                consecutiveFarFixes = 0
            }
        }

        let progress = makeProgress(snapped: match.coordinate, distanceFromRoute: distanceFromRoute)
        lastProgress = progress
        return progress
    }

    /// Moves a match that lies more than `maxRegression` behind the furthest progress up to that floor.
    private func applyRegressionFloor(_ match: Match, fix: GeoCoordinate) -> Match {
        let floor = furthestDistance - configuration.maxRegression
        guard match.distanceAlong < floor, let c = coordinate(atDistance: floor) else { return match }
        return Match(distanceAlong: floor, distance: GeoMath.distance(fix, c), coordinate: c, bearing: match.bearing)
    }

    // MARK: - Progress assembly

    private func fraction(at along: Double) -> Double {
        totalLength > 0 ? min(1, max(0, along / totalLength)) : 1
    }

    private func makeProgress(snapped: GeoCoordinate, distanceFromRoute: Double) -> RouteProgress {
        let along = distanceAlong
        let remaining = max(0, totalLength - along)
        let remainingDuration = totalLength > 0 && route.duration.isFinite
            ? max(0, route.duration * remaining / totalLength) : 0
        let next = maneuvers.first { $0.distanceFromStart > along + configuration.maneuverPassedTolerance }
        let shade = shadeRuns.state(at: along)
        return RouteProgress(
            distanceAlong: along, remainingDistance: remaining, remainingDuration: remainingDuration,
            fractionCompleted: fraction(at: along), nextManeuver: next,
            distanceToNextManeuver: next.map { max(0, $0.distanceFromStart - along) },
            snappedCoordinate: snapped, distanceFromRoute: distanceFromRoute, isInShade: shade.isInShade,
            distanceToNextSun: shade.distanceToNextSun, nextSunLength: shade.nextSunLength,
            remainingShadedDistance: shade.remainingShadedDistance, remainingSunnyDistance: shade.remainingSunnyDistance,
            isOffRoute: isOffRoute, hasArrived: hasArrived)
    }

    // MARK: - Geometry

    private struct Match {
        var distanceAlong: Double
        /// Distance from the fix, metres.
        var distance: Double
        var coordinate: GeoCoordinate
        /// Bearing of the matched segment, degrees (nil for zero-length segments).
        var bearing: Double?
    }

    /// Closest point on the route between `lo` and `hi` metres along it.
    ///
    /// Near-equal matches on different passes of the route (overlapping out-and-back geometry) are disambiguated by
    /// the fix's course when known (segment direction within 90°), then by closeness to `reference`, ahead on ties.
    private func project(_ point: GeoCoordinate, course: Double?, from lo: Double, to hi: Double,
                         reference: Double) -> Match? {
        let coords = route.coordinates
        guard let first = coords.first else { return nil }
        guard coords.count > 1 else {
            return Match(distanceAlong: 0, distance: GeoMath.distance(point, first), coordinate: first, bearing: nil)
        }
        let projection = LocalProjection(origin: point)
        var candidates: [Match] = []
        var i = segmentIndex(atDistance: max(lo, 0))
        while i < coords.count - 1 {
            let start = cumulativeDistances[i], end = cumulativeDistances[i + 1]
            if start > hi { break }
            i += 1
            if end < lo { continue }
            let length = end - start
            let a = projection.project(coords[i - 1]), b = projection.project(coords[i])
            var t = Geometry2D.closestPointOnSegment(.zero, a, b).t
            if length > 0 {
                t = min(max(t, (lo - start) / length), (hi - start) / length)
                t = min(max(t, 0), 1)
            } else {
                t = 0
            }
            let ab = b - a
            let p = a + ab * t
            let bearing = ab.lengthSquared > 0 ? GeoMath.normalizeDegrees(GeoMath.degrees(atan2(ab.x, ab.y))) : nil
            candidates.append(Match(distanceAlong: start + length * t, distance: p.length,
                                    coordinate: projection.unproject(p), bearing: bearing))
        }
        guard let best = candidates.min(by: { $0.distance < $1.distance }) else { return nil }
        let tieTolerance = 0.5, distinctPassGap = 10.0
        let rivals = candidates.filter {
            $0.distance <= best.distance + tieTolerance && abs($0.distanceAlong - best.distanceAlong) > distinctPassGap
        }
        guard !rivals.isEmpty else { return best }
        var pool = [best] + rivals
        if let course, course.isFinite, course >= 0 {
            let agreeing = pool.filter { match in
                match.bearing.map { abs(GeoMath.angleDifference(from: $0, to: course)) < 90 } ?? false
            }
            if !agreeing.isEmpty { pool = agreeing }
        }
        return pool.min { a, b in
            let da = abs(a.distanceAlong - reference), db = abs(b.distanceAlong - reference)
            return da == db ? a.distanceAlong > b.distanceAlong : da < db
        }
    }

    /// Index `i` of the segment `[i, i+1]` containing `distance` (clamped to the route).
    private func segmentIndex(atDistance distance: Double) -> Int {
        let n = cumulativeDistances.count
        guard n > 1 else { return 0 }
        // Last coordinate index whose cumulative distance ≤ distance, capped to the last segment.
        var lo = 0, hi = n - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if cumulativeDistances[mid] <= distance { lo = mid } else { hi = mid - 1 }
        }
        return min(lo, n - 2)
    }

    /// Coordinate `distance` metres along the route (clamped).
    private func coordinate(atDistance distance: Double) -> GeoCoordinate? {
        let coords = route.coordinates
        guard let first = coords.first else { return nil }
        guard coords.count > 1 else { return first }
        let d = min(max(distance, 0), totalLength)
        let i = segmentIndex(atDistance: d)
        let length = cumulativeDistances[i + 1] - cumulativeDistances[i]
        let t = length > 0 ? min(1, max(0, (d - cumulativeDistances[i]) / length)) : 0
        return GeoMath.interpolate(coords[i], coords[i + 1], fraction: t)
    }
}
