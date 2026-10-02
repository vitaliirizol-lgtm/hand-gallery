import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Open-Meteo forecast + elevation client. See SPEC §2.
///
/// Errors: transport failures → `ShadeError.networkUnavailable`; non-2xx → `ShadeError.badResponse(status:)`;
/// unreadable bodies or `{"error":true,"reason":…}` → `ShadeError.decodingFailed`; cancellation → `.cancelled`.
public struct OpenMeteoClient: WeatherProviding, ElevationProviding {
    /// Open-Meteo accepts at most this many coordinates per elevation request.
    public static let maxElevationBatchSize = 100
    /// Elevation batches requested at the same time.
    public static let maxConcurrentElevationRequests = 4
    /// Fields requested for both `current` and `hourly`.
    public static let weatherFields = "temperature_2m,apparent_temperature,uv_index,cloud_cover,is_day"

    private let http: HTTPClient
    private let forecastURL: URL
    private let elevationURL: URL

    public init(http: HTTPClient, forecastURL: URL = URL(string: "https://api.open-meteo.com/v1/forecast")!,
                elevationURL: URL = URL(string: "https://api.open-meteo.com/v1/elevation")!) {
        self.http = http
        self.forecastURL = forecastURL
        self.elevationURL = elevationURL
    }

    /// Current conditions plus 2 days of hourly snapshots (times in UTC).
    public func forecast(at coordinate: GeoCoordinate) async throws -> WeatherForecast {
        let request = try Self.makeRequest(base: forecastURL, queryItems: [
            URLQueryItem(name: "latitude", value: Self.format(coordinate.latitude)),
            URLQueryItem(name: "longitude", value: Self.format(coordinate.longitude)),
            URLQueryItem(name: "current", value: Self.weatherFields),
            URLQueryItem(name: "hourly", value: Self.weatherFields),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "GMT"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
        ])
        let data = try await perform(request)
        return try Self.decodeForecast(data)
    }

    /// Batches requests to ≤ 100 coordinates each; preserves order.
    public func elevations(for coordinates: [GeoCoordinate]) async throws -> [Double] {
        guard !coordinates.isEmpty else { return [] }
        let size = Self.maxElevationBatchSize
        let batches = stride(from: 0, to: coordinates.count, by: size).map {
            Array(coordinates[$0..<min($0 + size, coordinates.count)])
        }
        if batches.count == 1 { return try await elevationBatch(batches[0]) }

        var results = [[Double]?](repeating: nil, count: batches.count)
        try await withThrowingTaskGroup(of: (index: Int, values: [Double]).self) { group in
            var next = 0
            while next < min(Self.maxConcurrentElevationRequests, batches.count) {
                let index = next, batch = batches[index]
                group.addTask { (index, try await self.elevationBatch(batch)) }
                next += 1
            }
            while let finished = try await group.next() {
                results[finished.index] = finished.values
                if next < batches.count {
                    let index = next, batch = batches[index]
                    group.addTask { (index, try await self.elevationBatch(batch)) }
                    next += 1
                }
            }
        }
        var out: [Double] = []
        out.reserveCapacity(coordinates.count)
        for values in results {
            guard let values else { throw ShadeError.decodingFailed("missing elevation batch") }
            out += values
        }
        return out
    }

    // MARK: - Private

