import ShadeFeatures
import SwiftUI

/// Where the sun is during the trip, as two lanes labelled L and R — the vehicle's left side on top, its right side
/// below — running from departure (leading) to arrival (trailing).
///
/// A lane is striped orange while the sun shines on that side and plain soft green while it is in the shade; orange
/// dots mark the sun straight ahead or behind and grey lines the sun below the horizon. Every category has its own
/// texture (shown in the legend too), so the meaning never depends on colour; VoiceOver reads the shares and clock
/// times as one summary.
struct SeatTimelineView: View {
    let samples: [SeatSideSample]

    @ScaledMetric(relativeTo: .caption) private var laneHeight: CGFloat = 14
    private let laneGap: CGFloat = 3

    init(samples: [SeatSideSample]) {
        self.samples = samples
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                laneLabels
                VStack(spacing: 6) {
                    lanes
                    times
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Sun during the trip"))
            .accessibilityValue(Text(verbatim: accessibilitySummary))
            legend
        }
    }

    // MARK: - Lanes

    private var runs: [SeatTimelineRun] {
        SeatTimelineRun.runs(from: samples)
    }

    private var laneLabels: some View {
        VStack(alignment: .center, spacing: laneGap) {
            Text("L", comment: "Abbreviation of “left side” in the seat-side sun timeline.")
                .frame(height: laneHeight)
            Text("R", comment: "Abbreviation of “right side” in the seat-side sun timeline.")
                .frame(height: laneHeight)
        }
        .font(.captionStrong)
        .foregroundStyle(Theme.inkSecondary)
        .accessibilityHidden(true)
    }

    private var lanes: some View {
        GeometryReader { proxy in
            VStack(spacing: laneGap) {
                lane(.left, width: proxy.size.width)
                lane(.right, width: proxy.size.width)
            }
        }
        .frame(height: laneHeight * 2 + laneGap)
    }

    private func lane(_ side: SeatTimelineLane, width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Theme.shadeSoft)
            ForEach(runs) { run in
                SeatTimelineFill(style: run.category.style(in: side))
                    .frame(width: max(0, width * CGFloat(run.end - run.start)))
                    .offset(x: width * CGFloat(run.start))
            }
        }
        .frame(width: width, height: laneHeight)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder
    private var times: some View {
        if let first = samples.first, let last = samples.last {
            HStack {
                Text(verbatim: Formatters.clockTime(first.time))
                Spacer(minLength: 8)
                Text(verbatim: Formatters.clockTime(last.time))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.inkSecondary)
        }
    }

    // MARK: - Legend

    private var legend: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .leading)],
                  alignment: .leading, spacing: 8) {
            legendItem(.sun, title: "Sun on that side")
            legendItem(.shade, title: "Shade")
            if contains(.aheadOrBehind) {
                legendItem(.sunAheadOrBehind, title: "Sun ahead or behind")
            }
            if contains(.sunDown) {
                legendItem(.sunDown, title: "Sun down")
            }
        }
        .accessibilityHidden(true)
    }

    private func legendItem(_ style: SeatTimelineFillStyle, title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            SeatTimelineFill(style: style)
                .frame(width: 20, height: 10)
                .background(Theme.shadeSoft)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func contains(_ category: SeatTimelineCategory) -> Bool {
        runs.contains { $0.category == category }
    }

    // MARK: - VoiceOver

    private var accessibilitySummary: String {
        var shares: [SeatTimelineCategory: Double] = [:]
        for run in runs {
            shares[run.category, default: 0] += run.end - run.start
        }
        let left = Formatters.percent(shares[.left] ?? 0)
        let right = Formatters.percent(shares[.right] ?? 0)
        let aheadOrBehind = Formatters.percent(shares[.aheadOrBehind] ?? 0)
        let down = Formatters.percent(shares[.sunDown] ?? 0)
        guard let first = samples.first, let last = samples.last else { return "" }
        let start = Formatters.clockTime(first.time)
        let end = Formatters.clockTime(last.time)
        return String(localized: "From \(start) to \(end). Sun on the left side \(left) of the time, on the right side \(right), ahead or behind \(aheadOrBehind), below the horizon \(down).",
                      comment: "VoiceOver summary of the seat-side timeline. Times, then four percentages.")
    }
}

// MARK: - Model

/// Lane of the timeline = side of the vehicle.
private enum SeatTimelineLane {
    case left, right
}

/// Sun relative to the vehicle, merged into the four kinds the timeline shows.
private enum SeatTimelineCategory: Hashable {
    case left, right, aheadOrBehind, sunDown

