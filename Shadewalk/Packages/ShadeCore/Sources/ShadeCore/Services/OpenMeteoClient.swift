import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Open-Meteo forecast + elevation client. See SPEC §2.
public struct OpenMeteoClient: WeatherProviding, ElevationProviding {
    public init(http: HTTPClient, forecastURL: URL = URL(string: "https://api.open-meteo.com/v1/forecast")!,
                elevationURL: URL = URL(string: "https://api.open-meteo.com/v1/elevation")!) {
        fatalError("STUB: services module")
    }

    public func forecast(at coordinate: GeoCoordinate) async throws -> WeatherForecast {
        fatalError("STUB: services module")
    }

    /// Batches requests to ≤ 100 coordinates each; preserves order.
    public func elevations(for coordinates: [GeoCoordinate]) async throws -> [Double] {
        fatalError("STUB: services module")
    }
}
