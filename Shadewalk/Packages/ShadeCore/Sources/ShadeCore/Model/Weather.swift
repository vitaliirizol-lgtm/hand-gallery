import Foundation

public struct WeatherSnapshot: Hashable, Codable, Sendable {
    public var time: Date
    /// °C
    public var temperature: Double
    /// °C
    public var apparentTemperature: Double?
    public var uvIndex: Double?
    /// Percent, 0–100.
    public var cloudCover: Double?
    public var isDay: Bool

    public init(time: Date, temperature: Double, apparentTemperature: Double?, uvIndex: Double?, cloudCover: Double?, isDay: Bool) {
        self.time = time
        self.temperature = temperature
        self.apparentTemperature = apparentTemperature
        self.uvIndex = uvIndex
        self.cloudCover = cloudCover
        self.isDay = isDay
    }
}

public struct WeatherForecast: Hashable, Codable, Sendable {
    public var current: WeatherSnapshot
    /// Hourly snapshots, ascending by time.
    public var hourly: [WeatherSnapshot]

    public init(current: WeatherSnapshot, hourly: [WeatherSnapshot]) {
        self.current = current
        self.hourly = hourly
    }

    /// Hourly snapshot nearest to `date` (within 90 min), else `current` if `date` is within 90 min of it.
    public func snapshot(at date: Date) -> WeatherSnapshot? {
        let candidates = hourly + [current]
        guard let best = candidates.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }) else {
            return nil
        }
        return abs(best.time.timeIntervalSince(date)) <= 90 * 60 ? best : nil
    }
}
