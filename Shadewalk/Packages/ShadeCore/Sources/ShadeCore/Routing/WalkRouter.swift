import Foundation

/// Shade-aware A* router over a `WalkGraph`. See SPEC §4.5.
public final class WalkRouter: @unchecked Sendable {
    /// - Parameters:
    ///   - edgeShade: shade fraction per edge id (`count == graph.edges.count`).
    ///   - shadeEngine: used to split the final geometry into shaded/sunny runs; if nil, each edge is coloured by
    ///     its majority shade.
    ///   - coolSpots: used to fill `WalkRoute.coolSpotIDs` (within 40 m of the route).
    public init(graph: WalkGraph, edgeShade: [Double], shadeEngine: ShadeEngine?, coolSpots: [CoolSpot] = []) {
        fatalError("STUB: routing module")
    }

    /// Single route for `profile` (`.shadiest` uses the detour-capped search).
    public func route(from origin: GeoCoordinate, to destination: GeoCoordinate, profile: RouteProfile,
                      preferences: RoutingPreferences, sun: SunPosition, departure: Date) throws -> WalkRoute {
        fatalError("STUB: routing module")
    }

    /// Deduplicated alternatives ordered shadiest → balanced → fastest.
    public func alternatives(from origin: GeoCoordinate, to destination: GeoCoordinate,
                             preferences: RoutingPreferences, sun: SunPosition, departure: Date) throws -> [WalkRoute] {
        fatalError("STUB: routing module")
    }
}
