import XCTest
@testable import ShadeFeatures

final class CoolSpotsModelTests: XCTestCase {
    private static let spots = [
        CoolSpot(id: 1, kind: .park, name: "Park", coordinate: Fixtures.point(300, 0)),
        CoolSpot(id: 2, kind: .drinkingWater, name: "Fountain", coordinate: Fixtures.point(50, 0)),
        CoolSpot(id: 3, kind: .indoorCool, name: "Library", coordinate: Fixtures.point(0, 120)),
        CoolSpot(id: 4, kind: .shelter, name: nil, coordinate: Fixtures.point(-500, 0)),
        CoolSpot(id: 5, kind: .drinkingWater, name: nil, coordinate: Fixtures.point(0, -50)),
    ]

    @MainActor func testLoadSortsByDistanceWithPrecomputedDistances() async {
        let provider = FakeCoolSpotProvider { _, _ in Self.spots }
        let model = CoolSpotsModel(provider: provider)
        await model.load(near: Fixtures.origin, radius: 800)

        XCTAssertEqual(provider.recorder.requests.first?.radius, 800)
        XCTAssertEqual(provider.recorder.requests.first?.coordinate, Fixtures.origin)
        XCTAssertEqual(model.reference, Fixtures.origin)
        XCTAssertEqual(model.state.value?.count, 5)
        // 50 m ties are ordered by id.
        XCTAssertEqual(model.items.map(\.id), [2, 5, 3, 1, 4])
        XCTAssertEqual(model.items[0].distance, 50, accuracy: 0.5)
        XCTAssertEqual(model.items[2].distance, 120, accuracy: 0.5)
        XCTAssertEqual(model.items.last?.distance ?? 0, 500, accuracy: 0.5)
        XCTAssertEqual(model.allItems, model.items)
        XCTAssertEqual(model.count(of: .drinkingWater), 2)
    }

    @MainActor func testFiltersDefaultToAllAndToggle() async {
        let model = CoolSpotsModel(provider: FakeCoolSpotProvider { _, _ in Self.spots })
        XCTAssertEqual(model.filters, Set(CoolSpotKind.allCases))
        await model.load(near: Fixtures.origin)
        XCTAssertEqual(model.items.count, 5)

        model.toggle(.drinkingWater)
        XCTAssertFalse(model.isShowing(.drinkingWater))
        XCTAssertEqual(model.items.map(\.id), [3, 1, 4])
        model.filters = [.park]
        XCTAssertEqual(model.items.map(\.id), [1])
        XCTAssertEqual(model.allItems.count, 5)
        model.toggle(.drinkingWater)
        XCTAssertEqual(model.items.map(\.id), [2, 5, 1])
        model.filters = []
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor func testUpdateReferenceResorts() async {
        let model = CoolSpotsModel(provider: FakeCoolSpotProvider { _, _ in Self.spots })
        await model.load(near: Fixtures.origin)
        model.updateReference(Fixtures.point(-480, 0))
        XCTAssertEqual(model.items.first?.id, 4)
        XCTAssertEqual(model.items.first?.distance ?? 0, 20, accuracy: 0.5)
    }

    @MainActor func testErrorsMapToFailedState() async {
        let model = CoolSpotsModel(provider: FakeCoolSpotProvider { _, _ in throw ShadeError.networkUnavailable })
        await model.load(near: Fixtures.origin)
        XCTAssertEqual(model.state, .failed(message: ShadeError.networkUnavailable.errorDescription ?? "",
                                            error: .networkUnavailable))
        XCTAssertTrue(model.items.isEmpty)
    }

    @MainActor func testStaleLoadIsIgnored() async {
        let gate = AsyncGate()
        let provider = FakeCoolSpotProvider { _, index in
            if index == 0 {
                await gate.wait()
                return [CoolSpot(id: 99, kind: .park, name: "Old", coordinate: Fixtures.point(1, 1))]
            }
            return Self.spots
        }
        let model = CoolSpotsModel(provider: provider)
        let first = Task { await model.load(near: Fixtures.point(5000, 0)) }
        await waitUntil { provider.recorder.callCount == 1 }
        await model.load(near: Fixtures.origin)
        XCTAssertEqual(model.items.count, 5)
        await gate.open()
        await first.value
        XCTAssertEqual(model.items.count, 5)
        XCTAssertFalse(model.items.contains { $0.id == 99 })
        XCTAssertEqual(model.reference, Fixtures.origin)
    }
}
