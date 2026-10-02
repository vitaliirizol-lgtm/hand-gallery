import Foundation

/// Which side of a vehicle to sit on to avoid the sun. See SPEC §4.6.
public enum SeatSideAdvisor {
    /// Maximum spacing between timeline samples, seconds.
    public static let sampleInterval: TimeInterval = 30
    /// Minimum share difference (left vs right) needed to recommend a side.
    public static let decisionMargin = 0.15
    /// Cloud cover (percent) at or above which the sky counts as overcast.
    public static let overcastCloudCover = 85.0
    /// Upper bound on timeline samples; very long trips get proportionally wider steps.
    static let maxSamples = 10_000

    /// - Parameters:
    ///   - path: vehicle path (≥ 2 points).
    ///   - departure: departure time.
    ///   - duration: trip duration in seconds (> 0).
    ///   - cloudCover: percent 0–100, nil if unknown.
    public static func advise(path: [GeoCoordinate], departure: Date, duration: TimeInterval, cloudCover: Double?) -> SeatSideAdvice {
        advise(path: path, departure: departure, duration: duration, cloudCover: cloudCover,
               sunPosition: SolarCalculator.position(at:coordinate:))
    }

    /// Same as `advise(path:departure:duration:cloudCover:)` with an injectable sun model (used by tests).
    ///
    /// The path is walked at constant speed (`length / duration`) in steps of at most 30 s (at least two samples,
    /// both trip ends included). Each sample takes the heading of the path segment it lies on (zero-length segments
    /// are skipped) and classifies the sun with `classify(sun:heading:)`. Shares are time-weighted (trapezoid rule).
    /// Degenerate input (fewer than 2 valid points, zero-length path, `duration ≤ 0`) yields `either`/`balanced`
    /// with an empty timeline.
    public static func advise(path: [GeoCoordinate], departure: Date, duration: TimeInterval, cloudCover: Double?,
                              sunPosition: (Date, GeoCoordinate) -> SunPosition) -> SeatSideAdvice {
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        let degenerate = SeatSideAdvice(recommendation: .either, reason: .balanced, sunOnLeftShare: 0,
                                        sunOnRightShare: 0, sunDownFraction: 0, timeline: [], duration: safeDuration)
        let points = path.filter(\.isValid)
        guard points.count >= 2, safeDuration > 0, departure.timeIntervalSinceReferenceDate.isFinite,
              let walker = PathWalker(points) else {
            return degenerate
        }

        let intervals = min(maxSamples - 1, max(1, Int((safeDuration / sampleInterval - 1e-9).rounded(.up))))
        let count = intervals + 1
        var timeline: [SeatSideSample] = []
        timeline.reserveCapacity(count)
        var leftExposure = 0.0, rightExposure = 0.0, downWeight = 0.0, totalWeight = 0.0
        for k in 0..<count {
            let fraction = Double(k) / Double(intervals)
            let time = departure.addingTimeInterval(safeDuration * fraction)
            let (coordinate, heading) = walker.locate(distance: walker.length * fraction)
            let sun = sunPosition(time, coordinate)
            let (side, intensity) = classify(sun: sun, heading: heading)
            timeline.append(SeatSideSample(fraction: fraction, time: time, sunSide: side, intensity: intensity))

            // Trapezoid weights: the two trip ends each stand for half a step.
            let weight = (k == 0 || k == intervals) ? 0.5 : 1
            totalWeight += weight
            switch side {
            case .left: leftExposure += weight * intensity
            case .right: rightExposure += weight * intensity
            case .none: downWeight += weight
            case .ahead, .behind: break
            }
        }

        let sideTotal = leftExposure + rightExposure
        let leftShare = sideTotal > 0 ? leftExposure / sideTotal : 0
        let rightShare = sideTotal > 0 ? rightExposure / sideTotal : 0
        let sunDownFraction = totalWeight > 0 ? downWeight / totalWeight : 0
        let allDown = timeline.allSatisfy { $0.sunSide == .none }

        let recommendation: SeatSide
        let reason: SeatSideReason
        if allDown {
            (recommendation, reason) = (.either, .sunDown)
        } else if let cover = cloudCover, cover >= overcastCloudCover {
            (recommendation, reason) = (.either, .overcast)
        } else if rightShare - leftShare >= decisionMargin - 1e-9 {
            (recommendation, reason) = (.left, .sunMostlyOnRight)
        } else if leftShare - rightShare >= decisionMargin - 1e-9 {
            (recommendation, reason) = (.right, .sunMostlyOnLeft)
        } else {
            (recommendation, reason) = (.either, .balanced)
        }
        return SeatSideAdvice(recommendation: recommendation, reason: reason, sunOnLeftShare: leftShare,
                              sunOnRightShare: rightShare, sunDownFraction: sunDownFraction,
                              timeline: timeline, duration: safeDuration)
    }

