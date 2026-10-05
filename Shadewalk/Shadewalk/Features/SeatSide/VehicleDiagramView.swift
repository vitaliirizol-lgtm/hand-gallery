import ShadeFeatures
import SwiftUI

/// Original top-down drawing of the vehicle heading up the screen: rounded body, window strips, two seat columns.
/// The recommended side is filled in Shade green with a "You" seat; sun rays in Sun orange hit the other side.
///
/// Never colour-only: sides are labelled "Left" / "Right", the sunny side carries a sun icon and "Sun", the shady side a
/// leaf, "Shade" and the "You" marker. VoiceOver reads a one-line summary instead of the drawing.
struct VehicleDiagramView: View {
    let vehicle: VehicleKind
    /// Side to sit on; `.either` highlights neither.
    let seatSide: SeatSide
    let sunOnLeft: Bool
    let sunOnRight: Bool
    /// Shown above the vehicle when there is no direct sun (moon, cloud).
    let skySymbol: String?

    init(vehicle: VehicleKind, seatSide: SeatSide, sunOnLeft: Bool, sunOnRight: Bool, skySymbol: String? = nil) {
        self.vehicle = vehicle
        self.seatSide = seatSide
        self.sunOnLeft = sunOnLeft
        self.sunOnRight = sunOnRight
        self.skySymbol = skySymbol
    }

    /// Diagram for computed advice: the sun is drawn on the dominant side (both sides when balanced).
    init(vehicle: VehicleKind, advice: SeatSideAdvice) {
        var left = false
        var right = false
        var sky: String?
        switch advice.reason {
        case .sunMostlyOnRight:
            right = true
        case .sunMostlyOnLeft:
            left = true
        case .balanced:
            let hasSideSun = advice.sunOnLeftShare + advice.sunOnRightShare > 0
            left = hasSideSun
            right = hasSideSun
        case .sunDown:
            sky = "moon.stars.fill"
        case .overcast:
            sky = "cloud.fill"
        }
        self.init(vehicle: vehicle, seatSide: advice.recommendation, sunOnLeft: left, sunOnRight: right,
                  skySymbol: sky)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let skySymbol {
                Image(systemName: skySymbol)
                    .font(.title2)
                    .foregroundStyle(Theme.inkSecondary)
            }
            travelDirection
            HStack(alignment: .center, spacing: 8) {
                VehicleDiagramCallout(side: .left, isSunny: sunOnLeft, isYourSide: seatSide == .left)
                VehicleDiagramBody(vehicle: vehicle, seatSide: seatSide, sunOnLeft: sunOnLeft,
                                   sunOnRight: sunOnRight)
                VehicleDiagramCallout(side: .right, isSunny: sunOnRight, isYourSide: seatSide == .right)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Seat diagram"))
        .accessibilityValue(Text(verbatim: accessibilityDescription))
    }

    private var travelDirection: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.caption.weight(.bold))
            Text("Direction of travel")
                .font(.captionStrong)
        }
        .foregroundStyle(Theme.inkSecondary)
    }

    private var accessibilityDescription: String {
        let seat: String
        switch seatSide {
        case .left:
            seat = String(localized: "Your seat is on the left, in the shade.", comment: "Seat diagram, VoiceOver.")
        case .right:
            seat = String(localized: "Your seat is on the right, in the shade.", comment: "Seat diagram, VoiceOver.")
        case .either:
            seat = String(localized: "Either side works.", comment: "Seat diagram, VoiceOver.")
        }
        let sun: String
        switch (sunOnLeft, sunOnRight) {
        case (true, true):
            sun = String(localized: "The sun shines on both sides.", comment: "Seat diagram, VoiceOver.")
        case (true, false):
            sun = String(localized: "The sun shines on the left side.", comment: "Seat diagram, VoiceOver.")
        case (false, true):
            sun = String(localized: "The sun shines on the right side.", comment: "Seat diagram, VoiceOver.")
        case (false, false):
            sun = String(localized: "No direct sun on either side.", comment: "Seat diagram, VoiceOver.")
        }
        return seat + " " + sun
    }
}

// MARK: - Sides

private enum VehicleDiagramSide {
    case left, right

