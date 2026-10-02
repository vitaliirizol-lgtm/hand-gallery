import Foundation

/// Orchestrates area fetch → shade → routing → elevation; caches area data so departure-time changes only
/// recompute shade and routes. See SPEC §4.
public actor RoutePlanner: RoutePlanning, ShadeOverlayProviding, CoolSpotProviding {
    /// Straight-line limit for walking routes, metres.
    public static let maxStraightLineDistance: Double = 5_000

    public init(areaProvider: AreaDataProviding, elevationProvider: ElevationProviding?, weatherProvider: WeatherProviding?) {
        fatalError("STUB: integration")
    }

    public func plan(_ request: RouteRequest) async throws -> RoutePlan {
        fatalError("STUB: integration")
    }

    public func shadeOverlay(in bbox: BoundingBox, at date: Date) async throws -> ShadeOverlay {
        fatalError("STUB: integration")
    }

    public func coolSpots(near coordinate: GeoCoordinate, radius: Double) async throws -> [CoolSpot] {
        fatalError("STUB: integration")
    }
}
