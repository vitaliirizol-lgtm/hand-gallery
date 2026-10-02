import Foundation

/// Answers "is this point in shade?" for a sun position, given buildings, trees and canopy areas. See SPEC §4.3.
/// Immutable after init; safe to share across threads.
public final class ShadeEngine: @unchecked Sendable {
    public let projection: LocalProjection

    /// - Parameter origin: projection origin; defaults to the centre of all inputs.
    public init(buildings: [Building], trees: [Tree], canopies: [CanopyArea], origin: GeoCoordinate? = nil) {
        fatalError("STUB: shade module")
    }

    public convenience init(area: AreaData) {
        self.init(buildings: area.buildings, trees: area.trees, canopies: area.canopies, origin: area.bbox.center)
    }

    /// True if `coordinate` is shaded (or the sun is down).
    public func isShaded(_ coordinate: GeoCoordinate, sun: SunPosition) -> Bool {
        fatalError("STUB: shade module")
    }

    /// Fraction `[0, 1]` of samples (every `spacing` m, ≥ 2 samples) along `polyline` that are shaded.
    public func shadeFraction(along polyline: [GeoCoordinate], sun: SunPosition, spacing: Double = 5) -> Double {
        fatalError("STUB: shade module")
    }

    /// Splits `polyline` into consecutive shaded / sunny runs (adjacent runs share their boundary coordinate).
    /// Runs shorter than `minRunLength` are merged into their neighbours. Lengths sum to the polyline length.
    public func shadeRuns(along polyline: [GeoCoordinate], sun: SunPosition, spacing: Double = 5,
                          minRunLength: Double = 8) -> [RouteSegment] {
        fatalError("STUB: shade module")
    }

    /// Shade fraction per edge id (`result.count == graph.edges.count`). Covered edges → 1.
    public func edgeShadeFractions(for graph: WalkGraph, sun: SunPosition) -> [Double] {
        fatalError("STUB: shade module")
    }

    /// Shadow polygons (open rings) intersecting `bbox` (all if nil), at most `maxPolygons`.
    public func shadowPolygons(sun: SunPosition, within bbox: BoundingBox?, maxPolygons: Int = 4000) -> [[GeoCoordinate]] {
        fatalError("STUB: shade module")
    }
}