    func matches(_ seatSide: SeatSide) -> Bool {
        switch (self, seatSide) {
        case (.left, .left), (.right, .right): return true
        case (.left, .right), (.right, .left), (_, .either): return false
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

/// What is happening on one side of the vehicle: sun rays, or shade with the "You" marker.
private struct VehicleDiagramCallout: View {
    let side: VehicleDiagramSide
    let isSunny: Bool
    let isYourSide: Bool

    var body: some View {
        VStack(spacing: 8) {
            if isSunny {
                sunny
            } else if isYourSide {
                shady
            }
            Text(side.title)
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 68)
    }

    private var sunny: some View {
        VStack(spacing: 6) {
            Image(systemName: "sun.max.fill")
                .font(.title2)
                .foregroundStyle(Theme.sun)
            SeatSideSunRays(pointsTrailing: side == .left)
                .stroke(Theme.sun, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [7, 5]))
                .frame(width: 44, height: 64)
            Text("Sun")
                .font(.captionStrong)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private var shady: some View {
        VStack(spacing: 6) {
            Image(systemName: "leaf.fill")
                .font(.title3)
                .foregroundStyle(Theme.shade)
            Text("Shade")
                .font(.captionStrong)
                .foregroundStyle(Theme.shade)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 2) {
                if side == .right {
                    pointer("arrowtriangle.left.fill")
                }
                Text("You")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.onShade)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.shade, in: Capsule())
                if side == .left {
                    pointer("arrowtriangle.right.fill")
                }
            }
        }
    }

    private func pointer(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Theme.shade)
    }
}

// MARK: - Body

/// Proportions per vehicle: tram = slim, articulated, driving cabs at both ends; train = long with a rounded nose.
private struct VehicleDiagramLayout {
    let width: CGFloat
    let height: CGFloat
    let frontRadius: CGFloat
    let rearRadius: CGFloat
    let rows: Int
    let seatsPerSide: Int
    let hasRearWindshield: Bool
    let hasJoint: Bool

    init(_ vehicle: VehicleKind) {
        switch vehicle {
        case .bus:
            width = 96
            height = 204
            frontRadius = 20
            rearRadius = 12
            rows = 6
            seatsPerSide = 2
            hasRearWindshield = false
            hasJoint = false
        case .tram:
            width = 84
            height = 236
            frontRadius = 30
            rearRadius = 30
            rows = 6
            seatsPerSide = 1
            hasRearWindshield = true
            hasJoint = true
        case .train:
            width = 96
            height = 240
            frontRadius = 46
            rearRadius = 10
            rows = 7
            seatsPerSide = 2
            hasRearWindshield = false
            hasJoint = false
        }
    }

    var seatWidth: CGFloat { seatsPerSide == 1 ? 20 : 14 }
    var seatHeight: CGFloat { 12 }
    /// Row of the "You" seat.
    var youRow: Int { rows / 2 }
    var windshieldInsetTop: CGFloat { frontRadius * 0.35 + 5 }
    var windshieldInsetBottom: CGFloat { rearRadius * 0.35 + 5 }
}

private struct VehicleDiagramBody: View {
    let vehicle: VehicleKind
    let seatSide: SeatSide
    let sunOnLeft: Bool
    let sunOnRight: Bool

    private var layout: VehicleDiagramLayout { VehicleDiagramLayout(vehicle) }

    private var outline: VehicleOutlineShape {
        VehicleOutlineShape(frontRadius: layout.frontRadius, rearRadius: layout.rearRadius)
    }

    var body: some View {
        ZStack {
            outline
                .fill(Theme.surface)
            windows
            windshields
            seats
            if layout.hasJoint {
                joint
            }
            outline
                .stroke(Theme.ink.opacity(0.75), lineWidth: 2)
        }
        .frame(width: layout.width, height: layout.height)
        .shadow(color: Theme.cardShadow, radius: 8, x: 0, y: 4)
    }

    // MARK: Parts

    private var windows: some View {
        HStack(spacing: 0) {
            windowStrip(.left)
            Spacer(minLength: 0)
            windowStrip(.right)
        }
        .padding(.horizontal, 3)
        .padding(.top, layout.frontRadius * 0.85)
        .padding(.bottom, max(layout.rearRadius * 0.85, 8))
    }

    private func windowStrip(_ side: VehicleDiagramSide) -> some View {
        Capsule()
            .fill(windowColor(side))
            .frame(width: 4)
    }

    private var windshields: some View {
        VStack(spacing: 0) {
            windshield
            Spacer(minLength: 0)
            if layout.hasRearWindshield {
                windshield
            }
        }
        .padding(.top, layout.windshieldInsetTop)
        .padding(.bottom, layout.windshieldInsetBottom)
    }

    private var windshield: some View {
        Capsule()
            .fill(Theme.inkSecondary.opacity(0.4))
            .frame(width: layout.width * 0.56, height: 6)
    }