    /// Where the sun is relative to a vehicle heading `heading` degrees (clockwise from north), and its side
    /// exposure weight `|sin rel| · cos(elevation)`.
    ///
    /// `rel = azimuth − heading` in `[0, 360)`: right for `(15, 165)`, left for `(195, 345)`, behind for
    /// `[165, 195]`, ahead otherwise; `.none` when the sun is down. Intensity is 0 unless the side is left/right.
    public static func classify(sun: SunPosition, heading: Double) -> (side: SunSide, intensity: Double) {
        guard sun.isUp, sun.azimuth.isFinite, heading.isFinite else { return (.none, 0) }
        let rel = GeoMath.normalizeDegrees(sun.azimuth - heading)
        let side: SunSide
        if rel > 15 && rel < 165 {
            side = .right
        } else if rel > 195 && rel < 345 {
            side = .left
        } else if rel >= 165 && rel <= 195 {
            side = .behind
        } else {
            side = .ahead
        }
        guard side == .left || side == .right else { return (side, 0) }
        let intensity = abs(sin(GeoMath.radians(rel))) * cos(GeoMath.radians(min(90, sun.elevation)))
        return (side, max(0, intensity))
    }
}

/// Constant-speed walk along a polyline: positions and segment headings by distance travelled.
private struct PathWalker {
    /// Non-degenerate segments in path order.
    private let segments: [(start: GeoCoordinate, end: GeoCoordinate, offset: Double, length: Double, bearing: Double)]
    let length: Double

    /// Nil when the path has no segment of positive length.
    init?(_ points: [GeoCoordinate]) {
        guard points.count >= 2 else { return nil }
        var segs: [(start: GeoCoordinate, end: GeoCoordinate, offset: Double, length: Double, bearing: Double)] = []
        var walked = 0.0
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let d = GeoMath.distance(a, b)
            guard d > 1e-6, d.isFinite else { continue }
            segs.append((a, b, walked, d, GeoMath.bearing(from: a, to: b)))
            walked += d
        }
        guard !segs.isEmpty, walked > 0 else { return nil }
        segments = segs
        length = walked
    }

    /// Coordinate at `distance` metres along the path and the bearing of the segment containing it.
    func locate(distance: Double) -> (GeoCoordinate, Double) {
        // Binary search for the last segment whose offset ≤ distance.
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].offset <= distance { lo = mid } else { hi = mid - 1 }
        }
        let seg = segments[lo]
        let t = min(1, max(0, (distance - seg.offset) / seg.length))
        return (Self.interpolate(seg.start, seg.end, t), seg.bearing)
    }

    /// Linear interpolation that takes the short way across the ±180° meridian.
    private static func interpolate(_ a: GeoCoordinate, _ b: GeoCoordinate, _ t: Double) -> GeoCoordinate {
        var dLon = b.longitude - a.longitude
        if dLon > 180 { dLon -= 360 } else if dLon < -180 { dLon += 360 }
        var lon = a.longitude + dLon * t
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        return GeoCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: lon)
    }
}