    private func elevationBatch(_ batch: [GeoCoordinate]) async throws -> [Double] {
        let request = try Self.makeRequest(base: elevationURL, queryItems: [
            URLQueryItem(name: "latitude", value: batch.map { Self.format($0.latitude) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: batch.map { Self.format($0.longitude) }.joined(separator: ",")),
        ])
        let data = try await perform(request)
        let payload: ElevationPayload
        do {
            payload = try JSONDecoder().decode(ElevationPayload.self, from: data)
        } catch {
            throw ShadeError.decodingFailed("elevation: \(error)")
        }
        guard let raw = payload.elevation else { throw ShadeError.decodingFailed("elevation: missing values") }
        guard raw.count == batch.count else {
            throw ShadeError.decodingFailed("elevation: expected \(batch.count) values, got \(raw.count)")
        }
        var values: [Double] = []
        values.reserveCapacity(raw.count)
        for value in raw {
            guard let value, value.isFinite else { throw ShadeError.decodingFailed("elevation: null value") }
            values.append(value)
        }
        return values
    }

    /// Sends `request`; returns the body of a 2xx response that isn't an Open-Meteo error object.
    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.data(for: request)
        } catch let error as ShadeError {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError { throw ShadeError.cancelled }
            throw ShadeError.networkUnavailable
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ShadeError.badResponse(status: response.statusCode)
        }
        if let apiError = try? JSONDecoder().decode(APIErrorPayload.self, from: data), apiError.error == true {
            throw ShadeError.decodingFailed("Open-Meteo: \(apiError.reason ?? "unknown error")")
        }
        return data
    }

    private static func makeRequest(base: URL, queryItems: [URLQueryItem]) throws -> URLRequest {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ShadeError.networkUnavailable
        }
        components.queryItems = (components.queryItems ?? []) + queryItems
        guard let url = components.url else { throw ShadeError.networkUnavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(OverpassClient.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Fixed 6-decimal formatting (≈ 0.1 m), locale-independent.
    static func format(_ degrees: Double) -> String {
        String(format: "%.6f", degrees)
    }

    static func decodeForecast(_ data: Data) throws -> WeatherForecast {
        let payload: ForecastPayload
        do {
            payload = try JSONDecoder().decode(ForecastPayload.self, from: data)
        } catch {
            throw ShadeError.decodingFailed("forecast: \(error)")
        }
        guard let current = payload.current, let time = current.time, let temperature = current.temperature else {
            throw ShadeError.decodingFailed("forecast: missing current conditions")
        }
        let currentSnapshot = WeatherSnapshot(
            time: Date(timeIntervalSince1970: time), temperature: temperature,
            apparentTemperature: current.apparentTemperature, uvIndex: current.uvIndex,
            cloudCover: current.cloudCover, isDay: isDay(current.isDay, uvIndex: current.uvIndex))

        var hourly: [WeatherSnapshot] = []
        if let h = payload.hourly, let times = h.time {
            hourly.reserveCapacity(times.count)
            for (i, time) in times.enumerated() {
                // Hours past the model horizon come back as nulls.
                guard let time, let temperature = value(h.temperature, i) else { continue }
                let uv = value(h.uvIndex, i)
                hourly.append(WeatherSnapshot(
                    time: Date(timeIntervalSince1970: time), temperature: temperature,
                    apparentTemperature: value(h.apparentTemperature, i), uvIndex: uv,
                    cloudCover: value(h.cloudCover, i), isDay: isDay(value(h.isDay, i), uvIndex: uv)))
            }
            hourly.sort { $0.time < $1.time }
        }
        return WeatherForecast(current: currentSnapshot, hourly: hourly)
    }

    private static func value(_ array: [Double?]?, _ index: Int) -> Double? {
        guard let array, array.indices.contains(index) else { return nil }
        return array[index]
    }

    /// `is_day` is 1/0; if it's missing, fall back to "UV above zero".
    private static func isDay(_ flag: Double?, uvIndex: Double?) -> Bool {
        if let flag { return flag != 0 }
        return (uvIndex ?? 0) > 0
    }

    private struct APIErrorPayload: Decodable {
        var error: Bool?
        var reason: String?
    }

    private struct ElevationPayload: Decodable {
        var elevation: [Double?]?
    }

    private struct ForecastPayload: Decodable {
        struct Current: Decodable {
            var time: Double?
            var temperature: Double?
            var apparentTemperature: Double?
            var uvIndex: Double?
            var cloudCover: Double?
            var isDay: Double?

            enum CodingKeys: String, CodingKey {
                case time
                case temperature = "temperature_2m"
                case apparentTemperature = "apparent_temperature"
                case uvIndex = "uv_index"
                case cloudCover = "cloud_cover"
                case isDay = "is_day"
            }
        }

        struct Hourly: Decodable {
            var time: [Double?]?
            var temperature: [Double?]?
            var apparentTemperature: [Double?]?
            var uvIndex: [Double?]?
            var cloudCover: [Double?]?
            var isDay: [Double?]?

            enum CodingKeys: String, CodingKey {
                case time
                case temperature = "temperature_2m"
                case apparentTemperature = "apparent_temperature"
                case uvIndex = "uv_index"
                case cloudCover = "cloud_cover"
                case isDay = "is_day"
            }
        }

        var current: Current?
        var hourly: Hourly?
    }
}
