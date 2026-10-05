import MapKit
import ShadeFeatures
import SwiftUI

/// Small, non-interactive map of the road path behind the seat-side advice, with the stops at both ends.
struct SeatSideRouteMap: View {
    let path: DrivingPath

    var body: some View {
        Map(initialPosition: cameraPosition, interactionModes: []) {
            MapPolyline(coordinates: coordinates)
                .stroke(Theme.ink.opacity(0.85),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
            if let start = startCoordinate {
                Annotation("Get on", coordinate: start) {
                    SeatSideMapStop(systemImage: SeatSideTripEnd.from.systemImage, tint: SeatSideTripEnd.from.tint)
                }
            }
            if let end = endCoordinate {
                Annotation("Get off", coordinate: end) {
                    SeatSideMapStop(systemImage: SeatSideTripEnd.to.systemImage, tint: SeatSideTripEnd.to.tint)
                }
            }
        }
        .mapStyle(Theme.mapStyle)
        .id(path)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Map of the trip"))
    }

    private var coordinates: [CLLocationCoordinate2D] {
        path.coordinates.clCoordinates
    }

    private var startCoordinate: CLLocationCoordinate2D? {
        path.coordinates.first?.clCoordinate
    }

    private var endCoordinate: CLLocationCoordinate2D? {
        path.coordinates.last?.clCoordinate
    }

    private var cameraPosition: MapCameraPosition {
        MapCameraPosition.fitting(path.coordinates, paddingFactor: 1.4, minimumSpanMeters: 600) ?? .automatic
    }
}

/// End-of-trip marker: icon on a tinted, white-ringed circle (the icon differs per end, so it isn't colour-only). Tints
/// are dark in light mode and light in dark mode, so `onShade` icons stay legible on them.
private struct SeatSideMapStop: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.onShade)
            .frame(width: 24, height: 24)
            .background(tint, in: Circle())
            .overlay {
                Circle().stroke(Theme.surface, lineWidth: 2)
            }
            .shadow(color: Theme.cardShadow, radius: 4, x: 0, y: 2)
    }
}

#if DEBUG
#Preview("Seat side map") {
    SeatSideRouteMap(path: DrivingPath(coordinates: [PreviewData.downtown,
                                                     PreviewData.point(900, 0),
                                                     PreviewData.point(900, 700)],
                                       expectedTravelTime: 300))
        .frame(height: 180)
        .clipShape(Theme.controlShape)
        .padding()
        .background(Theme.canvas)
}
#endif
