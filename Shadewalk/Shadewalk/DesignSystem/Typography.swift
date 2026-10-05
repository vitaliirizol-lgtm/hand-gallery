import SwiftUI

/// Type scale (SF Pro; numbers in the rounded design with heavy weights). Every style is built on a Dynamic Type
/// text style, so it scales with the user's text size.
extension Font {
    /// Hero metric, e.g. the route card's "18 min".
    static let metricHero = Font.system(.largeTitle, design: .rounded, weight: .heavy)
    /// Large metric, e.g. remaining time in follow mode.
    static let metricLarge = Font.system(.title, design: .rounded, weight: .heavy)
    /// Medium metric, e.g. values in a metric row.
    static let metricMedium = Font.system(.title3, design: .rounded, weight: .bold)
    /// Small metric inside chips and rows.
    static let metricSmall = Font.system(.subheadline, design: .rounded, weight: .semibold)
    /// Unit next to a metric ("min", "km").
    static let metricUnit = Font.system(.subheadline, design: .rounded, weight: .semibold)

    /// Card / sheet titles.
    static let cardTitle = Font.system(.title3, design: .default, weight: .bold)
    /// Section headers.
    static let sectionTitle = Font.system(.headline, design: .default, weight: .semibold)
    /// Captions under metrics.
    static let metricCaption = Font.system(.caption, design: .default, weight: .medium)
    /// Emphasised small print.
    static let captionStrong = Font.system(.caption, design: .default, weight: .semibold)
    /// Chip labels.
    static let chipLabel = Font.system(.footnote, design: .rounded, weight: .semibold)
}