    init(_ side: SunSide) {
        switch side {
        case .left: self = .left
        case .right: self = .right
        case .ahead, .behind: self = .aheadOrBehind
        case .none: self = .sunDown
        }
    }

    func style(in lane: SeatTimelineLane) -> SeatTimelineFillStyle {
        switch self {
        case .left:
            return lane == .left ? .sun : .shade
        case .right:
            return lane == .right ? .sun : .shade
        case .aheadOrBehind:
            return .sunAheadOrBehind
        case .sunDown:
            return .sunDown
        }
    }
}

/// Consecutive samples of the same category, as a span of the trip `[start, end]` (fractions 0–1).
private struct SeatTimelineRun: Identifiable, Hashable {
    let id: Int
    let category: SeatTimelineCategory
    let start: Double
    let end: Double

    /// Each sample covers the span halfway to its neighbours; equal neighbours are merged.
    static func runs(from samples: [SeatSideSample]) -> [SeatTimelineRun] {
        guard !samples.isEmpty else { return [] }
        let fractions = samples.map { sample -> Double in
            sample.fraction.isFinite ? min(max(sample.fraction, 0), 1) : 0
        }
        var result: [SeatTimelineRun] = []
        for index in samples.indices {
            let start = index == 0 ? 0 : (fractions[index - 1] + fractions[index]) / 2
            let end = index == samples.count - 1 ? 1 : (fractions[index] + fractions[index + 1]) / 2
            let category = SeatTimelineCategory(samples[index].sunSide)
            if let last = result.last, last.category == category {
                result[result.count - 1] = SeatTimelineRun(id: last.id, category: category, start: last.start,
                                                           end: end)
            } else {
                result.append(SeatTimelineRun(id: result.count, category: category, start: start, end: end))
            }
        }
        return result.filter { $0.end > $0.start }
    }
}

/// How a lane span is painted.
private enum SeatTimelineFillStyle {
    /// Sun on this side: orange with diagonal stripes.
    case sun
    /// This side is in the shade: the lane's plain soft green shows through.
    case shade
    /// Sun straight ahead or behind: orange dots on a pale orange tint.
    case sunAheadOrBehind
    /// Sun below the horizon: grey horizontal lines.
    case sunDown
}

private struct SeatTimelineFill: View {
    let style: SeatTimelineFillStyle

    var body: some View {
        switch style {
        case .sun:
            Rectangle()
                .fill(Theme.sun)
                .overlay {
                    DiagonalStripes(spacing: 5)
                        .stroke(Color.white.opacity(0.45), lineWidth: 1.5)
                }
                .clipped()
        case .shade:
            Color.clear
        case .sunAheadOrBehind:
            Rectangle()
                .fill(Theme.sun.opacity(0.18))
                .overlay {
                    SeatTimelineDots(spacing: 5, radius: 1)
                        .fill(Theme.sunInk)
                }
                .clipped()
        case .sunDown:
            Rectangle()
                .fill(Theme.inkSecondary.opacity(0.18))
                .overlay {
                    SeatTimelineHatch(spacing: 3.5)
                        .stroke(Theme.inkSecondary, lineWidth: 1)
                }
                .clipped()
        }
    }
}

/// Dots on a square grid.
private struct SeatTimelineDots: Shape {
    var spacing: CGFloat
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard spacing > 0, radius > 0, rect.width > 0, rect.height > 0 else { return path }
        var y = rect.minY + spacing / 2
        while y < rect.maxY {
            var x = rect.minX + spacing / 2
            while x < rect.maxX {
                path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                x += spacing
            }
            y += spacing
        }
        return path
    }
}

/// Evenly spaced horizontal lines.
private struct SeatTimelineHatch: Shape {
    var spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard spacing > 0, rect.width > 0, rect.height > 0 else { return path }
        var y = rect.minY + spacing / 2
        while y < rect.maxY {
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            y += spacing
        }
        return path
    }
}

#if DEBUG
#Preview("Seat timeline") {
    let start = PreviewData.referenceDate
    let sides: [SunSide] = [.right, .right, .right, .ahead, .left, .left, .right, .right, .right, .right, .none]
    let samples = sides.enumerated().map { index, side in
        SeatSideSample(fraction: Double(index) / Double(sides.count - 1),
                       time: start.addingTimeInterval(Double(index) * 90), sunSide: side, intensity: 0.6)
    }
    return SeatTimelineView(samples: samples)
        .shadewalkCard()
        .padding()
        .background(Theme.canvas)
}
#endif
