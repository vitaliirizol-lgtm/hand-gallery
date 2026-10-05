import ShadeFeatures
import SwiftUI

/// "When do you leave?" card: Now, or any time today between sunrise and sunset on a sun-gradient track with a tick
/// (and a haptic) at every whole hour. The part of the day that has already gone is washed out, and a time in the past
/// is labelled "Earlier today".
///
/// Writes only `DepartureTimeModel` (`sliderValue` / `selectNow()`); the app environment mirrors its departure into
/// `RoutePlannerModel.departure`, which replans. Compact single row by default; stacked at accessibility text sizes.
/// Redrawn every minute, so "now" (time, thumb, sun glyph, elapsed part of the track) keeps up with the clock.
struct DepartureTimeSlider: View {
    @Environment(DepartureTimeModel.self) private var departureTime
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric(relativeTo: .subheadline) private var timeLabelWidth: CGFloat = 58

    var body: some View {
        TimelineView(.everyMinute) { _ in
            content(value: sliderValue)
        }
        .shadewalkCard(padding: 12)
        .sensoryFeedback(.selection, trigger: hourBucket)
    }

    /// `DepartureTimeModel.sliderValue`: reading "Now" gives the current time; writing selects a time today.
    private var sliderValue: Binding<Double> {
        Binding(get: { departureTime.sliderValue }, set: { newValue in departureTime.sliderValue = newValue })
    }

