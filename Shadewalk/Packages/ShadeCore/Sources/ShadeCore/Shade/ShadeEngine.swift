import Foundation

/// Answers "is this point in shade?" for a sun position, given buildings, trees and canopy areas. See SPEC §4.3.
/// Immutable after init; safe to share across threads.
///
/// All inputs are projected once into a `LocalProjection` and indexed in a uniform grid (≈ 25 m cells).
/// Building shade is found by marching the ray from the query point towards the sun through the grid
/// (Amanatides–Woo cell traversal, nearest cells first, early exit on the first blocker).
/// Trees and canopies are indexed by their crown / polygon extent; their sun-dependent shadow offset is applied
/// at query time by looking up the point moved *towards* the sun by each caster's own offset.
public final class ShadeEngine: @unchecked Sendable {
    public let projection: LocalProjection

    /// Footprint ring of building `i` is `buildingRings[buildings[i].ring]`.
    private let buildings: [IndexedBuilding]
    private let buildingRings: [Point2D]
    private let trees: [IndexedTree]
    /// Ring of canopy `i` is `canopyRings[canopies[i].ring]`.
    private let canopies: [IndexedCanopy]
    private let canopyRings: [Point2D]
    private let grid: ShadeGrid?
    private let buildingCells: ShadeGridBuckets
    private let treeCells: ShadeGridBuckets
    private let canopyCells: ShadeGridBuckets
    private let maxBuildingHeight: Double
    private let maxTreeHeight: Double
    private let maxCanopyHeight: Double
    /// Bounds of all indexed geometry (projected), nil when there is none.
    private let dataBounds: ShadeRect?

    /// Number of buildings kept after validation (ring ≥ 3 finite vertices, positive height, `minHeight < height`
    /// unless roof-only).
    public var buildingCount: Int { buildings.count }
    /// Number of trees kept after validation (finite position, positive crown radius).
    public var treeCount: Int { trees.count }
    /// Number of canopy areas kept after validation (ring ≥ 3 finite vertices).
    public var canopyCount: Int { canopies.count }

    /// - Parameter origin: projection origin; defaults to the centre of all inputs.
    public init(buildings: [Building], trees: [Tree], canopies: [CanopyArea], origin: GeoCoordinate? = nil) {
        let projection = LocalProjection(origin: ShadeEngine.resolveOrigin(origin, buildings, trees, canopies))
        self.projection = projection

        // Buildings.
        var bRecords: [IndexedBuilding] = []
        var bRings: [Point2D] = []
        bRecords.reserveCapacity(buildings.count)
        var maxBH = 0.0
        for b in buildings {
            guard let ring = ShadeEngine.projectRing(b.footprint, projection) else { continue }
            var height = b.height
            if !(height.isFinite && height > 0) {
                guard b.isRoofOnly else { continue }
                height = ShadeModel.defaultRoofHeight
            }
            var minHeight = b.minHeight.isFinite ? max(0, b.minHeight) : 0
            if b.isRoofOnly && minHeight <= 0 { minHeight = ShadeModel.defaultRoofMinHeight }
            if minHeight >= height {
                // Degenerate slab (underside at/above the top): a solid one casts nothing and is dropped;
                // a roof-only one still covers its footprint, so give it a thin slab.
                guard b.isRoofOnly else { continue }
                minHeight = height / 2
            }
            let start = bRings.count
            bRings.append(contentsOf: ring)
            let range = start..<bRings.count
            guard let box = ShadeRect(bRings, range) else { continue }
            bRecords.append(IndexedBuilding(box: box, ring: range, height: height, minHeight: minHeight,
                                            isRoofOnly: b.isRoofOnly))
            maxBH = max(maxBH, height)
        }

        // Trees.
        var tRecords: [IndexedTree] = []
        tRecords.reserveCapacity(trees.count)
        var maxTH = 0.0
        for t in trees {
            let p = projection.project(t.coordinate)
            guard p.x.isFinite, p.y.isFinite, t.crownRadius.isFinite, t.crownRadius > 0 else { continue }
            let height = t.height.isFinite && t.height > 0 ? t.height : 0
            tRecords.append(IndexedTree(center: p, height: height,
                                        radius: min(t.crownRadius, ShadeModel.maxCrownRadius)))
            maxTH = max(maxTH, height)
        }

        // Canopies.
        var cRecords: [IndexedCanopy] = []
        var cRings: [Point2D] = []
        var maxCH = 0.0
        for c in canopies {
            guard let ring = ShadeEngine.projectRing(c.ring, projection) else { continue }
            let height = c.height.isFinite && c.height > 0 ? c.height : 0
            let start = cRings.count
            cRings.append(contentsOf: ring)
            let range = start..<cRings.count
            guard let box = ShadeRect(cRings, range) else { continue }
            cRecords.append(IndexedCanopy(box: box, ring: range, height: height))
            maxCH = max(maxCH, height)
        }

        // Grid over everything (trees by crown extent). A 1 mm pad registers boxes touching a cell border in both
        // cells, so the traversal never misses them.
        let pad = 1e-3
        let boxes = bRecords.map(\.box)
        let treeBoxes = tRecords.map { ShadeRect(center: $0.center, radius: $0.radius) }
        let canopyBoxes = cRecords.map(\.box)
        let allBoxes = boxes + treeBoxes + canopyBoxes
        let grid = ShadeGrid.fitted(to: allBoxes, padding: pad, targetCellSize: ShadeModel.cellSize,
                                    maxCells: ShadeModel.maxCells, maxEntries: ShadeModel.maxCellEntries)
        self.grid = grid
        buildingCells = grid.map { ShadeGridBuckets(grid: $0, boxes: boxes, padding: pad) } ?? .empty
        treeCells = grid.map { ShadeGridBuckets(grid: $0, boxes: treeBoxes, padding: pad) } ?? .empty
        canopyCells = grid.map { ShadeGridBuckets(grid: $0, boxes: canopyBoxes, padding: pad) } ?? .empty
        self.buildings = bRecords
        buildingRings = bRings
        self.trees = tRecords
        self.canopies = cRecords
        canopyRings = cRings
        maxBuildingHeight = maxBH
        maxTreeHeight = maxTH
        maxCanopyHeight = maxCH
        dataBounds = allBoxes.first.map { first in allBoxes.dropFirst().reduce(first) { $0.union($1) } }
    }

