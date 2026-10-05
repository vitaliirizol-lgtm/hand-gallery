import XCTest
@testable import ShadeFeatures

final class LocationModelTests: XCTestCase {
    @MainActor func testMirrorsProviderState() async {
        let provider = FakeLocationProvider()
        provider.lastFix = Fixtures.fix(10)
        let model = LocationModel(provider: provider)
        XCTAssertEqual(model.authorization, .notDetermined)
        XCTAssertTrue(model.canRequestAuthorization)
        XCTAssertEqual(model.coordinate, Fixtures.point(10))
        XCTAssertEqual(model.currentPlace?.kind, .currentLocation)

        model.requestAuthorization()
        XCTAssertEqual(provider.authorizationRequests, 1)
        XCTAssertEqual(model.authorization, .authorized)
        XCTAssertTrue(model.isAuthorized)

        provider.authorization = .denied
        model.refresh()
        XCTAssertEqual(model.authorization, .denied)
        XCTAssertFalse(model.isAuthorized)
    }

    @MainActor func testStreamsFixesUntilStopped() async {
        let provider = FakeLocationProvider()
        let model = LocationModel(provider: provider)
        model.startUpdates()
        model.startUpdates() // no second subscription
        XCTAssertTrue(model.isUpdating)
        XCTAssertEqual(provider.subscriptionCount, 1)

        provider.send(Fixtures.fix(20))
        await waitUntil { model.lastFix == Fixtures.fix(20) }
        provider.send(Fixtures.fix(30))
        await waitUntil { model.coordinate == Fixtures.point(30) }

        model.stopUpdates()
        XCTAssertFalse(model.isUpdating)
        await waitUntil { provider.terminationCount == 1 }
        provider.send(Fixtures.fix(40))
        await settle()
        XCTAssertEqual(model.coordinate, Fixtures.point(30))
    }

    @MainActor func testProviderEndingStreamStopsUpdating() async {
        let provider = FakeLocationProvider()
        let model = LocationModel(provider: provider)
        model.startUpdates()
        provider.authorization = .denied
        provider.finishAll()
        await waitUntil { !model.isUpdating }
        XCTAssertEqual(model.authorization, .denied)
        model.startUpdates()
        XCTAssertEqual(provider.subscriptionCount, 2)
    }
}
