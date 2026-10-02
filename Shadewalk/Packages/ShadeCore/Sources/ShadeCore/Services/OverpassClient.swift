import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Overpass API client with mirror fallback, retry/backoff and disk cache. See SPEC §2.
public actor OverpassClient: AreaDataProviding, CoolSpotProviding {
    public static let defaultEndpoints: [URL] = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.kumi.systems/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
    ]

    /// - Parameters:
    ///   - cacheDirectory: on-disk cache root; nil disables disk caching.
    ///   - cacheTTL: seconds a cached response stays valid (default 7 days).
    ///   - now: clock, injectable for tests.
    public init(http: HTTPClient, endpoints: [URL] = OverpassClient.defaultEndpoints, cacheDirectory: URL? = nil,
                cacheTTL: TimeInterval = 7 * 24 * 3600, maxAttemptsPerEndpoint: Int = 2,
                now: @escaping @Sendable () -> Date = { Date() }) {
        fatalError("STUB: services module")
    }

    /// Raw Overpass JSON for `query` (cached by query text).
    public func fetch(query: String) async throws -> Data {
        fatalError("STUB: services module")
    }

    public func areaData(for bbox: BoundingBox) async throws -> AreaData {
        fatalError("STUB: services module")
    }

    public func coolSpots(near coordinate: GeoCoordinate, radius: Double) async throws -> [CoolSpot] {
        fatalError("STUB: services module")
    }
}