    public convenience init(area: AreaData) {
        self.init(buildings: area.buildings, trees: area.trees, canopies: area.canopies, origin: area.bbox.center)
    }

    // MARK: - Queries

    /// True if `coordinate` is shaded (or the sun is down).
    public func isShaded(_ coordinate: GeoCoordinate, sun: SunPosition) -> Bool {
        guard let s = ShadeSun(sun) else { return true }
        return isShaded(projection.project(coordinate), QueryContext(engine: self, sun: s))
    }

    /// Fraction `[0, 1]` of samples (every `spacing` m, ≥ 2 samples) along `polyline` that are shaded.
    public func shadeFraction(along polyline: [GeoCoordinate], sun: SunPosition, spacing: Double = 5) -> Double {
        guard let s = ShadeSun(sun) else { return 1 }
        return shadeFraction(polyline, QueryContext(engine: self, sun: s), spacing: spacing)
    }

    /// Splits `polyline` into consecutive shaded / sunny runs (adjacent runs share their boundary coordinate).
    /// Runs shorter than `minRunLength` are merged into their neighbours. Lengths sum to the polyline length.
    ///
    /// Samples are taken every `spacing` m; a run boundary lies halfway between two differently classified samples.
    /// Each run holds its boundary points plus the original vertices inside it. An empty polyline gives `[]`;
    /// a single point (or a zero-length polyline) gives one zero-length run classified at that point.
    public func shadeRuns(along polyline: [GeoCoordinate], sun: SunPosition, spacing: Double = 5,
                          minRunLength: Double = 8) -> [RouteSegment] {
        guard let first = polyline.first else { return [] }
        let line = ShadePolyline(polyline, projection: projection)
        let total = line.length
        guard polyline.count > 1, total > 0, total.isFinite else {
            return [RouteSegment(coordinates: polyline, length: 0, isShaded: isShaded(first, sun: sun))]
        }
        guard let s = ShadeSun(sun) else {
            return [RouteSegment(coordinates: polyline, length: total, isShaded: true)]
        }
        let ctx = QueryContext(engine: self, sun: s)
        let distances = line.sampleDistances(spacing: spacing)
        let shaded = line.points(at: distances).map { isShaded($0, ctx) }
        let runs = ShadeRunBuilder.merge(ShadeRunBuilder.runs(sampleDistances: distances, shaded: shaded, total: total),
                                         minLength: minRunLength)
        return ShadeRunBuilder.segments(runs, polyline: line)
    }

