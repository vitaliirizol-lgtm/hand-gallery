import Foundation
import Observation
import ShadeCore

/// When the walk starts.
public enum DepartureOption: Hashable, Sendable {
    case now
    case at(Date)

    /// Concrete departure date, resolving `.now` with `now`.
    public func date(now: Date) -> Date {
        switch self {
        case .now: return now
        case let .at(date): return date
        }
    }

    /// True for `.now`.
    public var isNow: Bool {
        if case .now = self { return true }
        return false
    }
}

/// Sunrise / sunset lookup: `(day, coordinate, timeZone) -> SunTimes`.
public typealias SunTimesLookup = (Date, GeoCoordinate, TimeZone) -> SunTimes

/// Departure-time slider for "today": the range runs from sunrise to sunset (rounded inwards to 15-minute steps).
///
/// Slider values are minutes since local midnight (wall-clock). When the sun times are unknown (no coordinate) or
/// the day is a polar day/night, the range falls back to 06:00–21:00.
@MainActor @Observable
public final class DepartureTimeModel {
    /// Fallback slider range, minutes since midnight (06:00–21:00).
    public static let fallbackRange: ClosedRange<Double> = 360...1260

    /// Selected departure.
    public private(set) var departure: DepartureOption = .now
    /// Slider range, minutes since local midnight, multiples of `step`.
    public private(set) var range: ClosedRange<Double> = 360...1260
    /// Sun times used for `range`; nil when the fallback range is in use.
    public private(set) var sunTimes: SunTimes?
    /// Start of the day the slider covers, in `timeZone`.
    public private(set) var day: Date

    /// Location the sun times are computed for. Setting it recomputes the range.
    public var coordinate: GeoCoordinate? {
        didSet { if coordinate != oldValue { refresh() } }
    }

    /// Time zone of the slider's wall clock. Setting it recomputes the range.
    public var timeZone: TimeZone {
        didSet { if timeZone != oldValue { refresh() } }
    }

    /// Slider step, minutes.
    public let step: Double

    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sunTimesLookup: SunTimesLookup

    /// - Parameters:
    ///   - sunTimes: sunrise/sunset lookup; defaults to `SolarCalculator.sunTimes`.
    ///   - step: slider step in minutes (default 15).
    public init(coordinate: GeoCoordinate? = nil, timeZone: TimeZone = .current, step: Double = 15,
                now: @escaping () -> Date = { Date() },
                sunTimes: @escaping SunTimesLookup = SolarCalculator.sunTimes) {
        self.coordinate = coordinate
        self.timeZone = timeZone
        self.step = step > 0 && step.isFinite ? step : 15
        self.now = now
        self.sunTimesLookup = sunTimes
        day = now()
        refresh()
    }

    /// True when the fallback range (06:00–21:00) is in use.
    public var usesFallbackRange: Bool { sunTimes == nil }

    /// Departure date with `.now` resolved against the clock.
    public var resolvedDate: Date { departure.date(now: now()) }

    /// Slider position. Reading `.now` gives the current time (clamped to `range`); writing snaps to `step`, clamps to
    /// `range` and selects that time today.
    public var sliderValue: Double {
        get {
            switch departure {
            case .now: return clamp(value(for: now()))
            case let .at(date): return clamp(value(for: date))
            }
        }
        set {
            guard newValue.isFinite else { return }
            departure = .at(date(forValue: snap(newValue)))
        }
    }

    /// Slider position of the current time (clamped to `range`, not snapped).
    public var nowValue: Double { clamp(value(for: now())) }

    /// Whole hours inside `range` (minutes since midnight), e.g. for haptic ticks.
    public var hourMarks: [Double] {
        let first = (range.lowerBound / 60).rounded(.up) * 60
        guard first <= range.upperBound else { return [] }
        return Array(stride(from: first, through: range.upperBound, by: 60))
    }

    /// Selects "Now".
    public func selectNow() {
        departure = .now
    }

    /// Selects `date` (snapped to `step` and clamped to today's range).
    public func select(_ date: Date) {
        sliderValue = value(for: date)
    }

    /// Recomputes `day`, `sunTimes` and `range` (call when the app becomes active or the day may have changed).
    /// A selected time from another day reverts to `.now`; a selected time outside the new range is clamped.
    public func refresh() {
        let calendar = self.calendar
        let currentNow = now()
        day = calendar.startOfDay(for: currentNow)
        computeRange(at: currentNow)
        if case let .at(date) = departure {
            if !calendar.isDate(date, inSameDayAs: currentNow) {
                departure = .now
            } else {
                let v = value(for: date)
                if !range.contains(v) { departure = .at(self.date(forValue: snap(v))) }
            }
        }
    }

    /// Wall-clock minutes since the start of `day` for `date` (0 before the day, 1440 after it).
    public func value(for date: Date) -> Double {
        let calendar = self.calendar
        if date < day { return 0 }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        if date >= nextDay { return 1440 }
        let c = calendar.dateComponents([.hour, .minute, .second], from: date)
        return Double((c.hour ?? 0) * 60 + (c.minute ?? 0)) + Double(c.second ?? 0) / 60
    }

    /// Date on `day` at the wall-clock time `value` (minutes since midnight, clamped to `0..<1440`).
    public func date(forValue value: Double) -> Date {
        let minutes = Int(min(max(value.isFinite ? value : 0, 0), 1439).rounded())
        let calendar = self.calendar
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
            ?? day.addingTimeInterval(Double(minutes) * 60)
    }

    // MARK: - Private

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func snap(_ value: Double) -> Double {
        clamp((value / step).rounded() * step)
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func computeRange(at date: Date) {
        guard let coordinate else {
            sunTimes = nil
            range = DepartureTimeModel.fallbackRange
            return
        }
        let times = sunTimesLookup(date, coordinate, timeZone)
        guard !times.isPolarDay, !times.isPolarNight, let sunrise = times.sunrise, let sunset = times.sunset,
              sunset > sunrise else {
            sunTimes = nil
            range = DepartureTimeModel.fallbackRange
            return
        }
        let lower = (value(for: sunrise) / step).rounded(.up) * step
        let upper = min((value(for: sunset) / step).rounded(.down) * step, 1440 - step)
        guard upper > lower else {
            sunTimes = nil
            range = DepartureTimeModel.fallbackRange
            return
        }
        sunTimes = times
        range = lower...upper
    }
}
