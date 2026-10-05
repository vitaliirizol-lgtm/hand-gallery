import Foundation

/// Shaded / sunny runs of a route laid out along its polyline, for "In shade now · Sun for next 120 m" style queries.
///
/// Built from `WalkRoute.segments` (cumulative run lengths). Adjacent runs with the same state are merged and the
/// run boundaries are scaled so they end exactly at the polyline length.
public struct RouteShadeRuns: Hashable, Sendable {
    /// One merged run, in metres along the route.
    public struct Run: Hashable, Sendable {
        public var start: Double
        public var end: Double
        public var isShaded: Bool

        public init(start: Double, end: Double, isShaded: Bool) {
            self.start = start
            self.end = end
            self.isShaded = isShaded
        }

        public var length: Double { end - start }
    }

    /// Shade state at a point along the route.
    public struct State: Hashable, Sendable {
        public var isInShade: Bool
        /// Metres until the next sunny run starts (0 if in sun now, nil if no more sun ahead).
        public var distanceToNextSun: Double?
        /// Remaining length of the current sunny run, or full length of the next one; nil if no more sun ahead.
        public var nextSunLength: Double?
        public var remainingShadedDistance: Double
        public var remainingSunnyDistance: Double
    }

    /// Merged runs covering `[0, totalLength]`, ascending. Never empty.
    public let runs: [Run]
    public let totalLength: Double

    /// - Parameters:
    ///   - route: route whose `segments` describe the runs. Without segments the whole route is one run, shaded when
    ///     the sun is down or `shadeFraction ≥ 0.5`.
    ///   - totalLength: polyline length the runs are scaled to (defaults to the length of `route.coordinates`).
    public init(route: WalkRoute, totalLength: Double? = nil) {
        let total = max(0, totalLength ?? GeoMath.length(of: route.coordinates))
        self.totalLength = total
        let segments = route.segments.filter { $0.length.isFinite && $0.length > 0 }
        let sum = segments.reduce(0) { $0 + $1.length }
        guard !segments.isEmpty, sum > 0 else {
            let shaded = !route.sun.isUp || route.shadeFraction >= 0.5
            runs = [Run(start: 0, end: total, isShaded: shaded)]
            return
        }
        let scale = total / sum
        var out: [Run] = []
        var cursor = 0.0
        for segment in segments {
            let end = cursor + segment.length * scale
            if let last = out.last, last.isShaded == segment.isShaded {
                out[out.count - 1].end = end
            } else {
                out.append(Run(start: cursor, end: end, isShaded: segment.isShaded))
            }
            cursor = end
        }
        // Remove floating-point drift so the last run ends exactly at the polyline end.
        out[out.count - 1].end = total
        runs = out
    }

    /// Index of the run containing `distance` (clamped to the route).
    public func runIndex(at distance: Double) -> Int {
        let d = min(max(distance, 0), totalLength)
        // Last run whose start ≤ d: a point exactly on a boundary belongs to the run that starts there.
        var lo = 0, hi = runs.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if runs[mid].start <= d { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Shade state at `distance` metres along the route.
    public func state(at distance: Double) -> State {
        let d = min(max(distance, 0), totalLength)
        let index = runIndex(at: d)
        var shaded = 0.0, sunny = 0.0
        for run in runs[index...] {
            let overlap = max(0, run.end - max(run.start, d))
            if run.isShaded { shaded += overlap } else { sunny += overlap }
        }
        let current = runs[index]
        if !current.isShaded {
            return State(isInShade: false, distanceToNextSun: 0, nextSunLength: max(0, current.end - d),
                         remainingShadedDistance: shaded, remainingSunnyDistance: sunny)
        }
        let next = runs[(index + 1)...].first { !$0.isShaded && $0.length > 0 }
        return State(isInShade: true, distanceToNextSun: next.map { max(0, $0.start - d) }, nextSunLength: next?.length,
                     remainingShadedDistance: shaded, remainingSunnyDistance: sunny)
    }
}
