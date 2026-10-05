import MapKit
import ShadeFeatures
import SwiftUI

/// Full-bleed map of the Walk tab: shade overlay, route alternatives (selected one coloured by shade and sun), route
/// label pills, start and destination, cool spots and the user's position.
///
/// The overlay polygons arrive ready-made (`WalkMapPolygon.polygons(from:)`, built once per overlay by the Walk
/// screen), so redrawing the map never converts thousands of rings again.
struct WalkMapView: View {
    @Binding var camera: MapCameraPosition
    let mapScope: Namespace.ID
    let overlayPolygons: [WalkMapPolygon]
    let showsCoolSpots: Bool
    @Binding var selectedCoolSpotID: Int64?
    let onCameraSettled: (MKCoordinateRegion) -> Void
    let onPlanToCoolSpot: (CoolSpot) -> Void

    @Environment(RoutePlannerModel.self) private var planner
    @Environment(CoolSpotsModel.self) private var coolSpots

    init(camera: Binding<MapCameraPosition>, mapScope: Namespace.ID, overlayPolygons: [WalkMapPolygon],
         showsCoolSpots: Bool, selectedCoolSpotID: Binding<Int64?>,
         onCameraSettled: @escaping (MKCoordinateRegion) -> Void, onPlanToCoolSpot: @escaping (CoolSpot) -> Void) {
        _camera = camera
        self.mapScope = mapScope
        self.overlayPolygons = overlayPolygons
        self.showsCoolSpots = showsCoolSpots
        _selectedCoolSpotID = selectedCoolSpotID
        self.onCameraSettled = onCameraSettled
        self.onPlanToCoolSpot = onPlanToCoolSpot
    }

    var body: some View {
        Map(position: $camera, scope: mapScope) {
            shadeLayer
            alternateRouteLayer
            selectedRouteLayer
            coolSpotLayer
            endpointLayer
            routeLabelLayer
            UserAnnotation()
        }
        .mapStyle(Theme.mapStyle)
        .mapControls {
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            onCameraSettled(context.region)
        }
    }

    // MARK: - Layers

    @MapContentBuilder
    private var shadeLayer: some MapContent {
        ForEach(overlayPolygons) { polygon in
            MapPolygon(coordinates: polygon.coordinates)
                .foregroundStyle(Theme.shadeOverlayFill)
        }
    }

    @MapContentBuilder
    private var alternateRouteLayer: some MapContent {
        ForEach(alternateRoutes) { route in
            MapPolyline(coordinates: route.coordinates.clCoordinates)
                .stroke(Theme.alternateRouteColor, style: Theme.routeStroke(isShaded: true, isSelected: false))
        }
    }

    @MapContentBuilder
    private var selectedRouteLayer: some MapContent {
        if let route = planner.selectedRoute, route.coordinates.count >= 2 {
            MapPolyline(coordinates: route.coordinates.clCoordinates)
                .stroke(Color.white, style: WalkMapStyle.casing)
            ForEach(selectedRuns) { run in
                MapPolyline(coordinates: run.coordinates)
                    .stroke(Theme.routeColor(isShaded: run.isShaded), style: Theme.routeStroke(isShaded: run.isShaded))
            }
        }
    }

    @MapContentBuilder
    private var coolSpotLayer: some MapContent {
        if showsCoolSpots {
            ForEach(visibleCoolSpots) { item in
                Annotation(item.spot.displayName, coordinate: item.spot.coordinate.clCoordinate, anchor: .bottom) {
                    CoolSpotMapBadge(spot: item.spot, isSelected: selectedCoolSpotID == item.id,
                                     onToggle: { toggleCoolSpot(item.id) },
                                     onPlanRoute: { onPlanToCoolSpot(item.spot) })
                }
                .annotationTitles(.hidden)
            }
        }
    }

    @MapContentBuilder
    private var endpointLayer: some MapContent {
        if let start = startCoordinate {
            Annotation(String(localized: "Start", comment: "Map label for the start of the route."),
                       coordinate: start, anchor: .center) {
                WalkOriginDot()
            }
            .annotationTitles(.hidden)
        }
        if let destination = planner.destination {
            Marker(destination.displayName, systemImage: "flag.fill", coordinate: destination.coordinate.clCoordinate)
                .tint(Theme.shade)
        }
    }

    @MapContentBuilder
    private var routeLabelLayer: some MapContent {
        ForEach(routeLabels) { label in
            Annotation(label.title, coordinate: label.coordinate, anchor: .bottom) {
                RouteLabelPill(route: label.route, isSelected: label.isSelected) {
                    planner.select(label.route)
                }
            }
            .annotationTitles(.hidden)
        }
    }

    // MARK: - Data

    private var alternateRoutes: [WalkRoute] {
        let selectedID = planner.selectedRoute?.id
        return planner.routes.filter { $0.id != selectedID && $0.coordinates.count >= 2 }
    }

    private var selectedRuns: [WalkMapRun] {
        guard let route = planner.selectedRoute else { return [] }
        return WalkGeometry.runs(of: route).map { run in
            WalkMapRun(id: run.id, coordinates: run.coordinates.clCoordinates, isShaded: run.isShaded)
        }
    }

    private var routeLabels: [WalkRouteLabel] {
        let selectedID = planner.selectedRoute?.id
        var labels: [WalkRouteLabel] = []
        for (index, route) in planner.routes.enumerated() {
            guard let coordinate = WalkGeometry.labelCoordinate(for: route, index: index) else { continue }
            labels.append(WalkRouteLabel(route: route, coordinate: coordinate.clCoordinate,
                                         isSelected: route.id == selectedID))
        }
        return labels
    }

