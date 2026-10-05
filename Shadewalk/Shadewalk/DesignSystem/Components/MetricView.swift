import SwiftUI

/// Size of a `MetricView`.
enum MetricSize: Hashable, Sendable {
    case hero, large, medium, small

    var valueFont: Font {
        switch self {
        case .hero: return .metricHero
        case .large: return .metricLarge
        case .medium: return .metricMedium
        case .small: return .metricSmall
        }
    }
}

/// Big rounded value + optional unit + optional caption, e.g. "18 min · Walk". Reads as one VoiceOver element.
struct MetricView: View {
    private let value: String
    private let unit: String?
    private let caption: Text?
    private let systemImage: String?
    private let tint: Color
    private let size: MetricSize
    private let alignment: HorizontalAlignment

    /// - Parameters:
    ///   - value: formatted value ("18 min", "1.4 km", or just "18" with `unit: "min"`).
    ///   - caption: localized caption under the value ("Walk", "Shade").
    init(value: String, unit: String? = nil, caption: LocalizedStringKey? = nil, systemImage: String? = nil,
         tint: Color = Theme.ink, size: MetricSize = .medium, alignment: HorizontalAlignment = .leading) {
        self.value = value
        self.unit = unit
        self.caption = caption.map { Text($0) }
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
        self.alignment = alignment
    }

    /// Caption that is already localized / formatted.
    init(value: String, unit: String? = nil, verbatimCaption: String, systemImage: String? = nil,
         tint: Color = Theme.ink, size: MetricSize = .medium, alignment: HorizontalAlignment = .leading) {
        self.value = value
        self.unit = unit
        self.caption = Text(verbatim: verbatimCaption)
        self.systemImage = systemImage
        self.tint = tint
        self.size = size
        self.alignment = alignment
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(verbatim: value)
                    .font(size.valueFont)
                    .foregroundStyle(tint)
                    .monospacedDigit()
                if let unit {
                    Text(verbatim: unit)
                        .font(.metricUnit)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if let caption {
                HStack(spacing: 4) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .accessibilityHidden(true)
                    }
                    caption
                }
                .font(.metricCaption)
                .foregroundStyle(Theme.inkSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Metrics") {
    HStack(spacing: 24) {
        MetricView(value: "18 min", caption: "Walk", size: .hero)
        MetricView(value: "1.4", unit: "km", caption: "Distance")
        MetricView(value: "62%", caption: "Shade", systemImage: "leaf.fill", tint: Theme.shade)
    }
    .padding()
    .background(Theme.canvas)
}
#endif
