import ShadeFeatures
import SwiftUI

/// Which end of the trip the place search is editing.
enum SeatSideTripEnd: String, Identifiable, Hashable {
    case from, to

    var id: String { rawValue }

    /// Small label above the place name.
    var caption: LocalizedStringKey {
        switch self {
        case .from: return "From"
        case .to: return "To"
        }
    }

    /// Shown while no place is chosen.
    var placeholder: LocalizedStringKey {
        switch self {
        case .from: return "Choose where you get on"
        case .to: return "Choose where you get off"
        }
    }

    /// Title of the place-search sheet.
    var searchTitle: LocalizedStringKey {
        switch self {
        case .from: return "Where do you get on?"
        case .to: return "Where do you get off?"
        }
    }

    /// Like a walk's start and destination: the ends differ by symbol, and orange stays reserved for the sun.
    var systemImage: String {
        switch self {
        case .from: return "smallcircle.filled.circle"
        case .to: return "flag.fill"
        }
    }

    var tint: Color { Theme.shade }
}

/// Trip inputs of the Seat side screen: From / To (with swap), vehicle and departure time.
struct SeatSideTripForm: View {
    @Binding var editingEnd: SeatSideTripEnd?
    @Binding var followsNow: Bool

    @Environment(SeatSideModel.self) private var seatSide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: Theme.spacing) {
            endpointsCard
            optionsCard
        }
    }

    // MARK: - From / To

    private var endpointsCard: some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                SeatSideEndpointRow(end: .from, place: seatSide.from) {
                    editingEnd = .from
                }
                Divider()
                    .padding(.leading, 48)
                SeatSideEndpointRow(end: .to, place: seatSide.to) {
                    editingEnd = .to
                }
            }
            swapButton
        }
        .shadewalkCard(padding: 12)
    }

    private var swapButton: some View {
        Button {
            withMotionAwareAnimation(reduceMotion: reduceMotion, Theme.quickSpring) {
                seatSide.swap()
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.shade)
                .frame(width: 44, height: 44)
                .background(Theme.shadeSoft, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(seatSide.from == nil && seatSide.to == nil)
        .accessibilityLabel(Text("Swap where you get on and off"))
    }

    // MARK: - Vehicle & departure

    private var optionsCard: some View {
        @Bindable var model = seatSide
        return VStack(alignment: .leading, spacing: 14) {
            Text("Vehicle")
                .font(.sectionTitle)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            SeatSideVehiclePicker(selection: $model.vehicle)
            Divider()
            departureRow
        }
        .shadewalkCard()
    }

    private var departureRow: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            Label {
                Text("Departure")
            } icon: {
                Image(systemName: "clock")
                    .foregroundStyle(Theme.shade)
            }
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.ink)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 4)
            }
            HStack(spacing: 10) {
                nowButton
                DatePicker("Departure time", selection: departureBinding, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        }
    }

    private var nowButton: some View {
        Button {
            followsNow = true
            seatSide.departure = Date()
        } label: {
            ChipView("Now", systemImage: followsNow ? "checkmark" : "clock.arrow.circlepath",
                     style: followsNow ? .filled : .outline)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Leave now"))
        .accessibilityAddTraits(followsNow ? [.isButton, .isSelected] : [.isButton])
    }

    /// Picking a time stops following the clock.
    private var departureBinding: Binding<Date> {
        Binding(
            get: { seatSide.departure },
            set: { newValue in
                followsNow = false
                seatSide.departure = newValue
            })
    }
}

// MARK: - Endpoint row

/// "From" / "To" row: tinted badge, caption and the chosen place (or a prompt). Opens place search.
private struct SeatSideEndpointRow: View {
    let end: SeatSideTripEnd
    let place: Place?
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 36

    init(end: SeatSideTripEnd, place: Place?, action: @escaping () -> Void) {
        self.end = end
        self.place = place
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: end.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(end.tint)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(end.tint.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(end.caption)
                        .font(.captionStrong)
                        .foregroundStyle(Theme.inkSecondary)
                    placeText
                        .font(.body.weight(.semibold))
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens place search"))
    }

    @ViewBuilder
    private var placeText: some View {
        if let place {
            Text(verbatim: place.displayName)
                .foregroundStyle(Theme.ink)
        } else {
            Text(end.placeholder)
                .foregroundStyle(Theme.inkSecondary)
        }
    }
}

// MARK: - Vehicle picker

/// Segmented control for bus / tram / train with icon and name in every segment (a system segmented picker can show
/// only one of the two).
private struct SeatSideVehiclePicker: View {
    @Binding var selection: VehicleKind

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(VehicleKind.allCases, id: \.self) { vehicle in
                segment(vehicle)
            }
        }
        .padding(4)
        .sensoryFeedback(.selection, trigger: selection)
        .background(Theme.canvas, in: Theme.controlShape)
        .overlay {
            Theme.controlShape.strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Vehicle"))
    }

    private func segment(_ vehicle: VehicleKind) -> some View {
        let isSelected = vehicle == selection
        return Button {
            withMotionAwareAnimation(reduceMotion: reduceMotion, Theme.quickSpring) {
                selection = vehicle
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: vehicle.systemImage)
                    .font(.title3.weight(.semibold))
                Text(verbatim: vehicle.displayName)
                    .font(.chipLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isSelected ? Theme.onShade : Theme.ink)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: Theme.controlCornerRadius - 4, style: .continuous)
                        .fill(Theme.shade)
                        .matchedGeometryEffect(id: "selectedVehicle", in: selectionNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: vehicle.displayName))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}
