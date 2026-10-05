import CoreLocation
import Foundation
import MapKit
import ShadeFeatures
import SwiftUI

// Bridges between ShadeCore's platform-neutral geometry and CoreLocation / MapKit.

extension CLLocationCoordinate2D {
    init(_ coordinate: GeoCoordinate) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

extension GeoCoordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// CoreLocation equivalent.
    var clCoordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(self) }
}

extension Array where Element == GeoCoordinate {
    /// CoreLocation equivalents, e.g. for `MapPolyline(coordinates:)` / `MapPolygon(coordinates:)`.
    var clCoordinates: [CLLocationCoordinate2D] { map { CLLocationCoordinate2D($0) } }
}

extension MKMultiPoint {
    /// All vertices of a polyline / polygon.
    var coordinateList: [CLLocationCoordinate2D] {
        let count = pointCount
        guard count > 0 else { return [] }
        var coordinates = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: count)
        coordinates.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            getCoordinates(base, range: NSRange(location: 0, length: count))
        }
        return coordinates
    }
}

extension BoundingBox {
    /// Box covered by `region` (clamped to valid latitudes / longitudes; no antimeridian wrapping).
    init(region: MKCoordinateRegion) {
        let halfLat = abs(region.span.latitudeDelta) / 2
        let halfLon = abs(region.span.longitudeDelta) / 2
        let center = region.center
        self.init(minLatitude: max(-90, center.latitude - halfLat),
                  minLongitude: max(-180, center.longitude - halfLon),
                  maxLatitude: min(90, center.latitude + halfLat),
                  maxLongitude: min(180, center.longitude + halfLon))
    }

    /// Region covering the box.
    var region: MKCoordinateRegion {
        MKCoordinateRegion(center: CLLocationCoordinate2D(center),
                           span: MKCoordinateSpan(latitudeDelta: maxLatitude - minLatitude,
                                                  longitudeDelta: maxLongitude - minLongitude))
    }
}

extension MKCoordinateRegion {
    /// Region showing all `coordinates`, enlarged by `paddingFactor` (1.3 = 30 % larger span) and at least
    /// `minimumSpanMeters` across. Nil when `coordinates` contains no valid coordinate.
    init?(fitting coordinates: [GeoCoordinate], paddingFactor: Double = 1.3, minimumSpanMeters: Double = 300) {
        guard let box = BoundingBox(coordinates: coordinates.filter(\.isValid)) else { return nil }
        let factor = paddingFactor.isFinite ? max(1, paddingFactor) : 1
        let center = box.center
        let minimumLatDelta = max(0, minimumSpanMeters) / GeoMath.metersPerDegreeLatitude
        let metersPerDegreeLon = max(GeoMath.metersPerDegreeLongitude(at: center.latitude), 1)
        let minimumLonDelta = max(0, minimumSpanMeters) / metersPerDegreeLon
        let latDelta = min(180, max((box.maxLatitude - box.minLatitude) * factor, minimumLatDelta))
        let lonDelta = min(360, max((box.maxLongitude - box.minLongitude) * factor, minimumLonDelta))
        self.init(center: CLLocationCoordinate2D(center),
                  span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta))
    }
}

extension MapCameraPosition {
    /// Camera showing all `coordinates` (see `MKCoordinateRegion(fitting:)`); nil when there are none.
    static func fitting(_ coordinates: [GeoCoordinate], paddingFactor: Double = 1.35,
                        minimumSpanMeters: Double = 400) -> MapCameraPosition? {
        guard let region = MKCoordinateRegion(fitting: coordinates, paddingFactor: paddingFactor,
                                              minimumSpanMeters: minimumSpanMeters) else { return nil }
        return .region(region)
    }

    /// Camera centred on `coordinate`, showing about `spanMeters` across.
    static func centered(on coordinate: GeoCoordinate, spanMeters: Double = 1_200) -> MapCameraPosition {
        .region(MKCoordinateRegion(center: CLLocationCoordinate2D(coordinate),
                                   latitudinalMeters: spanMeters, longitudinalMeters: spanMeters))
    }

    /// Follow-mode camera: centred on `coordinate`, tilted and rotated to `heading` (degrees from north).
    static func following(_ coordinate: GeoCoordinate, heading: Double?, distance: Double = 450,
                          pitch: Double = 45) -> MapCameraPosition {
        .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(coordinate), distance: distance,
                          heading: heading ?? 0, pitch: pitch))
    }
}
