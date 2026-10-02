import Foundation
import Observation
import ShadeCore

/// Weather for the map's weather pill (temperature, feels-like, UV).
///
/// Loads are throttled: a successful forecast is reused for coordinates within `nearbyDistance` (1 km) for
/// `refreshInterval` (10 min) unless `force` is set.
@MainActor @Observable
public final class WeatherModel {
    /// State of the latest load.
    public private(set) var state: LoadState<WeatherForecast> = .idle
    /// Last successful forecast; kept through reloads and failures for the same area, cleared when loading for a
    /// coordinate further than `nearbyDistance` away.
    public private(set) var forecast: WeatherForecast?
    /// Coordinate `forecast` was loaded for.
    public private(set) var forecastCoordinate: GeoCoordinate?
    /// When `forecast` was loaded (by the injected clock).
    public private(set) var lastUpdated: Date?

    @ObservationIgnored private let provider: WeatherProviding
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let refreshInterval: TimeInterval
    @ObservationIgnored private let nearbyDistance: Double
    @ObservationIgnored var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var pendingCoordinate: GeoCoordinate?
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - refreshInterval: minimum age before a forecast for a nearby coordinate is reloaded, seconds.
    ///   - nearbyDistance: coordinates closer than this share a forecast, metres.
    public init(provider: WeatherProviding, now: @escaping () -> Date = { Date() }, refreshInterval: TimeInterval = 600,
                nearbyDistance: Double = 1_000) {
        self.provider = provider
        self.now = now
        self.refreshInterval = refreshInterval
        self.nearbyDistance = nearbyDistance
    }

    /// Snapshot for the current time (falls back to the forecast's `current`).
    public var current: WeatherSnapshot? {
        guard let forecast else { return nil }
        return forecast.snapshot(at: now()) ?? forecast.current
    }

    /// Hourly snapshot nearest to `date` (within 90 min).
    public func snapshot(at date: Date) -> WeatherSnapshot? {
        forecast?.snapshot(at: date)
    }

    /// Loads the forecast for `coordinate` unless a fresh one for a nearby coordinate exists (or is loading).
    /// Returns when done or superseded.
    public func load(at coordinate: GeoCoordinate, force: Bool = false) async {
        if !force {
            if let loadedAt = forecastCoordinate, let updated = lastUpdated, forecast != nil,
               isNearby(loadedAt, coordinate), now().timeIntervalSince(updated) < refreshInterval {
                return
            }
            if let task = pendingTask, let loading = pendingCoordinate, isNearby(loading, coordinate) {
                await task.value
                return
            }
        }
        pendingTask?.cancel()
        generation += 1
        let token = generation
        if let loadedAt = forecastCoordinate, !isNearby(loadedAt, coordinate) {
            forecast = nil
            forecastCoordinate = nil
            lastUpdated = nil
        }
        state = .loading
        pendingCoordinate = coordinate
        let provider = self.provider
        let task = Task { [weak self] in
            do {
                let result = try await provider.forecast(at: coordinate)
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.forecast = result
                self.forecastCoordinate = coordinate
                self.lastUpdated = self.now()
                self.state = .loaded(result)
                self.finish(token)
            } catch {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.state = .failure(error)
                self.finish(token)
            }
        }
        pendingTask = task
        await task.value
    }

    private func finish(_ token: Int) {
        guard token == generation else { return }
        pendingTask = nil
        pendingCoordinate = nil
    }

    private func isNearby(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Bool {
        GeoMath.distance(a, b) < nearbyDistance
    }
}
