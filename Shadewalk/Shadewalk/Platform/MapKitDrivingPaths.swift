import CoreLocation
import Foundation
import MapKit
import ShadeFeatures

/// `DrivingPathProviding` backed by `MKDirections` (automobile): the road a bus / tram / train roughly follows.
struct MapKitDrivingPaths: DrivingPathProviding {
    // Runs on the main actor: MapKit request objects are created and started there.
    @MainActor
    func drivingPath(from: GeoCoordinate, to: GeoCoordinate) async throws -> DrivingPath {
        guard from.isValid, to.isValid else { throw ShadeError.noRouteFound }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(from)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(to)))
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw ShadeError.noRouteFound }
        let coordinates = route.polyline.coordinateList.map { GeoCoordinate($0) }.filter(\.isValid)
        guard coordinates.count >= 2 else { throw ShadeError.noRouteFound }
        return DrivingPath(coordinates: coordinates, expectedTravelTime: route.expectedTravelTime)
    }
}
