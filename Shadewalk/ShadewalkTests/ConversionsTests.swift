import CoreLocation
import MapKit
import ShadeFeatures
import SwiftUI
import XCTest
@testable import Shadewalk

final class ConversionsTests: XCTestCase {
    private let origin = GeoCoordinate(latitude: 37.7880, longitude: -122.4075)

    private func point(_ east: Double, _ north: Double) -> GeoCoordinate {
        LocalProjection(origin: origin).unproject(Point2D(x: east, y: north))
    }

    func testCoordinateRoundTrip() {
        let cl = CLLocationCoordinate2D(origin)
        XCTAssertEqual(cl.latitude, origin.latitude, accuracy: 1e-12)
        XCTAssertEqual(cl.longitude, origin.longitude, accuracy: 1e-12)
        XCTAssertEqual(GeoCoordinate(cl), origin)
        XCTAssertEqual(origin.clCoordinate.latitude, origin.latitude, accuracy: 1e-12)
        let list = [origin, point(100, 50)].clCoordinates
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[1].longitude, point(100, 50).longitude, accuracy: 1e-12)
    }

    func testBoundingBoxFromRegion() {
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 10, longitude: 20),
                                        span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 4))
        let box = BoundingBox(region: region)
        XCTAssertEqual(box.minLatitude, 9, accuracy: 1e-9)
        XCTAssertEqual(box.maxLatitude, 11, accuracy: 1e-9)
        XCTAssertEqual(box.minLongitude, 18, accuracy: 1e-9)
        XCTAssertEqual(box.maxLongitude, 22, accuracy: 1e-9)

        let back = box.region
        XCTAssertEqual(back.center.latitude, 10, accuracy: 1e-9)
        XCTAssertEqual(back.center.longitude, 20, accuracy: 1e-9)
        XCTAssertEqual(back.span.latitudeDelta, 2, accuracy: 1e-9)
        XCTAssertEqual(back.span.longitudeDelta, 4, accuracy: 1e-9)
    }

    func testBoundingBoxIsClampedToValidCoordinates() {
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 89.5, longitude: 179.5),
                                        span: MKCoordinateSpan(latitudeDelta: 4, longitudeDelta: 4))
        let box = BoundingBox(region: region)
        XCTAssertEqual(box.maxLatitude, 90, accuracy: 1e-9)
        XCTAssertEqual(box.maxLongitude, 180, accuracy: 1e-9)
        XCTAssertEqual(box.minLatitude, 87.5, accuracy: 1e-9)
    }

    func testRegionFittingContainsEveryCoordinateWithPadding() throws {
        let coordinates = [point(0, 0), point(800, 600), point(-200, 100)]
        let region = try XCTUnwrap(MKCoordinateRegion(fitting: coordinates, paddingFactor: 1.3))
        let box = BoundingBox(region: region)
        for coordinate in coordinates {
            XCTAssertTrue(box.contains(coordinate), "\(coordinate)")
        }
        let raw = try XCTUnwrap(BoundingBox(coordinates: coordinates))
        XCTAssertEqual(region.span.latitudeDelta, (raw.maxLatitude - raw.minLatitude) * 1.3, accuracy: 1e-9)
        XCTAssertEqual(region.center.latitude, raw.center.latitude, accuracy: 1e-9)
    }

    func testRegionFittingASinglePointUsesTheMinimumSpan() throws {
        let region = try XCTUnwrap(MKCoordinateRegion(fitting: [origin], minimumSpanMeters: 300))
        XCTAssertEqual(region.span.latitudeDelta * GeoMath.metersPerDegreeLatitude, 300, accuracy: 0.5)
        XCTAssertEqual(region.center.latitude, origin.latitude, accuracy: 1e-9)
    }

    func testRegionFittingNothingIsNil() {
        XCTAssertNil(MKCoordinateRegion(fitting: []))
        XCTAssertNil(MKCoordinateRegion(fitting: [GeoCoordinate(latitude: .nan, longitude: 0)]))
    }

    func testCameraPositions() throws {
        let fitted = try XCTUnwrap(MapCameraPosition.fitting([point(0, 0), point(500, 500)]))
        let region = try XCTUnwrap(fitted.region)
        XCTAssertTrue(BoundingBox(region: region).contains(point(500, 500)))
        XCTAssertNil(MapCameraPosition.fitting([]))

        let centered = MapCameraPosition.centered(on: origin, spanMeters: 1_000)
        let centeredRegion = try XCTUnwrap(centered.region)
        XCTAssertEqual(centeredRegion.center.latitude, origin.latitude, accuracy: 1e-9)
        XCTAssertEqual(centeredRegion.center.longitude, origin.longitude, accuracy: 1e-9)

        let following = MapCameraPosition.following(origin, heading: 90)
        let camera = try XCTUnwrap(following.camera)
        XCTAssertEqual(camera.heading, 90, accuracy: 1e-9)
        XCTAssertEqual(camera.centerCoordinate.latitude, origin.latitude, accuracy: 1e-9)
    }

    func testPolylineCoordinateList() {
        let coordinates = [CLLocationCoordinate2D(latitude: 1, longitude: 2),
                           CLLocationCoordinate2D(latitude: 3, longitude: 4),
                           CLLocationCoordinate2D(latitude: 5, longitude: 6)]
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let list = polyline.coordinateList
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[2].latitude, 5, accuracy: 1e-9)
        XCTAssertEqual(list[2].longitude, 6, accuracy: 1e-9)
    }
}
