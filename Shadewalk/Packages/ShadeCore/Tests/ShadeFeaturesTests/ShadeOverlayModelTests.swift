import XCTest
@testable import ShadeFeatures

final class ShadeOverlayModelTests: XCTestCase {
    /// Box of `side` metres centred `(x, y)` metres from the fixture origin.
    private static func box(_ side: Double, x: Double = 0, y: Double = 0) -> BoundingBox {
        let h = side / 2
        return BoundingBox(coordinates: [Fixtures.point(x - h, y - h), Fixtures.point(x + h, y + h)])
            ?? BoundingBox(minLatitude: 0, minLongitude: 0, maxLatitude: 0, maxLongitude: 0)
    }

    @MainActor func testDisabledDoesNotFetch() async {
        let provider = FakeOverlayProvider()
        let model = ShadeOverlayModel(provider: provider, debounceInterval: 0)
        model.update(visible: Self.box(800), date: Fixtures.departure)
        await settle()
        XCTAssertEqual(provider.recorder.callCount, 0)
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.polygons.isEmpty)
    }

    @MainActor func testEnabledFetchesWithMargin() async {
        let provider = FakeOverlayProvider()
        let model = ShadeOverlayModel(provider: provider, isEnabled: true, debounceInterval: 0)
        let visible = Self.box(800)
        model.update(visible: visible, date: Fixtures.departure)
        XCTAssertEqual(model.state, .loading)
        await model.pendingTask?.value
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.polygons.count, 1)
        XCTAssertEqual(model.overlay?.date, Fixtures.departure)
        let request = provider.recorder.requests.first
        XCTAssertEqual(request?.date, Fixtures.departure)
        XCTAssertTrue(request?.bbox.contains(visible) ?? false)
        XCTAssertEqual(request?.bbox.widthMeters ?? 0, 800 * 1.3, accuracy: 2)
    }

    @MainActor func testTooZoomedOutClearsPolygons() async {
        let provider = FakeOverlayProvider()
        let model = ShadeOverlayModel(provider: provider, isEnabled: true, debounceInterval: 0)
        model.update(visible: Self.box(800), date: Fixtures.departure)
        await model.pendingTask?.value
        XCTAssertFalse(model.polygons.isEmpty)

        model.update(visible: Self.box(3000), date: Fixtures.departure)
        XCTAssertEqual(model.state, .tooZoomedOut)
        XCTAssertTrue(model.polygons.isEmpty)
        await settle()
        XCTAssertEqual(provider.recorder.callCount, 1)

        // Zooming back in loads again.
        model.update(visible: Self.box(800), date: Fixtures.departure)
        await model.pendingTask?.value
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(provider.recorder.callCount, 2)
    }

    @MainActor func testKeepsLastOverlayWhileLoadingAndIgnoresStaleResults() async {
        let gate = AsyncGate()
        let provider = FakeOverlayProvider { request, index in
            if index == 1 { await gate.wait() }
            return ShadeOverlay(polygons: Array(repeating: [request.bbox.center], count: index + 1), sun: Fixtures.sun,
                                date: request.date)
        }
        let model = ShadeOverlayModel(provider: provider, isEnabled: true, debounceInterval: 0)
        model.update(visible: Self.box(500), date: Fixtures.departure)
        await model.pendingTask?.value
        XCTAssertEqual(model.polygons.count, 1)

        // New time: the old overlay stays visible while the new one loads.
        let later = Fixtures.departure.addingTimeInterval(3600)
        model.update(visible: Self.box(500), date: later)
        await waitUntil { provider.recorder.callCount == 2 }
        XCTAssertEqual(model.state, .loading)
        XCTAssertEqual(model.polygons.count, 1)

        // A newer request supersedes the gated one.
        let evening = Fixtures.departure.addingTimeInterval(7200)
        model.update(visible: Self.box(500), date: evening)
        await model.pendingTask?.value
        XCTAssertEqual(model.polygons.count, 3)
        XCTAssertEqual(model.overlay?.date, evening)

        await gate.open()
        await waitUntil { provider.recorder.completedCount == 3 }
        await settle()
        XCTAssertEqual(model.polygons.count, 3)
        XCTAssertEqual(model.overlay?.date, evening)
        XCTAssertEqual(model.state, .ready)
    }

    @MainActor func testCoveredAreaIsNotRefetched() async {
        let provider = FakeOverlayProvider()
        let model = ShadeOverlayModel(provider: provider, isEnabled: true, debounceInterval: 0)
        model.update(visible: Self.box(800), date: Fixtures.departure)
        await model.pendingTask?.value
        // Small pan inside the fetched margin, same time (within tolerance).
        model.update(visible: Self.box(800, x: 50, y: -40), date: Fixtures.departure.addingTimeInterval(30))
        await settle()
        XCTAssertEqual(provider.recorder.callCount, 1)
        // Pan beyond the margin.
        model.update(visible: Self.box(800, x: 400), date: Fixtures.departure)
        await model.pendingTask?.value
        XCTAssertEqual(provider.recorder.callCount, 2)
    }

    @MainActor func testUpdatesAreDebounced() async {
        let provider = FakeOverlayProvider()
        let model = ShadeOverlayModel(provider: provider, isEnabled: true, debounceInterval: 0.02)
        for i in 0..<5 {
            model.update(visible: Self.box(600, x: Double(i) * 500), date: Fixtures.departure)
        }
        await model.pendingTask?.value
        XCTAssertEqual(provider.recorder.callCount, 1)
        XCTAssertTrue(provider.recorder.requests.first?.bbox.contains(Self.box(600, x: 2000)) ?? false)
    }

    @MainActor func testTogglingEnabled() async {
        let provider = FakeOverlayProvider()
        let model = ShadeOverlayModel(provider: provider, debounceInterval: 0)
        model.update(visible: Self.box(800), date: Fixtures.departure)
        model.isEnabled = true
        await model.pendingTask?.value
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(provider.recorder.callCount, 1)

        model.isEnabled = false
        XCTAssertEqual(model.state, .idle)
        XCTAssertTrue(model.polygons.isEmpty)

        model.isEnabled = true
        await model.pendingTask?.value
        XCTAssertEqual(provider.recorder.callCount, 2)
    }

    @MainActor func testFailureKeepsOverlayAndRetryReloads() async {
        let provider = FakeOverlayProvider { request, index in
            if index == 1 { throw ShadeError.networkUnavailable }
            return ShadeOverlay(polygons: [[request.bbox.center]], sun: Fixtures.sun, date: request.date)
        }
        let model = ShadeOverlayModel(provider: provider, isEnabled: true, debounceInterval: 0)
        model.update(visible: Self.box(800), date: Fixtures.departure)
        await model.pendingTask?.value
        model.update(visible: Self.box(800), date: Fixtures.departure.addingTimeInterval(3600))
        await model.pendingTask?.value
        XCTAssertEqual(model.state, .failed(message: ShadeError.networkUnavailable.errorDescription ?? ""))
        XCTAssertEqual(model.polygons.count, 1)

        model.retry()
        await model.pendingTask?.value
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.overlay?.date, Fixtures.departure.addingTimeInterval(3600))
    }
}
