import XCTest
@testable import ShadeFeatures

final class SearchModelTests: XCTestCase {
    @MainActor private func makeModel(_ search: FakePlaceSearch, store: KeyValueStore = InMemoryKeyValueStore())
        -> SearchModel {
        SearchModel(search: search, store: store, debounceInterval: 0)
    }

    @MainActor func testShortQueriesDoNotSearch() async {
        let search = FakePlaceSearch()
        let model = makeModel(search)
        model.query = "c"
        model.query = "  c  "
        await settle()
        XCTAssertTrue(search.queries.isEmpty)
        XCTAssertTrue(model.results.isIdle)
        await model.searchNow()
        XCTAssertTrue(search.queries.isEmpty)
    }

    @MainActor func testQueryLoadsSuggestions() async {
        let search = FakePlaceSearch()
        let model = makeModel(search)
        model.searchCenter = Fixtures.origin
        model.query = " cafe "
        XCTAssertTrue(model.results.isLoading)
        await model.pendingTask?.value
        XCTAssertEqual(search.queries, ["cafe"])
        XCTAssertEqual(search.nearCoordinates.first ?? nil, Fixtures.origin)
        XCTAssertEqual(model.suggestions.map(\.title), ["Cafe"])
        XCTAssertEqual(model.results, .loaded([PlaceSuggestion(id: "cafe", title: "Cafe", subtitle: "Seoul")]))
    }

    @MainActor func testTypingIsDebouncedToTheLastQuery() async {
        let search = FakePlaceSearch()
        let model = makeModel(search)
        model.query = "ca"
        model.query = "caf"
        model.query = "cafe"
        await model.pendingTask?.value
        await settle()
        XCTAssertEqual(search.queries, ["cafe"])
    }

    @MainActor func testRealDebounceDelaysLookup() async {
        let search = FakePlaceSearch()
        let model = SearchModel(search: search, store: InMemoryKeyValueStore(), debounceInterval: 0.03)
        model.query = "park"
        await Task.yield()
        XCTAssertTrue(search.queries.isEmpty)
        await model.pendingTask?.value
        XCTAssertEqual(search.queries, ["park"])
    }

    @MainActor func testStaleSuggestionsAreIgnored() async {
        let gate = AsyncGate()
        let search = FakePlaceSearch(suggestions: { query, index in
            if index == 0 { await gate.wait() }
            return [PlaceSuggestion(id: query, title: query, subtitle: "")]
        })
        let model = makeModel(search)
        model.query = "lib"
        await waitUntil { search.queries.count == 1 }
        model.query = "library"
        await model.pendingTask?.value
        XCTAssertEqual(model.suggestions.map(\.id), ["library"])
        await gate.open()
        await waitUntil { search.completedQueries == 2 }
        await settle()
        XCTAssertEqual(model.suggestions.map(\.id), ["library"])
    }

    @MainActor func testClearingQueryDropsInFlightResults() async {
        let gate = AsyncGate()
        let search = FakePlaceSearch(suggestions: { query, _ in
            await gate.wait()
            return [PlaceSuggestion(id: query, title: query, subtitle: "")]
        })
        let model = makeModel(search)
        model.query = "museum"
        await waitUntil { search.queries.count == 1 }
        model.clear()
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.results.isIdle)
        await gate.open()
        await waitUntil { search.completedQueries == 1 }
        await settle()
        XCTAssertTrue(model.results.isIdle)
    }

    @MainActor func testErrorsMapToFailedState() async {
        let search = FakePlaceSearch(suggestions: { _, _ in throw TestError(message: "No connection") })
        let model = makeModel(search)
        model.query = "station"
        await model.pendingTask?.value
        XCTAssertEqual(model.results, .failed(message: "No connection", error: nil))
        XCTAssertTrue(model.suggestions.isEmpty)
    }

    @MainActor func testResolveAddsToRecents() async throws {
        let search = FakePlaceSearch()
        let model = makeModel(search)
        let place = try await model.resolve(PlaceSuggestion(id: "p1", title: "Park", subtitle: "Seoul"))
        XCTAssertEqual(place.id, "p1")
        XCTAssertEqual(model.recents.map(\.id), ["p1"])
        XCTAssertFalse(model.isResolving)
    }

    @MainActor func testResolveFailurePropagatesAndKeepsRecents() async {
        let search = FakePlaceSearch(resolve: { _ in throw ShadeError.noRouteFound })
        let model = makeModel(search)
        do {
            _ = try await model.resolve(PlaceSuggestion(id: "x", title: "X", subtitle: ""))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? ShadeError, .noRouteFound)
        }
        XCTAssertTrue(model.recents.isEmpty)
        XCTAssertFalse(model.isResolving)
    }

    @MainActor func testRecentsDedupeOrderAndCap() async {
        let model = makeModel(FakePlaceSearch())
        for i in 0..<12 { model.addRecent(Fixtures.place("p\(i)", Double(i), 0)) }
        XCTAssertEqual(model.recents.count, SearchModel.maxRecents)
        XCTAssertEqual(model.recents.first?.id, "p11")
        XCTAssertEqual(model.recents.last?.id, "p2")

        model.addRecent(Fixtures.place("p5", 99, 99))
        XCTAssertEqual(model.recents.first?.id, "p5")
        XCTAssertEqual(model.recents.first?.coordinate, Fixtures.point(99, 99))
        XCTAssertEqual(model.recents.filter { $0.id == "p5" }.count, 1)
        XCTAssertEqual(model.recents.count, 10)

        model.addRecent(Place.currentLocation(Fixtures.origin))
        XCTAssertNotEqual(model.recents.first?.kind, .currentLocation)

        model.removeRecent(id: "p5")
        XCTAssertFalse(model.recents.contains { $0.id == "p5" })
        model.clearRecents()
        XCTAssertTrue(model.recents.isEmpty)
    }

    @MainActor func testRecentsPersistAcrossInstances() async {
        let store = InMemoryKeyValueStore()
        let model = makeModel(FakePlaceSearch(), store: store)
        model.addRecent(Fixtures.place("a"))
        model.addRecent(Fixtures.place("b"))
        let reloaded = makeModel(FakePlaceSearch(), store: store)
        XCTAssertEqual(reloaded.recents.map(\.id), ["b", "a"])
        XCTAssertEqual(reloaded.recents, model.recents)
    }

    @MainActor func testCorruptOrOversizedRecentsAreSanitized() async throws {
        let store = InMemoryKeyValueStore()
        store.set(Data("{oops".utf8), forKey: ShadeFeaturesStorageKeys.recentPlaces)
        XCTAssertTrue(makeModel(FakePlaceSearch(), store: store).recents.isEmpty)

        let stored = (0..<15).map { Fixtures.place("p\($0 % 12)") }
        store.set(try JSONEncoder().encode(stored), forKey: ShadeFeaturesStorageKeys.recentPlaces)
        let model = makeModel(FakePlaceSearch(), store: store)
        XCTAssertEqual(model.recents.count, 10)
        XCTAssertEqual(Set(model.recents.map(\.id)).count, 10)
    }
}