    /// Shade fraction per edge id (`result.count == graph.edges.count`). Covered edges → 1.
    ///
    /// `result[i]` belongs to `graph.edges[i]` (edge ids are dense indexes). Sampling follows `shadeFraction`
    /// with the default 5 m spacing; large graphs are processed in parallel.
    public func edgeShadeFractions(for graph: WalkGraph, sun: SunPosition) -> [Double] {
        let edges = graph.edges
        guard let s = ShadeSun(sun) else { return [Double](repeating: 1, count: edges.count) }
        let ctx = QueryContext(engine: self, sun: s)
        func fraction(_ i: Int) -> Double {
            let e = edges[i]
            return e.isCovered ? 1 : shadeFraction(e.geometry, ctx, spacing: ShadeModel.defaultSpacing)
        }
        var out = [Double](repeating: 0, count: edges.count)
        let chunk = 128
        let chunks = (edges.count + chunk - 1) / chunk
        if chunks <= 1 {
            for i in edges.indices { out[i] = fraction(i) }
            return out
        }
        out.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            // Each iteration writes a disjoint index range; the engine itself is immutable.
            DispatchQueue.concurrentPerform(iterations: chunks) { c in
                let lo = c * chunk, hi = min(lo + chunk, edges.count)
                for i in lo..<hi { base[i] = fraction(i) }
            }
        }
        return out
    }

    /// Shadow polygons (open rings) intersecting `bbox` (all if nil), at most `maxPolygons`.
    ///
    /// Solid buildings: convex hull of the footprint and the footprint moved by the shadow vector of its height.
    /// Raised structures (`minHeight > 0`, roof-only): hull of the footprint moved by the shadow vectors of
    /// `minHeight` and `height`; roof-only structures also add their footprint. Trees: 12-gon crown discs at the
    /// offset centre. Canopies: the ring moved by its offset. Shadow vectors are capped at 400 m. When more than
    /// `maxPolygons` qualify, those closest to the bbox centre (data centre if nil) are kept. Empty when the sun is down.
    public func shadowPolygons(sun: SunPosition, within bbox: BoundingBox?, maxPolygons: Int = 4000) -> [[GeoCoordinate]] {
        guard let s = ShadeSun(sun), maxPolygons > 0, let dataBounds else { return [] }
        let clip: ShadeRect? = bbox.map {
            let a = projection.project(GeoCoordinate(latitude: $0.minLatitude, longitude: $0.minLongitude))
            let b = projection.project(GeoCoordinate(latitude: $0.maxLatitude, longitude: $0.maxLongitude))
            return ShadeRect(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
        }
        let focus = clip?.center ?? dataBounds.center

        // Cheap pass: bounds of every shadow polygon, filtered and ranked before any hull is built.
        var candidates: [OverlayCandidate] = []
        func consider(_ kind: OverlayCandidate.Kind, _ index: Int, _ box: ShadeRect) {
            if let clip, !box.intersects(clip) { return }
            candidates.append(OverlayCandidate(kind: kind, index: index, distance: box.distance(to: focus),
                                               order: candidates.count))
        }
        for (i, c) in canopies.enumerated() {
            consider(.canopy, i, c.box.offset(by: s.shadowDir * s.canopyOffset(height: c.height)))
        }
        for (i, b) in buildings.enumerated() {
            let top = b.box.offset(by: s.buildingShadowVector(height: b.height))
            let bottom = b.minHeight > 0 ? b.box.offset(by: s.buildingShadowVector(height: b.minHeight)) : b.box
            consider(.building, i, top.union(bottom))
            if b.isRoofOnly { consider(.roof, i, b.box) }
        }
        for (i, t) in trees.enumerated() {
            consider(.tree, i, ShadeRect(center: t.center + s.shadowDir * s.treeOffset(height: t.height), radius: t.radius))
        }
        if candidates.count > maxPolygons {
            candidates.sort { $0.distance != $1.distance ? $0.distance < $1.distance : $0.order < $1.order }
            candidates.removeSubrange(maxPolygons...)
            candidates.sort { $0.order < $1.order }
        }

        return candidates.compactMap { c -> [GeoCoordinate]? in
            let ring = polygon(for: c, s)
            return ring.count >= 3 ? projection.unproject(ring) : nil
        }
    }

    // MARK: - Internals

    /// Everything a point query needs for one sun position (computed once per public call).
    private struct QueryContext: Sendable {
        let sun: ShadeSun
        let buildingReach: Double
        let treeReach: Double
        let canopyReach: Double
        let reach: Double

        init(engine: ShadeEngine, sun: ShadeSun) {
            self.sun = sun
            buildingReach = engine.buildings.isEmpty ? -1
                : sun.reach(height: engine.maxBuildingHeight, cap: ShadeModel.maxBuildingShadow)
            treeReach = engine.trees.isEmpty ? -1 : sun.treeOffset(height: engine.maxTreeHeight)
            canopyReach = engine.canopies.isEmpty ? -1 : sun.canopyOffset(height: engine.maxCanopyHeight)
            reach = max(buildingReach, treeReach, canopyReach)
        }
    }

    /// Ray-parameter slack used when matching a caster to the cell that owns it.
    private static let windowSlack = 1e-6

    private func isShaded(_ p: Point2D, _ ctx: QueryContext) -> Bool {
        guard let grid, ctx.reach >= 0, p.x.isFinite, p.y.isFinite else { return false }
        let sun = ctx.sun
        let u = sun.toSun

        // High sun: the unshifted canopy polygon counts too.
        if ctx.canopyReach >= 0, sun.countsUnshiftedCanopy, let cell = grid.cell(containing: p) {
            for k in canopyCells.range(of: cell) {
                let c = canopies[Int(canopyCells.items[k])]
                if c.box.contains(p) && ShadowGeometry.ringContains(canopyRings, c.ring, p) { return true }
            }
        }

        // March towards the sun. Every caster is tested only in the cell whose ray interval holds its own
        // ray parameter (crown/canopy offset, or footprint-box entry), so each is tested at most once or twice.
        guard var ray = ShadeGridRay(grid: grid, origin: p, dir: u, length: ctx.reach) else { return false }
        while let step = ray.next() {
            let lo = step.tEnter - ShadeEngine.windowSlack
            let hi = step.tExit + ShadeEngine.windowSlack
            if lo <= ctx.treeReach {
                for k in treeCells.range(of: step.cell) {
                    let t = trees[Int(treeCells.items[k])]
                    let off = sun.treeOffset(height: t.height)
                    guard off >= lo && off <= hi else { continue }
                    // P is inside the disc centred at trunk + shadowDir·off  ⇔  P + toSun·off is within r of the trunk.
                    let dx = p.x + u.x * off - t.center.x, dy = p.y + u.y * off - t.center.y
                    if dx * dx + dy * dy <= t.radius * t.radius { return true }
                }
            }
            if lo <= ctx.canopyReach {
                for k in canopyCells.range(of: step.cell) {
                    let c = canopies[Int(canopyCells.items[k])]
                    let off = sun.canopyOffset(height: c.height)
                    guard off >= lo && off <= hi else { continue }
                    let q = Point2D(x: p.x + u.x * off, y: p.y + u.y * off)
                    if c.box.contains(q) && ShadowGeometry.ringContains(canopyRings, c.ring, q) { return true }
                }
            }
            if lo <= ctx.buildingReach {
                for k in buildingCells.range(of: step.cell) {
                    if buildingBlocks(Int(buildingCells.items[k]), p, ctx, lo, hi) { return true }
                }
            }
        }
        return false
    }

    /// Whether building `i` blocks the sun ray from `p`, tested only when its footprint-box entry lies in `[lo, hi]`.
    @inline(__always)
    private func buildingBlocks(_ i: Int, _ p: Point2D, _ ctx: QueryContext, _ lo: Double, _ hi: Double) -> Bool {
        let b = buildings[i]
        let u = ctx.sun.toSun
        guard let span = b.box.lineInterval(origin: p, dir: u), span.far >= 0 else { return false }
        let entry = max(span.near, 0)
        guard entry >= lo, entry <= hi, entry <= ctx.buildingReach else { return false }
        let tanE = ctx.sun.tanElevation
        if b.isRoofOnly && entry == 0 && ShadowGeometry.ringContains(buildingRings, b.ring, p) { return true }
        guard entry * tanE <= b.height,          // ray already above the roof where it reaches the box
              span.far * tanE >= b.minHeight     // ray still below the underside where it leaves the box
        else { return false }

        let crossings = ShadowGeometry.rayCrossings(buildingRings, b.ring, origin: p, dir: u)
        let tOut = crossings?.last ?? 0
        guard tOut * tanE >= b.minHeight else { return false }
        if let tIn = crossings?.first, tIn * tanE <= b.height, tIn <= ctx.buildingReach { return true }
        // The first crossing is too high (or there is none): blocked only if p itself is inside (t_in = 0).
        return entry == 0 && ShadowGeometry.ringContains(buildingRings, b.ring, p)
    }

    private func shadeFraction(_ polyline: [GeoCoordinate], _ ctx: QueryContext, spacing: Double) -> Double {
        guard !polyline.isEmpty else { return 0 }
        let line = ShadePolyline(polyline, projection: projection)
        let points = line.points(at: line.sampleDistances(spacing: spacing))
        guard !points.isEmpty else { return 0 }
        var shaded = 0
        for p in points where isShaded(p, ctx) { shaded += 1 }
        return Double(shaded) / Double(points.count)
    }

    private func polygon(for c: OverlayCandidate, _ s: ShadeSun) -> [Point2D] {
        switch c.kind {
        case .building:
            let b = buildings[c.index]
            let ring = buildingRings[b.ring]
            let top = s.buildingShadowVector(height: b.height)
            let bottom = b.minHeight > 0 ? s.buildingShadowVector(height: b.minHeight) : .zero
            return Geometry2D.convexHull(ring.map { $0 + bottom } + ring.map { $0 + top })
        case .roof:
            return Array(buildingRings[buildings[c.index].ring])
        case .tree:
            let t = trees[c.index]
            return Geometry2D.circle(center: t.center + s.shadowDir * s.treeOffset(height: t.height),
                                     radius: t.radius, segments: 12)
        case .canopy:
            let canopy = canopies[c.index]
            let v = s.shadowDir * s.canopyOffset(height: canopy.height)
            return canopyRings[canopy.ring].map { $0 + v }
        }
    }

    // MARK: - Setup helpers

    /// `origin` if valid, else the centre of the bounding box of all valid input coordinates.
    private static func resolveOrigin(_ origin: GeoCoordinate?, _ buildings: [Building], _ trees: [Tree],
                                      _ canopies: [CanopyArea]) -> GeoCoordinate {
        if let origin, origin.isValid { return origin }
        var box: BoundingBox?
        func add(_ c: GeoCoordinate) {
            guard c.isValid else { return }
            if let b = box {
                if c.latitude < b.minLatitude { box?.minLatitude = c.latitude }
                if c.latitude > b.maxLatitude { box?.maxLatitude = c.latitude }
                if c.longitude < b.minLongitude { box?.minLongitude = c.longitude }
                if c.longitude > b.maxLongitude { box?.maxLongitude = c.longitude }
            } else {
                box = BoundingBox(minLatitude: c.latitude, minLongitude: c.longitude,
                                  maxLatitude: c.latitude, maxLongitude: c.longitude)
            }
        }
        for b in buildings { b.footprint.forEach(add) }
        for t in trees { add(t.coordinate) }
        for c in canopies { c.ring.forEach(add) }
        return box?.center ?? GeoCoordinate(latitude: 0, longitude: 0)
    }

    /// Projected open ring with ≥ 3 finite vertices, or nil.
    private static func projectRing(_ ring: [GeoCoordinate], _ projection: LocalProjection) -> [Point2D]? {
        let pts = Geometry2D.openRing(projection.project(ring))
        guard pts.count >= 3, pts.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return pts
    }
}

// MARK: - Indexed records

private struct IndexedBuilding: Sendable {
    var box: ShadeRect
    var ring: Range<Int>
    var height: Double
    /// Effective underside height (roof-only default applied).
    var minHeight: Double
    var isRoofOnly: Bool
}

private struct IndexedTree: Sendable {
    var center: Point2D
    var height: Double
    var radius: Double
}

private struct IndexedCanopy: Sendable {
    var box: ShadeRect
    var ring: Range<Int>
    var height: Double
}

private struct OverlayCandidate: Sendable {
    enum Kind: Sendable { case building, roof, tree, canopy }
    var kind: Kind
    var index: Int
    /// Distance from the focus point to the polygon's bounds.
    var distance: Double
    /// Enumeration order (canopies, buildings, trees), used for stable output.
    var order: Int
}
