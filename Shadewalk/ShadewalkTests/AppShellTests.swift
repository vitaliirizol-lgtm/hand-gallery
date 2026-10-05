import Foundation
import ShadeFeatures
import SwiftData
import XCTest
@testable import Shadewalk

final class AppShellTests: XCTestCase {
    @MainActor
    func testRouterPlansRouteOnTheWalkTab() async {
        let router = AppRouter(selectedTab: .saved)
        let place = Place(id: "p", name: "Library", coordinate: GeoCoordinate(latitude: 1, longitude: 2))
        router.planRoute(to: place)
        XCTAssertEqual(router.selectedTab, .walk)
        XCTAssertEqual(router.takePendingDestination(), place)
        XCTAssertNil(router.pendingDestination)
    }

    @MainActor
    func testSavedPlaceRoundTrips() async throws {
        let container = try ModelContainer(for: SavedPlace.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let place = Place(id: "a", name: "Old Mill", subtitle: "Elm Street",
                          coordinate: GeoCoordinate(latitude: 10, longitude: 20))
        context.insert(SavedPlace(place: place, kind: .home))
        try context.save()

        let saved = try context.fetch(FetchDescriptor<SavedPlace>())
        XCTAssertEqual(saved.count, 1)
        let home = try XCTUnwrap(saved.first)
        XCTAssertEqual(home.id, "saved-home")
        XCTAssertEqual(home.kind, .home)
        XCTAssertEqual(home.place.kind, .home)
        XCTAssertEqual(home.place.name, "Old Mill")
        XCTAssertEqual(home.place.subtitle, "Elm Street")
        XCTAssertEqual(home.coordinate, GeoCoordinate(latitude: 10, longitude: 20))
    }

    func testSavedPlaceIdentifiers() {
        let place = Place(id: "a", name: "Old Mill", coordinate: GeoCoordinate(latitude: 10, longitude: 20))
        // Home and Work have fixed ids, so saving a new Home replaces the old one (unique id).
        XCTAssertEqual(SavedPlace.identifier(for: place, kind: .home), "saved-home")
        XCTAssertEqual(SavedPlace.identifier(for: place, kind: .work), "saved-work")
        XCTAssertEqual(SavedPlace.identifier(for: place, kind: .favorite), "saved-a")
        let resaved = Place(id: "saved-a", name: "Old Mill", coordinate: place.coordinate)
        XCTAssertEqual(SavedPlace.identifier(for: resaved, kind: .favorite), "saved-a")
        XCTAssertEqual(SavedPlaceKind.allCases.map(\.sortRank), [0, 1, 2])
    }

    func testShadeBarPartsMergeRunsAndNormalise() {
        let segments = [
            RouteSegment(coordinates: [], length: 100, isShaded: true),
            RouteSegment(coordinates: [], length: 100, isShaded: true),
            RouteSegment(coordinates: [], length: 0.5, isShaded: false),
            RouteSegment(coordinates: [], length: 200, isShaded: false),
            RouteSegment(coordinates: [], length: 0, isShaded: true),
        ]
        let parts = ShadeBarPart.parts(from: segments)
        XCTAssertEqual(parts.map(\.isShaded), [true, false])
        XCTAssertEqual(parts[0].fraction, 200 / 400.5, accuracy: 1e-9)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
        XCTAssertTrue(ShadeBarPart.parts(from: []).isEmpty)
    }
}
