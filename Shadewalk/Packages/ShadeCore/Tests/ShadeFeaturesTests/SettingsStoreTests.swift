import XCTest
@testable import ShadeFeatures

final class SettingsStoreTests: XCTestCase {
    @MainActor func testDefaults() async {
        let settings = SettingsStore(store: InMemoryKeyValueStore())
        XCTAssertEqual(settings.walkingSpeed, .normal)
        XCTAssertEqual(settings.maxDetourFraction, 0.25)
        XCTAssertFalse(settings.avoidStairs)
        XCTAssertEqual(settings.units, .system)
        XCTAssertFalse(settings.showShadeOverlayByDefault)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertEqual(settings.routingPreferences, RoutingPreferences.default)
    }

    @MainActor func testWalkingSpeedPresets() async {
        XCTAssertEqual(WalkingSpeed.slow.metersPerSecond, 1.1)
        XCTAssertEqual(WalkingSpeed.normal.metersPerSecond, 1.35)
        XCTAssertEqual(WalkingSpeed.fast.metersPerSecond, 1.6)
    }

    @MainActor func testChangesPersistAndRoundTrip() async {
        let store = InMemoryKeyValueStore()
        let settings = SettingsStore(store: store)
        settings.walkingSpeed = .fast
        settings.maxDetourFraction = 0.4
        settings.avoidStairs = true
        settings.units = .imperial
        settings.showShadeOverlayByDefault = true
        settings.hasCompletedOnboarding = true
        XCTAssertNotNil(store.data(forKey: ShadeFeaturesStorageKeys.settings))

        let reloaded = SettingsStore(store: store)
        XCTAssertEqual(reloaded.settings, settings.settings)
        XCTAssertEqual(reloaded.walkingSpeed, .fast)
        XCTAssertEqual(reloaded.maxDetourFraction, 0.4)
        XCTAssertTrue(reloaded.avoidStairs)
        XCTAssertEqual(reloaded.units, .imperial)
        XCTAssertTrue(reloaded.showShadeOverlayByDefault)
        XCTAssertTrue(reloaded.hasCompletedOnboarding)
        XCTAssertEqual(reloaded.routingPreferences,
                       RoutingPreferences(walkingSpeed: 1.6, maxDetourFraction: 0.4, avoidStairs: true))
    }

    @MainActor func testDetourIsClamped() async {
        let settings = SettingsStore(store: InMemoryKeyValueStore())
        settings.maxDetourFraction = 0.9
        XCTAssertEqual(settings.maxDetourFraction, 0.5)
        settings.maxDetourFraction = -1
        XCTAssertEqual(settings.maxDetourFraction, 0)
        settings.maxDetourFraction = .nan
        XCTAssertEqual(settings.maxDetourFraction, 0.25)
        XCTAssertEqual(AppSettings(maxDetourFraction: 3).maxDetourFraction, 0.5)
    }

    @MainActor func testUnchangedValueDoesNotWrite() async {
        let store = InMemoryKeyValueStore()
        let settings = SettingsStore(store: store)
        settings.walkingSpeed = .normal
        XCTAssertNil(store.data(forKey: ShadeFeaturesStorageKeys.settings))
    }

    @MainActor func testCorruptDataFallsBackToDefaults() async {
        let store = InMemoryKeyValueStore()
        store.set(Data("not json".utf8), forKey: ShadeFeaturesStorageKeys.settings)
        XCTAssertEqual(SettingsStore(store: store).settings, AppSettings.default)
    }

    @MainActor func testPartialAndUnknownFieldsUseDefaults() async {
        let store = InMemoryKeyValueStore()
        let json = #"{"walkingSpeed":"sprint","avoidStairs":true,"maxDetourFraction":"lots","units":"metric"}"#
        store.set(Data(json.utf8), forKey: ShadeFeaturesStorageKeys.settings)
        let settings = SettingsStore(store: store)
        XCTAssertEqual(settings.walkingSpeed, .normal) // unknown preset
        XCTAssertEqual(settings.maxDetourFraction, 0.25) // wrong type
        XCTAssertTrue(settings.avoidStairs)
        XCTAssertEqual(settings.units, .metric)
        XCTAssertFalse(settings.hasCompletedOnboarding) // missing
    }

    @MainActor func testCustomKeyAndBatchUpdate() async {
        let store = InMemoryKeyValueStore()
        let settings = SettingsStore(store: store, key: "custom")
        settings.update {
            $0.walkingSpeed = .slow
            $0.avoidStairs = true
        }
        XCTAssertNil(store.data(forKey: ShadeFeaturesStorageKeys.settings))
        XCTAssertEqual(SettingsStore(store: store, key: "custom").walkingSpeed, .slow)
    }

    @MainActor func testResetKeepsOnboardingFlag() async {
        let store = InMemoryKeyValueStore()
        let settings = SettingsStore(store: store)
        settings.update {
            $0.walkingSpeed = .fast
            $0.hasCompletedOnboarding = true
            $0.units = .metric
        }
        settings.resetToDefaults()
        XCTAssertEqual(settings.walkingSpeed, .normal)
        XCTAssertEqual(settings.units, .system)
        XCTAssertTrue(settings.hasCompletedOnboarding)
        XCTAssertEqual(SettingsStore(store: store).settings, settings.settings)
    }
}

final class LoadStateTests: XCTestCase {
    func testAccessorsAndMapping() {
        let loaded: LoadState<Int> = .loaded(3)
        XCTAssertEqual(loaded.value, 3)
        XCTAssertEqual(loaded.map { $0 * 2 }, .loaded(6))
        XCTAssertFalse(loaded.isLoading)
        XCTAssertTrue(LoadState<Int>.loading.isLoading)
        XCTAssertTrue(LoadState<Int>.idle.isIdle)
        XCTAssertNil(LoadState<Int>.loading.value)
        XCTAssertEqual(LoadState<Int>.loading.map { $0 + 1 }, .loading)
    }

    func testFailureMapsShadeErrors() {
        let state = LoadState<Int>.failure(ShadeError.noRouteFound)
        XCTAssertTrue(state.isFailed)
        XCTAssertEqual(state.shadeError, .noRouteFound)
        XCTAssertEqual(state.errorMessage, ShadeError.noRouteFound.errorDescription)
        XCTAssertEqual(state, .failed(message: ShadeError.noRouteFound.errorDescription ?? "", error: .noRouteFound))
        XCTAssertEqual(state.map { "\($0)" }.shadeError, .noRouteFound)
    }

    func testFailureMapsOtherErrors() {
        let state = LoadState<Int>.failure(TestError(message: "Boom"))
        XCTAssertEqual(state, .failed(message: "Boom", error: nil))
        XCTAssertNil(state.shadeError)
        XCTAssertFalse(LoadState<Int>.failure(CancellationError()).errorMessage?.isEmpty ?? true)
    }
}
