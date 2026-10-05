import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Data services (implemented in ShadeCore)

/// Minimal HTTP abstraction so clients can be tested with canned responses.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Fetches OSM-derived `AreaData` for a bounding box.
public protocol AreaDataProviding: Sendable {
    func areaData(for bbox: BoundingBox) async throws -> AreaData
}

public protocol WeatherProviding: Sendable {
    func forecast(at coordinate: GeoCoordinate) async throws -> WeatherForecast
}

public protocol ElevationProviding: Sendable {
    /// Elevations in metres, same order and count as `coordinates`.
    func elevations(for coordinates: [GeoCoordinate]) async throws -> [Double]
}

/// Plans shade-aware walking routes.
public protocol RoutePlanning: Sendable {
    func plan(_ request: RouteRequest) async throws -> RoutePlan
}

/// Shadow polygons for the map overlay.
public protocol ShadeOverlayProviding: Sendable {
    func shadeOverlay(in bbox: BoundingBox, at date: Date) async throws -> ShadeOverlay
}

public protocol CoolSpotProviding: Sendable {
    func coolSpots(near coordinate: GeoCoordinate, radius: Double) async throws -> [CoolSpot]
}

// MARK: - Platform services (implemented in the iOS app with CoreLocation / MapKit; faked in tests)

@MainActor
public protocol LocationProviding: AnyObject {
    var authorization: LocationAuthorization { get }
    var lastFix: LocationFix? { get }
    func requestAuthorization()
    /// Stream of location fixes; ends when the consumer cancels. Several streams may be open at once
    /// (e.g. the location and navigation models); every fix is delivered to each open stream.
    func fixes() -> AsyncStream<LocationFix>
}

@MainActor
public protocol PlaceSearching: AnyObject {
    func suggestions(for query: String, near: GeoCoordinate?) async throws -> [PlaceSuggestion]
    func resolve(_ suggestion: PlaceSuggestion) async throws -> Place
    func reverseGeocode(_ coordinate: GeoCoordinate) async -> Place?
}

public protocol DrivingPathProviding: Sendable {
    func drivingPath(from: GeoCoordinate, to: GeoCoordinate) async throws -> DrivingPath
}

/// Small persistent key-value store (UserDefaults in the app, in-memory in tests).
public protocol KeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// Thread-safe in-memory `KeyValueStore`.
public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }
}