    @ViewBuilder
    private func content(value: Binding<Double>) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    timeLabel
                    Spacer(minLength: 8)
                    nowButton
                }
                track(value: value)
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                timeLabel
                    .frame(minWidth: timeLabelWidth, alignment: .leading)
                track(value: value)
                nowButton
            }
        }
    }

    // MARK: - Pieces

    /// "Leave" (or "Earlier today") over the selected time, with a sun (or moon, before sunrise / after sunset) glyph.
    private var timeLabel: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: isSunUpAtDeparture ? "sun.max.fill" : "moon.stars.fill")
                    .foregroundStyle(isSunUpAtDeparture ? Theme.sunInk : Theme.inkSecondary)
                caption
                    .foregroundStyle(Theme.inkSecondary)
            }
            .font(.caption.weight(.semibold))
            Text(verbatim: selectedTimeText)
                .font(.metricSmall)
                .foregroundStyle(isInThePast ? Theme.inkSecondary : Theme.ink)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headline)
    }

    private var caption: Text {
        if isInThePast {
            return Text("Earlier today", comment: "Above a departure time that has already passed.")
        }
        return Text("Leave", comment: "Label above the departure time on the Walk screen.")
    }

    private var headline: Text {
        if isNow {
            return Text("Leave now · \(selectedTimeText)")
        }
        if isInThePast {
            return Text("Earlier today · \(selectedTimeText)",
                        comment: "VoiceOver: the chosen departure time has already passed, e.g. “Earlier today · 08:00”.")
        }
        return Text("Leave at \(selectedTimeText)")
    }

    private func track(value: Binding<Double>) -> some View {
        VStack(spacing: 2) {
            DepartureSliderTrack(value: value, range: departureTime.range, step: departureTime.step,
                                 hourMarks: departureTime.hourMarks, nowValue: departureTime.nowValue,
                                 valueText: selectedTimeText)
            bounds
        }
    }

    private var nowButton: some View {
        Button {
            departureTime.selectNow()
        } label: {
            ChipView("Now", systemImage: "clock.arrow.circlepath", tint: Theme.shade, style: isNow ? .filled : .outline)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(Text("Leave now"))
        .accessibilityAddTraits(isNow ? [.isButton, .isSelected] : [.isButton])
    }

    /// Sunrise and sunset under the ends of the track (or the fallback range's ends).
    @ViewBuilder
    private var bounds: some View {
        if let sunrise = departureTime.sunTimes?.sunrise, let sunset = departureTime.sunTimes?.sunset {
            HStack {
                boundLabel(clock(sunrise), systemImage: "sunrise.fill", tint: SunGradient.dawn)
                    .accessibilityLabel(Text("Sunrise \(clock(sunrise))"))
                Spacer(minLength: 4)
                boundLabel(clock(sunset), systemImage: "sunset.fill", tint: SunGradient.dusk)
                    .accessibilityLabel(Text("Sunset \(clock(sunset))"))
            }
        } else {
            HStack {
                boundLabel(clock(departureTime.date(forValue: departureTime.range.lowerBound)), systemImage: "clock",
                           tint: Theme.inkSecondary)
                Spacer(minLength: 4)
                boundLabel(clock(departureTime.date(forValue: departureTime.range.upperBound)), systemImage: "clock",
                           tint: Theme.inkSecondary)
            }
        }
    }

    private func boundLabel(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .foregroundStyle(Theme.inkSecondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.caption2.weight(.medium))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Values

    private var isNow: Bool { departureTime.departure.isNow }

    /// A chosen time (not "Now") that has already passed.
    private var isInThePast: Bool {
        !isNow && departureTime.resolvedDate < Date()
    }

    private var selectedTimeText: String { clock(departureTime.resolvedDate) }

    /// Changes whenever a chosen time crosses a whole hour (drives the haptic tick); constant while "Now" follows the
    /// clock, so time passing doesn't tick.
    private var hourBucket: Int {
        guard !isNow else { return -1 }
        let value = departureTime.sliderValue
        return value.isFinite ? Int(value / 60) : 0
    }

    private var isSunUpAtDeparture: Bool {
        guard let sunrise = departureTime.sunTimes?.sunrise, let sunset = departureTime.sunTimes?.sunset else {
            return true
        }
        let date = departureTime.resolvedDate
        return date >= sunrise && date <= sunset
    }

    private func clock(_ date: Date) -> String {
        Formatters.clockTime(date, timeZone: departureTime.timeZone)
    }
}

/// The departure control: sun-gradient track with hour ticks, the part of the day already gone washed out, and a
/// thumb. Drag or tap to pick a time (snapped to `step`); VoiceOver adjusts it one step at a time.
///
/// Drawn by hand because a system `Slider` paints its own grey track over the gradient.
private struct DepartureSliderTrack: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let hourMarks: [Double]
    /// Slider value of the current time; the track before it is washed out.
    let nowValue: Double
    let valueText: String

    @ScaledMetric(relativeTo: .body) private var thumbSize: CGFloat = 26
    private let trackHeight: CGFloat = 6

    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, hourMarks: [Double], nowValue: Double,
         valueText: String) {
        _value = value
        self.range = range
        self.step = step
        self.hourMarks = hourMarks
        self.nowValue = nowValue
        self.valueText = valueText
    }

    var body: some View {
        GeometryReader { proxy in
            control(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: controlHeight)
        .accessibilityElement()
        .accessibilityLabel(Text("Departure time"))
        .accessibilityValue(Text(verbatim: valueText))
        .accessibilityAdjustableAction { direction in
            adjust(direction)
        }
    }

    private var thumbDiameter: CGFloat { min(thumbSize, 34) }

    private var controlHeight: CGFloat { max(32, thumbDiameter + 6) }

    /// Extra touch area above and below the control, so it is at least 44 pt tall without taking more room.
    private var touchOutset: CGFloat { max(0, (44 - controlHeight) / 2) }

    private func control(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            SunGradientTrack(height: trackHeight)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Theme.surface.opacity(0.6))
                        .frame(width: elapsedWidth(in: width))
                }
                .clipShape(Capsule())
                .frame(width: width)
                .position(x: width / 2, y: height / 2)
            HourTickMarks(fractions: tickFractions, inset: thumbDiameter / 2)
                .stroke(Theme.inkSecondary.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .frame(width: width, height: height)
            thumb
                .position(x: thumbCenter(for: value, in: width), y: height / 2)
        }
        .frame(width: width, height: height)
        .padding(.vertical, touchOutset)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    select(atX: drag.location.x, in: width)
                }
        )
        .padding(.vertical, -touchOutset)
    }

    private var thumb: some View {
        Circle()
            .fill(Color.white)
            .frame(width: thumbDiameter, height: thumbDiameter)
            .overlay {
                Circle().strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
            }
            .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
    }

    // MARK: Geometry

    private var span: Double { range.upperBound - range.lowerBound }

    private func fraction(of value: Double) -> CGFloat {
        guard span > 0 else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / span, 0), 1))
    }

    /// The thumb's centre travels between half a thumb from each end.
    private func thumbCenter(for value: Double, in width: CGFloat) -> CGFloat {
        let inset = thumbDiameter / 2
        return inset + max(0, width - inset * 2) * fraction(of: value)
    }

    /// Washed-out part of the track, up to the current time.
    private func elapsedWidth(in width: CGFloat) -> CGFloat {
        guard nowValue > range.lowerBound else { return 0 }
        return nowValue >= range.upperBound ? width : thumbCenter(for: nowValue, in: width)
    }

    private var tickFractions: [CGFloat] {
        hourMarks.map { fraction(of: $0) }
    }

    // MARK: Input

    private func select(atX x: CGFloat, in width: CGFloat) {
        let inset = thumbDiameter / 2
        let usable = width - inset * 2
        guard usable > 0, span > 0 else { return }
        let position = Double(min(max((x - inset) / usable, 0), 1))
        set(range.lowerBound + position * span)
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        let stepSize = step > 0 ? step : 15
        switch direction {
        case .increment:
            set(((value / stepSize).rounded(.down) + 1) * stepSize)
        case .decrement:
            set(((value / stepSize).rounded(.up) - 1) * stepSize)
        @unknown default:
            break
        }
    }

    /// Snaps to `step`, clamps to `range`, and writes only real changes (each one replans).
    private func set(_ raw: Double) {
        guard raw.isFinite else { return }
        let snapped = step > 0 ? (raw / step).rounded() * step : raw
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        if clamped != value {
            value = clamped
        }
    }
}

/// Short vertical ticks under the track at the given fractions of the thumb's travel.
private struct HourTickMarks: Shape {
    var fractions: [CGFloat]
    var inset: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let usable = max(0, rect.width - inset * 2)
        for fraction in fractions where fraction >= 0 && fraction <= 1 {
            let x = rect.minX + inset + usable * fraction
            path.move(to: CGPoint(x: x, y: rect.midY + 6))
            path.addLine(to: CGPoint(x: x, y: rect.midY + 10))
        }
        return path
    }
}

#if DEBUG
#Preview("Departure time") {
    VStack(spacing: 16) {
        DepartureTimeSlider()
        DepartureTimeSlider()
            .dynamicTypeSize(.accessibility2)
    }
    .padding()
    .background(Theme.canvas)
    .previewEnvironment()
}
#endif