    private var visibleCoolSpots: [CoolSpotItem] {
        Array(coolSpots.items.prefix(WalkMapStyle.maxCoolSpotAnnotations))
    }

    /// Start of the selected route, else a chosen (non-GPS) origin; the user's own dot marks "My Location".
    private var startCoordinate: CLLocationCoordinate2D? {
        if let first = planner.selectedRoute?.coordinates.first { return first.clCoordinate }
        guard let origin = planner.origin, origin.kind != .currentLocation else { return nil }
        return origin.coordinate.clCoordinate
    }

    private func toggleCoolSpot(_ id: Int64) {
        selectedCoolSpotID = selectedCoolSpotID == id ? nil : id
    }
}

// MARK: - Map data

/// A shade-overlay polygon ready for `MapPolygon`.
struct WalkMapPolygon: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]

    /// Map polygons for overlay rings (at most `WalkMapStyle.maxOverlayPolygons`; rings with fewer than 3 vertices
    /// are skipped).
    static func polygons(from rings: [[GeoCoordinate]]) -> [WalkMapPolygon] {
        var polygons: [WalkMapPolygon] = []
        polygons.reserveCapacity(min(rings.count, WalkMapStyle.maxOverlayPolygons))
        for (index, ring) in rings.prefix(WalkMapStyle.maxOverlayPolygons).enumerated() where ring.count >= 3 {
            polygons.append(WalkMapPolygon(id: index, coordinates: ring.clCoordinates))
        }
        return polygons
    }
}

/// A shaded or sunny run ready for `MapPolyline`.
struct WalkMapRun: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    let isShaded: Bool
}

/// Where a route's label pill sits.
struct WalkRouteLabel: Identifiable {
    let route: WalkRoute
    let coordinate: CLLocationCoordinate2D
    let isSelected: Bool

    var id: String { route.id }

    /// "Shadiest · 14 min".
    var title: String {
        String(localized: "\(route.profile.displayName) · \(Formatters.duration(route.duration))",
               comment: "Map label of a route: profile and walking time, e.g. “Shadiest · 14 min”.")
    }
}

// MARK: - Annotation views

/// Tappable "Shadiest · 14 min" pill on the map; selects its route.
struct RouteLabelPill: View {
    let route: WalkRoute
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: route.profile.systemImage)
                    .imageScale(.small)
                Text("\(route.profile.displayName) · \(Formatters.duration(route.duration))")
                    .lineLimit(1)
            }
            .font(.captionStrong)
            .foregroundStyle(isSelected ? Theme.onShade : route.profile.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isSelected {
                    Capsule().fill(route.profile.tint)
                } else {
                    Capsule().fill(Theme.surface)
                }
            }
            .overlay {
                Capsule().strokeBorder(isSelected ? Color.white.opacity(0.9) : Theme.hairline,
                                       lineWidth: isSelected ? 1.5 : 0.5)
            }
            .shadow(color: Theme.cardShadow, radius: 6, x: 0, y: 3)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(route.profile.displayName) route, \(Formatters.duration(route.duration))"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// Cool spot on the map: a small badge (with a 44 pt touch area) that opens a callout with "Shady route here".
struct CoolSpotMapBadge: View {
    let spot: CoolSpot
    let isSelected: Bool
    let onToggle: () -> Void
    let onPlanRoute: () -> Void

    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 30

    init(spot: CoolSpot, isSelected: Bool, onToggle: @escaping () -> Void, onPlanRoute: @escaping () -> Void) {
        self.spot = spot
        self.isSelected = isSelected
        self.onToggle = onToggle
        self.onPlanRoute = onPlanRoute
    }

    var body: some View {
        VStack(spacing: 6) {
            if isSelected {
                callout
            }
            Button(action: onToggle) {
                Image(systemName: spot.kind.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(spot.kind.tint)
                    .frame(width: size, height: size)
                    .background(Theme.surface, in: Circle())
                    .overlay {
                        Circle().strokeBorder(spot.kind.tint, lineWidth: isSelected ? 3 : 2)
                    }
                    .shadow(color: Theme.cardShadow, radius: 4, x: 0, y: 2)
                    .frame(width: max(44, size), height: max(44, size))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: spot.displayName))
            .accessibilityValue(Text(verbatim: spot.kind.displayName))
            .accessibilityHint(Text("Shows a shady route option"))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
        }
    }

    private var callout: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: spot.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                if spot.displayName != spot.kind.displayName {
                    Text(verbatim: spot.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            Button(action: onPlanRoute) {
                Label("Shady route here", systemImage: "figure.walk")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.onShade)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.shade, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(maxWidth: 220, alignment: .leading)
        .background(Theme.surface, in: Theme.controlShape)
        .overlay {
            Theme.controlShape.strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
        .shadow(color: Theme.cardShadow, radius: 10, x: 0, y: 4)
    }
}

/// Start of the route: a white-ringed shade dot.
struct WalkOriginDot: View {
    @ScaledMetric(relativeTo: .caption) private var size: CGFloat = 16

    var body: some View {
        Circle()
            .fill(Theme.shade)
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(Color.white, lineWidth: 3)
            }
            .shadow(color: Theme.cardShadow, radius: 3, x: 0, y: 1)
            .accessibilityHidden(true)
    }
}
