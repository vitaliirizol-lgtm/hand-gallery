import Foundation

/// Axis-aligned rectangle in projected metres.
struct ShadeRect: Hashable, Sendable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    /// Bounds of `points[range]`; nil when the range is empty.
    init?(_ points: [Point2D], _ range: Range<Int>) {
        guard let first = range.first else { return nil }
        var lo = points[first], hi = points[first]
        for i in range.dropFirst() {
            let p = points[i]
            if p.x < lo.x { lo.x = p.x } else if p.x > hi.x { hi.x = p.x }
            if p.y < lo.y { lo.y = p.y } else if p.y > hi.y { hi.y = p.y }
        }
        self.init(minX: lo.x, minY: lo.y, maxX: hi.x, maxY: hi.y)
    }

    /// Square of half-size `radius` around `center`.
    init(center: Point2D, radius: Double) {
        self.init(minX: center.x - radius, minY: center.y - radius, maxX: center.x + radius, maxY: center.y + radius)
    }

    var center: Point2D { Point2D(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
    var width: Double { maxX - minX }
    var height: Double { maxY - minY }

    func union(_ o: ShadeRect) -> ShadeRect {
        ShadeRect(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    func offset(by v: Point2D) -> ShadeRect {
        ShadeRect(minX: minX + v.x, minY: minY + v.y, maxX: maxX + v.x, maxY: maxY + v.y)
    }

    func expanded(by d: Double) -> ShadeRect {
        ShadeRect(minX: minX - d, minY: minY - d, maxX: maxX + d, maxY: maxY + d)
    }

    func intersects(_ o: ShadeRect) -> Bool {
        !(o.minX > maxX || o.maxX < minX || o.minY > maxY || o.maxY < minY)
    }

    @inline(__always)
    func contains(_ p: Point2D) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    /// Distance from `p` to the rectangle (0 inside).
    func distance(to p: Point2D) -> Double {
        let dx = max(minX - p.x, 0, p.x - maxX)
        let dy = max(minY - p.y, 0, p.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Parameter interval `[near, far]` (unclamped) of the line `origin + t·dir` inside the rectangle, or nil if
    /// the line misses it. A zero `dir` component is handled without producing NaNs.
    @inline(__always)
    func lineInterval(origin: Point2D, dir: Point2D) -> (near: Double, far: Double)? {
        var near = -Double.infinity, far = Double.infinity
        if dir.x != 0 {
            let inv = 1 / dir.x
            var a = (minX - origin.x) * inv, b = (maxX - origin.x) * inv
            if a > b { swap(&a, &b) }
            near = a; far = b
        } else if origin.x < minX || origin.x > maxX {
            return nil
        }
        if dir.y != 0 {
            let inv = 1 / dir.y
            var a = (minY - origin.y) * inv, b = (maxY - origin.y) * inv
            if a > b { swap(&a, &b) }
            if a > near { near = a }
            if b < far { far = b }
        } else if origin.y < minY || origin.y > maxY {
            return nil
        }
        return near <= far ? (near, far) : nil
    }
}

/// Uniform square-cell grid over a rectangle (cells indexed row-major).
struct ShadeGrid: Sendable {
    let originX: Double
    let originY: Double
    let cellSize: Double
    let columns: Int
    let rows: Int

    var cellCount: Int { columns * rows }
    var bounds: ShadeRect {
        ShadeRect(minX: originX, minY: originY,
                  maxX: originX + Double(columns) * cellSize, maxY: originY + Double(rows) * cellSize)
    }

    /// Grid covering `rect` with cells of `targetCellSize` metres, grown if that would exceed `maxCells`.
    init?(covering rect: ShadeRect, targetCellSize: Double, maxCells: Int) {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
              rect.maxX >= rect.minX, rect.maxY >= rect.minY, targetCellSize > 0, maxCells > 0 else { return nil }
        var size = targetCellSize
        // +1 so a coordinate exactly on the max edge still maps to a real cell.
        func dims(_ s: Double) -> (Double, Double) {
            ((rect.width / s).rounded(.down) + 1, (rect.height / s).rounded(.down) + 1)
        }
        var (c, r) = dims(size)
        while c * r > Double(maxCells) {
            size *= max(1.25, (c * r / Double(maxCells)).squareRoot())
            (c, r) = dims(size)
        }
        originX = rect.minX
        originY = rect.minY
        cellSize = size
        columns = Int(c)
        rows = Int(r)
    }

    /// Grid over the union of `boxes` (grown by `padding`); the cell size starts at `targetCellSize` and doubles
    /// while registering every box would need more than `maxEntries` cell entries (pathological huge polygons).
    static func fitted(to boxes: [ShadeRect], padding: Double, targetCellSize: Double, maxCells: Int,
                       maxEntries: Int) -> ShadeGrid? {
        guard let first = boxes.first else { return nil }
        let bounds = boxes.dropFirst().reduce(first) { $0.union($1) }.expanded(by: max(padding, 0) + 1)
        var size = targetCellSize
        var grid = ShadeGrid(covering: bounds, targetCellSize: size, maxCells: maxCells)
        for _ in 0..<32 {
            guard let g = grid else { return nil }
            if g.cellCount == 1 { return g }
            var entries = 0
            for b in boxes {
                let e = b.expanded(by: padding)
                entries += (g.column(e.maxX) - g.column(e.minX) + 1) * (g.row(e.maxY) - g.row(e.minY) + 1)
                if entries > maxEntries { break }
            }
            if entries <= maxEntries { return g }
            size = g.cellSize * 2
            grid = ShadeGrid(covering: bounds, targetCellSize: size, maxCells: maxCells)
        }
        return grid
    }

    /// Clamped column of `x` (NaN → 0).
    @inline(__always)
    func column(_ x: Double) -> Int {
        let c = ((x - originX) / cellSize).rounded(.down)
        return !(c > 0) ? 0 : (c >= Double(columns - 1) ? columns - 1 : Int(c))
    }

    /// Clamped row of `y` (NaN → 0).
    @inline(__always)
    func row(_ y: Double) -> Int {
        let r = ((y - originY) / cellSize).rounded(.down)
        return !(r > 0) ? 0 : (r >= Double(rows - 1) ? rows - 1 : Int(r))
    }

    /// Cell containing `p`, or nil when `p` is outside the grid.
    func cell(containing p: Point2D) -> Int? {
        guard bounds.contains(p) else { return nil }
        return row(p.y) * columns + column(p.x)
    }
}

/// Compressed per-cell item lists (CSR layout): items of cell `c` are `items[starts[c] ..< starts[c + 1]]`.
struct ShadeGridBuckets: Sendable {
    let starts: [Int32]
    let items: [Int32]

    static let empty = ShadeGridBuckets(starts: [], items: [])

    private init(starts: [Int32], items: [Int32]) {
        self.starts = starts
        self.items = items
    }

    /// Registers item `i` in every cell overlapping `boxes[i]` grown by `padding`.
    init(grid: ShadeGrid, boxes: [ShadeRect], padding: Double) {
        guard !boxes.isEmpty else { self = .empty; return }
        let bounds = grid.bounds
        func range(_ b: ShadeRect) -> (c0: Int, r0: Int, c1: Int, r1: Int)? {
            let e = b.expanded(by: padding)
            guard e.intersects(bounds) else { return nil }
            return (grid.column(e.minX), grid.row(e.minY), grid.column(e.maxX), grid.row(e.maxY))
        }
        var counts = [Int32](repeating: 0, count: grid.cellCount + 1)
        for b in boxes {
            guard let r = range(b) else { continue }
            for row in r.r0...r.r1 {
                let base = row * grid.columns
                for col in r.c0...r.c1 { counts[base + col + 1] += 1 }
            }
        }
        for i in 1..<counts.count { counts[i] += counts[i - 1] }
        var fill = counts
        var items = [Int32](repeating: 0, count: Int(counts[counts.count - 1]))
        for (i, b) in boxes.enumerated() {
            guard let r = range(b) else { continue }
            for row in r.r0...r.r1 {
                let base = row * grid.columns
                for col in r.c0...r.c1 {
                    let cell = base + col
                    items[Int(fill[cell])] = Int32(i)
                    fill[cell] += 1
                }
            }
        }
        self.starts = counts
        self.items = items
    }

    @inline(__always)
    func range(of cell: Int) -> Range<Int> {
        guard cell + 1 < starts.count else { return 0..<0 }
        return Int(starts[cell])..<Int(starts[cell + 1])
    }
}

/// One cell visited by a `ShadeGridRay`, with the ray-parameter interval spent inside it.
struct ShadeGridStep: Sendable {
    var cell: Int
    var tEnter: Double
    var tExit: Double
}

/// Amanatides–Woo traversal of the grid cells crossed by the segment `origin + t·dir`, `t ∈ [0, length]`,
/// in ray order. `dir` should be a unit vector (or zero, which visits only the origin's cell).
struct ShadeGridRay: Sendable {
    private let grid: ShadeGrid
    private var col: Int
    private var row: Int
    private let stepX: Int
    private let stepY: Int
    private var tMaxX: Double
    private var tMaxY: Double
    private let tDeltaX: Double
    private let tDeltaY: Double
    private var tEnter: Double
    private let tEnd: Double
    private var remaining: Int
    private var done = false

    init?(grid: ShadeGrid, origin: Point2D, dir: Point2D, length: Double) {
        guard length >= 0, origin.x.isFinite, origin.y.isFinite, dir.x.isFinite, dir.y.isFinite,
              let clip = grid.bounds.lineInterval(origin: origin, dir: dir) else { return nil }
        let t0 = max(clip.near, 0), t1 = min(clip.far, length)
        guard t0 <= t1 else { return nil }
        self.grid = grid
        let start = Point2D(x: origin.x + dir.x * t0, y: origin.y + dir.y * t0)
        col = grid.column(start.x)
        row = grid.row(start.y)
        let s = grid.cellSize
        if dir.x > 0 {
            stepX = 1
            tMaxX = (grid.originX + Double(col + 1) * s - origin.x) / dir.x
            tDeltaX = s / dir.x
        } else if dir.x < 0 {
            stepX = -1
            tMaxX = (grid.originX + Double(col) * s - origin.x) / dir.x
            tDeltaX = -s / dir.x
        } else {
            stepX = 0; tMaxX = .infinity; tDeltaX = .infinity
        }
        if dir.y > 0 {
            stepY = 1
            tMaxY = (grid.originY + Double(row + 1) * s - origin.y) / dir.y
            tDeltaY = s / dir.y
        } else if dir.y < 0 {
            stepY = -1
            tMaxY = (grid.originY + Double(row) * s - origin.y) / dir.y
            tDeltaY = -s / dir.y
        } else {
            stepY = 0; tMaxY = .infinity; tDeltaY = .infinity
        }
        tEnter = t0
        tEnd = t1
        remaining = grid.columns + grid.rows + 2
    }

    /// Next cell along the ray, or nil when the segment (or the grid) has been left.
    mutating func next() -> ShadeGridStep? {
        guard !done, remaining > 0 else { return nil }
        remaining -= 1
        let exit = max(tEnter, min(tMaxX, tMaxY, tEnd))
        let step = ShadeGridStep(cell: row * grid.columns + col, tEnter: tEnter, tExit: exit)
        if exit >= tEnd {
            done = true
        } else if tMaxX < tMaxY {
            col += stepX
            tEnter = exit
            tMaxX += tDeltaX
            if col < 0 || col >= grid.columns { done = true }
        } else {
            row += stepY
            tEnter = exit
            tMaxY += tDeltaY
            if row < 0 || row >= grid.rows { done = true }
        }
        return step
    }
}
