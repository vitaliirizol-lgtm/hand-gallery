import Foundation

/// A polyline prepared for shade sampling: projected vertices plus cumulative (great-circle) distances.
struct ShadePolyline: Sendable {
    let coordinates: [GeoCoordinate]
    let projected: [Point2D]
    /// `cumulative[i]` = metres from the start to vertex `i`.
    let cumulative: [Double]

    var length: Double { cumulative.last ?? 0 }

    init(_ coordinates: [GeoCoordinate], projection: LocalProjection) {
        self.coordinates = coordinates
        projected = projection.project(coordinates)
        cumulative = GeoMath.cumulativeDistances(of: coordinates)
    }

    /// Sanitised sample spacing (non-positive / non-finite → default; tiny values clamped).
    static func spacing(_ s: Double) -> Double {
        guard s.isFinite, s > 0 else { return ShadeModel.defaultSpacing }
        return max(s, ShadeModel.minSpacing)
    }

    /// Distances of evenly spaced samples (every ≤ `spacing` m, both ends included, ≥ 2 samples) — or a single
    /// sample at 0 for an empty-length polyline. Empty for an empty polyline.
    func sampleDistances(spacing: Double) -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        let total = length
        guard coordinates.count > 1, total > 0, total.isFinite else { return [0] }
        // Tolerance keeps e.g. 200.0001 m / 10 m at 20 intervals (matches GeoMath.resample).
        let raw = (total / ShadePolyline.spacing(spacing) - 1e-6).rounded(.up)
        let n = raw.isFinite ? Int(min(max(raw, 1), Double(ShadeModel.maxSamples))) : 1
        return (0...n).map { total * Double($0) / Double(n) }
    }

    /// Segment `i` (between vertices `i` and `i+1`) containing distance `d`, searching forward from `hint`.
    @inline(__always)
    func segment(containing d: Double, from hint: Int) -> Int {
        var i = max(0, min(hint, coordinates.count - 2))
        while i < coordinates.count - 2 && cumulative[i + 1] < d { i += 1 }
        return i
    }

    /// Projected point at distance `d` (requires ≥ 2 vertices).
    @inline(__always)
    func point(atDistance d: Double, segment i: Int) -> Point2D {
        let segLen = cumulative[i + 1] - cumulative[i]
        let t = segLen > 0 ? min(1, max(0, (d - cumulative[i]) / segLen)) : 0
        let a = projected[i], b = projected[i + 1]
        return Point2D(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Geographic coordinate at distance `d`; snaps to a vertex within 1 mm so boundaries never duplicate vertices.
    func coordinate(atDistance d: Double, segment i: Int) -> GeoCoordinate {
        if abs(d - cumulative[i]) <= 1e-3 { return coordinates[i] }
        if abs(d - cumulative[i + 1]) <= 1e-3 { return coordinates[i + 1] }
        let segLen = cumulative[i + 1] - cumulative[i]
        let t = segLen > 0 ? min(1, max(0, (d - cumulative[i]) / segLen)) : 0
        return GeoMath.interpolate(coordinates[i], coordinates[i + 1], fraction: t)
    }

    /// Projected sample points for `distances` (ascending).
    func points(at distances: [Double]) -> [Point2D] {
        guard coordinates.count > 1 else { return projected.isEmpty ? [] : [projected[0]] }
        var seg = 0
        return distances.map { d in
            seg = segment(containing: d, from: seg)
            return point(atDistance: d, segment: seg)
        }
    }
}

/// A shaded or sunny interval `[start, end]` (metres along a polyline).
struct ShadeRun: Hashable, Sendable {
    var start: Double
    var end: Double
    var isShaded: Bool
    var length: Double { end - start }
}

enum ShadeRunBuilder {
    /// Runs from classified samples: each sample owns the stretch up to halfway to its neighbours.
    static func runs(sampleDistances d: [Double], shaded: [Bool], total: Double) -> [ShadeRun] {
        guard let first = shaded.first, d.count == shaded.count else { return [] }
        var out: [ShadeRun] = []
        var start = 0.0
        var cls = first
        for k in 1..<max(1, shaded.count) where shaded[k] != cls {
            let boundary = (d[k - 1] + d[k]) / 2
            out.append(ShadeRun(start: start, end: boundary, isShaded: cls))
            start = boundary
            cls = shaded[k]
        }
        out.append(ShadeRun(start: start, end: total, isShaded: cls))
        return out
    }

    /// Repeatedly flips the shortest run shorter than `minLength` (merging it with its neighbours) until every run
    /// is at least `minLength` long or a single run remains. Ties go to the earlier run. O(R log R).
    /// A non-positive (or NaN) `minLength` disables merging; `.infinity` merges everything into one run.
    static func merge(_ input: [ShadeRun], minLength: Double) -> [ShadeRun] {
        guard input.count > 1, minLength > 0 else { return input }
        var runs = input
        let n = runs.count
        var prev = Array(-1..<(n - 1))
        var next = Array(1...n)
        next[n - 1] = -1
        var alive = [Bool](repeating: true, count: n)
        var heap = MinHeap()
        for i in 0..<n where runs[i].length < minLength { heap.push(.init(length: runs[i].length, index: i)) }
        var aliveCount = n
        while aliveCount > 1, let top = heap.pop() {
            let i = top.index
            // Skip stale entries (run gone, or grown since it was queued).
            guard alive[i], runs[i].length == top.length, runs[i].length < minLength else { continue }
            let l = prev[i], r = next[i]
            if l >= 0 && r >= 0 {
                // Neighbours share the opposite class: fuse l + i + r into l.
                runs[l].end = runs[r].end
                alive[i] = false; alive[r] = false
                aliveCount -= 2
                let rr = next[r]
                next[l] = rr
                if rr >= 0 { prev[rr] = l }
                if runs[l].length < minLength { heap.push(.init(length: runs[l].length, index: l)) }
            } else if l >= 0 {
                runs[l].end = runs[i].end
                alive[i] = false
                aliveCount -= 1
                next[l] = -1
                if runs[l].length < minLength { heap.push(.init(length: runs[l].length, index: l)) }
            } else if r >= 0 {
                runs[r].start = runs[i].start
                alive[i] = false
                aliveCount -= 1
                prev[r] = -1
                if runs[r].length < minLength { heap.push(.init(length: runs[r].length, index: r)) }
            }
        }
        return (0..<n).compactMap { alive[$0] ? runs[$0] : nil }
    }

    /// Binary min-heap ordered by (length, index).
    private struct MinHeap {
        struct Entry {
            var length: Double
            var index: Int
            static func < (a: Entry, b: Entry) -> Bool { a.length != b.length ? a.length < b.length : a.index < b.index }
        }

        private var items: [Entry] = []

        mutating func push(_ e: Entry) {
            items.append(e)
            var c = items.count - 1
            while c > 0 {
                let p = (c - 1) / 2
                guard items[c] < items[p] else { break }
                items.swapAt(c, p)
                c = p
            }
        }

        mutating func pop() -> Entry? {
            guard let top = items.first else { return nil }
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var p = 0
                while true {
                    let l = 2 * p + 1, r = l + 1
                    var m = p
                    if l < items.count && items[l] < items[m] { m = l }
                    if r < items.count && items[r] < items[m] { m = r }
                    if m == p { break }
                    items.swapAt(p, m)
                    p = m
                }
            }
            return top
        }
    }

    /// Converts runs into `RouteSegment`s: boundary points plus the original vertices strictly inside each run;
    /// adjacent segments share their boundary coordinate.
    static func segments(_ runs: [ShadeRun], polyline: ShadePolyline) -> [RouteSegment] {
        let coords = polyline.coordinates, cum = polyline.cumulative
        guard coords.count > 1, let firstCoord = coords.first, let lastCoord = coords.last else { return [] }
        var out: [RouteSegment] = []
        out.reserveCapacity(runs.count)
        var seg = 0
        var vertex = 1
        var startCoord = firstCoord
        for (k, run) in runs.enumerated() {
            var pts = [startCoord]
            let isLast = k == runs.count - 1
            // Interior vertices: strictly inside (start, end), excluding those snapped to a boundary.
            while vertex < coords.count - 1 && cum[vertex] <= run.start + 1e-3 { vertex += 1 }
            while vertex < coords.count - 1 && (isLast || cum[vertex] < run.end - 1e-3) {
                pts.append(coords[vertex])
                vertex += 1
            }
            let endCoord: GeoCoordinate
            if isLast {
                endCoord = lastCoord
            } else {
                seg = polyline.segment(containing: run.end, from: seg)
                endCoord = polyline.coordinate(atDistance: run.end, segment: seg)
            }
            pts.append(endCoord)
            out.append(RouteSegment(coordinates: pts, length: run.length, isShaded: run.isShaded))
            startCoord = endCoord
        }
        return out
    }
}
