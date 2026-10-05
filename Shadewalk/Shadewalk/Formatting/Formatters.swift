import Foundation
import ShadeFeatures

/// Locale-aware display strings for route metrics.
///
/// Every function takes an explicit `locale` (default `.current`) so output is deterministic in tests. Sentences that
/// need translation go through `String(localized:)` with whole-sentence keys; numbers are interpolated as `Int` so the
/// String Catalog gets `%lld` keys (with locale digit grouping, e.g. "1,898 steps").
enum Formatters {
    // MARK: - Distance

    /// "850 m", "1.4 km", "12 km" (metric) or "350 ft", "0.9 mi" (imperial).
    ///
    /// Metres are rounded to 5 m below 100 m and to 10 m below 1 km; kilometres and miles keep one decimal below 10.
    /// Imperial distances under 0.1 mi are shown in feet (rounded to 10 ft).
    static func distance(_ meters: Double, units: UnitPreference = .system, locale: Locale = .current) -> String {
        let value = meters.isFinite ? min(max(meters, 0), 100_000_000) : 0
        if usesMetricDistances(units, locale: locale) {
            if value < 1_000 {
                let step: Double = value < 100 ? 5 : 10
                let rounded = (value / step).rounded() * step
                if rounded < 1_000 {
                    return measurement(rounded, unit: UnitLength.meters, fractionDigits: 0, locale: locale)
                }
            }
            let kilometers = value / 1_000
            return measurement(kilometers, unit: UnitLength.kilometers, fractionDigits: kilometers < 9.95 ? 1 : 0,
                               locale: locale)
        }
        let miles = value / metersPerMile
        if miles < 0.1 {
            let feet = ((value / metersPerFoot) / 10).rounded() * 10
            return measurement(feet, unit: UnitLength.feet, fractionDigits: 0, locale: locale)
        }
        return measurement(miles, unit: UnitLength.miles, fractionDigits: miles < 9.95 ? 1 : 0, locale: locale)
    }

    /// Height difference, e.g. "12 m" or "40 ft" (never converted to km / mi).
    static func elevation(_ meters: Double, units: UnitPreference = .system, locale: Locale = .current) -> String {
        let value = meters.isFinite ? min(max(meters, -100_000), 100_000) : 0
        if usesMetricDistances(units, locale: locale) {
            return measurement(cleanZero(value.rounded()), unit: UnitLength.meters, fractionDigits: 0, locale: locale)
        }
        return measurement(cleanZero((value / metersPerFoot).rounded()), unit: UnitLength.feet, fractionDigits: 0,
                           locale: locale)
    }

    /// True when distances should be shown in metres / kilometres.
    static func usesMetricDistances(_ units: UnitPreference, locale: Locale = .current) -> Bool {
        switch units {
        case .metric: return true
        case .imperial: return false
        case .system: return locale.measurementSystem == .metric
        }
    }

    // MARK: - Time

    /// Walking duration: "18 min", "1 h 05 min". Rounded to the nearest minute; any positive duration is at least
    /// "1 min".
    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        let clamped = seconds.isFinite ? min(max(seconds, 0), 359_999 * 60) : 0
        let totalMinutes = clamped > 0 ? max(1, Int((clamped / 60).rounded())) : 0
        if totalMinutes < 60 {
            return String(localized: "\(totalMinutes) min", locale: locale,
                          comment: "Duration shorter than an hour, e.g. “18 min”.")
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let paddedMinutes = minutes.formatted(IntegerFormatStyle<Int>(locale: locale).precision(.integerLength(2)))
        return String(localized: "\(hours) h \(paddedMinutes) min", locale: locale,
                      comment: "Duration of an hour or more, e.g. “1 h 05 min”. The minutes are zero-padded.")
    }

    /// Short clock time in the locale's style, e.g. "3:42 PM" or "15:42".
    static func clockTime(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        var calendar = locale.calendar
        calendar.timeZone = timeZone
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                     timeZone: timeZone)
        return date.formatted(style)
    }

    // MARK: - Counts & ratios

    /// Step counter with locale grouping, e.g. "1,898 steps".
    static func steps(_ count: Int, locale: Locale = .current) -> String {
        String(localized: "\(max(0, count)) steps", locale: locale,
               comment: "Number of walking steps, e.g. “1,898 steps”.")
    }

    /// Fraction `[0, 1]` as a whole percentage, e.g. 0.62 → "62%" (clamped to 0–100 %).
    static func percent(_ fraction: Double, locale: Locale = .current) -> String {
        clampedFraction(fraction).formatted(FloatingPointFormatStyle<Double>.Percent(locale: locale)
            .precision(.fractionLength(0)))
    }

    /// Fraction `[0, 1]` as a whole number of percent (0–100), for sentences like "62 percent shade".
    static func percentValue(_ fraction: Double) -> Int {
        Int((clampedFraction(fraction) * 100).rounded())
    }

    // MARK: - Weather

    /// Temperature from degrees Celsius, in °C or °F per `units` (system: °F only for US-style locales), e.g. "31°C".
    /// With `showsUnit == false` only the degree sign is kept, e.g. "31°".
    static func temperature(_ celsius: Double, units: UnitPreference = .system, locale: Locale = .current,
                            showsUnit: Bool = true) -> String {
        let source = Measurement(value: celsius.isFinite ? celsius : 0, unit: UnitTemperature.celsius)
        let target = usesFahrenheit(units, locale: locale) ? source.converted(to: UnitTemperature.fahrenheit) : source
        let options: MeasurementFormatter.UnitOptions = showsUnit ? [.providedUnit]
            : [.providedUnit, .temperatureWithoutUnit]
        return measurement(cleanZero(target.value.rounded()), unit: target.unit, fractionDigits: 0, locale: locale,
                           options: options)
    }

    /// True when temperatures should be shown in °F.
    static func usesFahrenheit(_ units: UnitPreference, locale: Locale = .current) -> Bool {
        switch units {
        case .metric: return false
        case .imperial: return true
        case .system: return locale.measurementSystem == .us
        }
    }

    /// UV index rounded to a whole number (never negative).
    static func uvIndex(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return max(0, Int(min(value, 99).rounded()))
    }

    // MARK: - Private

    private static let metersPerMile = 1_609.344
    private static let metersPerFoot = 0.3048

    private static func clampedFraction(_ fraction: Double) -> Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }

    /// Avoids "-0".
    private static func cleanZero(_ value: Double) -> Double {
        value == 0 ? 0 : value
    }

    private static func measurement<U: Unit>(_ value: Double, unit: U, fractionDigits: Int, locale: Locale,
                                             options: MeasurementFormatter.UnitOptions = [.providedUnit]) -> String {
        let numbers = NumberFormatter()
        numbers.locale = locale
        numbers.numberStyle = .decimal
        numbers.minimumFractionDigits = 0
        numbers.maximumFractionDigits = max(0, fractionDigits)
        let formatter = MeasurementFormatter()
        formatter.locale = locale
        formatter.unitOptions = options
        formatter.unitStyle = .medium
        formatter.numberFormatter = numbers
        return formatter.string(from: Measurement(value: value, unit: unit))
    }
}
