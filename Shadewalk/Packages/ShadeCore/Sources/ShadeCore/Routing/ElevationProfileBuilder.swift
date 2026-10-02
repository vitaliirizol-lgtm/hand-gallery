import Foundation

/// Elevation sampling and slope profile for a route (SPEC §4.5).
public enum ElevationProfileBuilder {
    /// Samples are never closer than this (the elevation model is far coarser), metres.
    public static let minSampleSpacing = 10.0

    /// Up to `maxSamples` evenly spaced points along the route (always includes both ends when count ≥ 2).
    /// Short routes get fewer samples so that consecutive samples are at least `minSampleSpacing` apart.
    public static func samplePoints(along coordinates: [GeoCoordinate], maxSamples: Int = 60) -> [GeoCoordinate] {
        guard maxSamples > 0, let first = coordinates.first else { return [] }
        guard coordinates.count >= 2, maxSamples >= 2 else { return [first] }
        let last = coordinates[coordinates.count - 1]
        let cumulative = GeoMath.cumulativeDistances(of: coordinates)
        let total = cumulative[cumulative.count - 1]
        guard total > 0, total.isFinite else { return [first, last] }

        let wanted = Int(min(Double(maxSamples), (total / minSampleSpacing).rounded(.down) + 1))
        let n = max(2, min(maxSamples, wanted))
        var out: [GeoCoordinate] = [first]
        out.reserveCapacity(n)
        var seg = 1
        for k in 1..<(n - 1) {
            let target = total * Double(k) / Double(n - 1)
            while seg < coordinates.count - 1 && cumulative[seg] < target { seg += 1 }
            let span = cumulative[seg] - cumulative[seg - 1]
            let t = span > 0 ? min(1, max(0, (target - cumulative[seg - 1]) / span)) : 0
            out.append(GeoMath.interpolate(coordinates[seg - 1], coordinates[seg], fraction: t))
        }
        out.append(last)
        return out
    }

    /// Profile from elevations sampled evenly along a route of `totalDistance` metres.
    ///
    /// Elevations are smoothed with a 3-point moving average (2-point at the ends); ascent/descent sum the
    /// positive/negative differences of consecutive smoothed samples; `min(binCount, samples − 1)` equal-length
    /// bins carry the signed grade `Δelevation / bin length`; `maxGrade` is the largest |bin grade|.
    /// Fewer than 2 usable samples, or a non-positive distance, give zero grades.
    public static func profile(elevations: [Double], totalDistance: Double, binCount: Int = 12) -> ElevationProfile {
        let raw = sanitized(elevations)
        let n = raw.count
        guard n >= 2 else {
            return ElevationProfile(elevations: raw, sampleSpacing: 0, ascent: 0, descent: 0, maxGrade: 0, bins: [])
        }
        let distance = totalDistance.isFinite && totalDistance > 0 ? totalDistance : 0
        let spacing = distance / Double(n - 1)

        var smooth = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - 1), hi = min(n - 1, i + 1)
            var sum = 0.0
            for j in lo...hi { sum += raw[j] }
            smooth[i] = sum / Double(hi - lo + 1)
        }

        var ascent = 0.0, descent = 0.0
        for i in 1..<n {
            let d = smooth[i] - smooth[i - 1]
            if d > 0 { ascent += d } else { descent -= d }
        }

        let binTotal = max(0, min(binCount, n - 1))
        var bins: [SlopeBin] = []
        bins.reserveCapacity(binTotal)
        var maxGrade = 0.0
        if binTotal > 0 {
            // Bin boundaries in sample-index units; elevation interpolated between samples.
            func elevation(atIndex x: Double) -> Double {
                let i = min(n - 2, max(0, Int(x.rounded(.down))))
                let t = min(1, max(0, x - Double(i)))
                return smooth[i] + (smooth[i + 1] - smooth[i]) * t
            }
            let binLength = distance / Double(binTotal)
            let indexStep = Double(n - 1) / Double(binTotal)
            for b in 0..<binTotal {
                let rise = elevation(atIndex: indexStep * Double(b + 1)) - elevation(atIndex: indexStep * Double(b))
                let grade = binLength > 0 ? rise / binLength : 0
                bins.append(SlopeBin(grade: grade))
                maxGrade = max(maxGrade, abs(grade))
            }
        }
        return ElevationProfile(elevations: smooth, sampleSpacing: spacing, ascent: ascent, descent: descent,
                                maxGrade: maxGrade, bins: bins)
    }

    /// Replaces non-finite values with the nearest preceding finite value (or the first finite one);
    /// all-invalid input becomes empty.
    private static func sanitized(_ values: [Double]) -> [Double] {
        guard let firstFinite = values.first(where: \.isFinite) else { return [] }
        var last = firstFinite
        return values.map { v in
            if v.isFinite { last = v }
            return last
        }
    }
}
