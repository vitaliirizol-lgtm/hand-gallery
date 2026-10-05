import Charts
import ShadeFeatures
import SwiftUI

/// Slope profile from start to arrival: one bar per elevation bin, as tall as the stretch is steep (|grade| in %),
/// coloured by slope category with a legend naming each category.
struct SlopeChartView: View {
    let profile: ElevationProfile
    var units: UnitPreference = .system

    @ScaledMetric(relativeTo: .body) private var chartHeight: CGFloat = 140

    init(profile: ElevationProfile, units: UnitPreference = .system) {
        self.profile = profile
        self.units = units
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Slope", systemImage: "mountain.2.fill")
            summary
            chart
            legend
            Text("Elevation from Open-Meteo")
                .font(.caption2)
                .foregroundStyle(Theme.inkSecondary)
        }
        .shadewalkCard()
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(alignment: .top, spacing: 20) {
            MetricView(value: Formatters.elevation(profile.ascent, units: units), caption: "Climb",
                       systemImage: "arrow.up.right", size: .small)
            MetricView(value: Formatters.elevation(profile.descent, units: units), caption: "Descent",
                       systemImage: "arrow.down.right", size: .small)
            MetricView(value: Formatters.percent(profile.maxGrade), caption: "Steepest",
                       systemImage: "triangle.fill", size: .small)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Chart

    private var chart: some View {
        Chart(bars) { bar in
            BarMark(x: .value("Stretch", bar.key), y: .value("Steepness", bar.percent))
                .foregroundStyle(bar.category.tint)
                .cornerRadius(3)
        }
        .chartYScale(domain: 0...yAxisMaximum)
        .chartXAxis {
            AxisMarks(values: axisKeys) { value in
                AxisValueLabel {
                    axisLabel(for: value)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: yAxisTicks) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Double.self) {
                        Text(verbatim: Formatters.percent(percent / 100))
                    }
                }
            }
        }
        .frame(height: chartHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Slope profile"))
        .accessibilityValue(accessibilitySummary)
    }

    private var bars: [SlopeChartBar] {
        profile.bins.enumerated().map { index, bin in
            SlopeChartBar(id: index, key: String(index + 1),
                          percent: bin.grade.isFinite ? abs(bin.grade) * 100 : 0, category: bin.category)
        }
    }

    /// First and last bar: labelled "Start" and "Arrival".
    private var axisKeys: [String] {
        guard let first = bars.first?.key, let last = bars.last?.key else { return [] }
        return first == last ? [first] : [first, last]
    }

    private func axisLabel(for value: AxisValue) -> Text {
        if let key = value.as(String.self), key == bars.first?.key {
            return Text("Start")
        }
        return Text("Arrival")
    }

    /// Whole-percent step of the y axis; at least 0–4 % so flat routes don't look dramatic.
    private var yAxisStep: Double {
        let steepest = bars.map(\.percent).max() ?? 0
        let base = max(4, steepest * 1.15)
        return max(1, (base / 2).rounded(.up))
    }

    private var yAxisMaximum: Double { yAxisStep * 2 }

    private var yAxisTicks: [Double] { [0, yAxisStep, yAxisStep * 2] }

    // MARK: - Legend

    private var categories: [SlopeCategory] {
        Array(Set(profile.bins.map(\.category))).sorted()
    }

    private var legendFlow: WalkChipFlow { WalkChipFlow(spacing: 14, lineSpacing: 6) }

    private var legend: some View {
        legendFlow {
            ForEach(categories, id: \.self) { category in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(category.tint)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
                    Text(verbatim: category.displayName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var accessibilitySummary: Text {
        let steepest = Formatters.percentValue(profile.maxGrade)
        let climb = Formatters.elevation(profile.ascent, units: units)
        let descent = Formatters.elevation(profile.descent, units: units)
        return Text("\(profile.overallCategory.displayName). Steepest stretch \(steepest) percent. Climb \(climb), descent \(descent).")
    }
}

/// One bar of the slope chart.
private struct SlopeChartBar: Identifiable {
    let id: Int
    let key: String
    let percent: Double
    let category: SlopeCategory
}

#if DEBUG
#Preview("Slope chart") {
    ScrollView {
        if let elevation = PreviewData.sampleRoute?.elevation {
            SlopeChartView(profile: elevation)
                .padding()
        }
    }
    .background(Theme.canvas)
    .previewEnvironment()
}
#endif