    private var seats: some View {
        HStack(alignment: .top, spacing: 0) {
            seatColumn(.left)
            Spacer(minLength: 6)
            seatColumn(.right)
        }
        .padding(.horizontal, 11)
        .padding(.top, layout.windshieldInsetTop + 16)
        .padding(.bottom, layout.hasRearWindshield ? layout.windshieldInsetBottom + 16 : 12)
    }

    private func seatColumn(_ side: VehicleDiagramSide) -> some View {
        VStack(spacing: 0) {
            ForEach(0..<layout.rows, id: \.self) { row in
                seatRow(side, row: row)
                if row < layout.rows - 1 {
                    Spacer(minLength: 3)
                }
            }
        }
    }

    private func seatRow(_ side: VehicleDiagramSide, row: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<layout.seatsPerSide, id: \.self) { index in
                seat(side, row: row, index: index)
            }
        }
    }

    private func seat(_ side: VehicleDiagramSide, row: Int, index: Int) -> some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(seatColor(side))
            .frame(width: layout.seatWidth, height: layout.seatHeight)
            .overlay {
                if isYouSeat(side, row: row, index: index) {
                    youMarker
                }
            }
    }

    private var youMarker: some View {
        Image(systemName: "person.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Theme.onShade)
            .frame(width: 22, height: 22)
            .background(Theme.shade, in: Circle())
            .overlay {
                Circle().stroke(Theme.surface, lineWidth: 2)
            }
    }

    /// Articulation between the two tram sections.
    private var joint: some View {
        VStack(spacing: 3) {
            Rectangle().frame(height: 1.5)
            Rectangle().frame(height: 1.5)
            Rectangle().frame(height: 1.5)
        }
        .foregroundStyle(Theme.ink.opacity(0.45))
        .padding(.vertical, 3)
        .frame(width: layout.width - 4)
        .background(Theme.surface)
    }

    // MARK: Colours

    private func isSunny(_ side: VehicleDiagramSide) -> Bool {
        switch side {
        case .left: return sunOnLeft
        case .right: return sunOnRight
        }
    }

    private func windowColor(_ side: VehicleDiagramSide) -> Color {
        if isSunny(side) { return Theme.sun }
        if side.matches(seatSide) { return Theme.shade }
        return Theme.inkSecondary.opacity(0.35)
    }

    private func seatColor(_ side: VehicleDiagramSide) -> Color {
        if side.matches(seatSide) { return Theme.shade.opacity(0.85) }
        if isSunny(side) { return Theme.sun.opacity(0.45) }
        return Theme.inkSecondary.opacity(0.22)
    }

    private func isYouSeat(_ side: VehicleDiagramSide, row: Int, index: Int) -> Bool {
        guard side.matches(seatSide), row == layout.youRow else { return false }
        switch side {
        case .left: return index == 0
        case .right: return index == layout.seatsPerSide - 1
        }
    }
}

// MARK: - Shapes

/// Vehicle outline with separately rounded front (top) and rear (bottom) corners.
private struct VehicleOutlineShape: Shape {
    var frontRadius: CGFloat
    var rearRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let front = min(max(frontRadius, 0), limit)
        let rear = min(max(rearRadius, 0), limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + front))
        path.addQuadCurve(to: CGPoint(x: rect.minX + front, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - front, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + front),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rear))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - rear, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rear, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - rear),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Slanted light beams aimed at the vehicle: towards trailing when `pointsTrailing` (sun on the left), else leading.
struct SeatSideSunRays: Shape {
    var pointsTrailing: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }
        let count = 4
        let rise = min(rect.height / CGFloat(count) * 0.6, 8)
        for index in 0..<count {
            let y = rect.minY + rect.height * (CGFloat(index) + 0.5) / CGFloat(count)
            let inset = index.isMultiple(of: 2) ? 0 : rect.width * 0.3
            let outer = pointsTrailing ? rect.minX + inset : rect.maxX - inset
            let inner = pointsTrailing ? rect.maxX : rect.minX
            path.move(to: CGPoint(x: outer, y: y - rise / 2))
            path.addLine(to: CGPoint(x: inner, y: y + rise / 2))
        }
        return path
    }
}

#if DEBUG
#Preview("Vehicle diagrams") {
    ScrollView {
        VStack(spacing: 24) {
            VehicleDiagramView(vehicle: .bus, seatSide: .left, sunOnLeft: false, sunOnRight: true)
            VehicleDiagramView(vehicle: .tram, seatSide: .right, sunOnLeft: true, sunOnRight: false)
            VehicleDiagramView(vehicle: .train, seatSide: .either, sunOnLeft: false, sunOnRight: false,
                               skySymbol: "moon.stars.fill")
        }
        .padding()
    }
    .background(Theme.canvas)
}
#endif
