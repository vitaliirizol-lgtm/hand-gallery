import Foundation
import ShadeFeatures
import XCTest
@testable import Shadewalk

final class FormattersTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let uk = Locale(identifier: "en_GB")
    private let de = Locale(identifier: "de_DE")

    /// ICU output may contain (narrow) no-break spaces; compare with plain spaces.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    // MARK: - Distance

    func testMetricDistances() {
        XCTAssertEqual(plain(Formatters.distance(850, units: .metric, locale: us)), "850 m")
        XCTAssertEqual(plain(Formatters.distance(847, units: .metric, locale: us)), "850 m")
        XCTAssertEqual(plain(Formatters.distance(42, units: .metric, locale: us)), "40 m")
        XCTAssertEqual(plain(Formatters.distance(1_412, units: .metric, locale: us)), "1.4 km")
        XCTAssertEqual(plain(Formatters.distance(998, units: .metric, locale: us)), "1 km")
        XCTAssertEqual(plain(Formatters.distance(12_300, units: .metric, locale: us)), "12 km")
    }

    func testDistanceUsesLocaleDecimalSeparator() {
        XCTAssertEqual(plain(Formatters.distance(1_412, units: .metric, locale: de)), "1,4 km")
    }

    func testImperialDistances() {
        XCTAssertEqual(plain(Formatters.distance(1_448, units: .imperial, locale: us)), "0.9 mi")
        XCTAssertEqual(plain(Formatters.distance(100, units: .imperial, locale: us)), "330 ft")
    }

    func testInvalidDistancesFormatAsZero() {
        XCTAssertEqual(plain(Formatters.distance(.nan, units: .metric, locale: us)), "0 m")
        XCTAssertEqual(plain(Formatters.distance(-20, units: .metric, locale: us)), "0 m")
    }

    func testSystemUnitsFollowTheLocale() {
        XCTAssertTrue(Formatters.usesMetricDistances(.system, locale: de))
        XCTAssertFalse(Formatters.usesMetricDistances(.system, locale: us))
        XCTAssertFalse(Formatters.usesMetricDistances(.system, locale: uk))
        XCTAssertTrue(Formatters.usesMetricDistances(.metric, locale: us))
        XCTAssertFalse(Formatters.usesMetricDistances(.imperial, locale: de))
        XCTAssertTrue(Formatters.usesFahrenheit(.system, locale: us))
        XCTAssertFalse(Formatters.usesFahrenheit(.system, locale: uk))
        XCTAssertFalse(Formatters.usesFahrenheit(.system, locale: de))
    }

    func testElevation() {
        XCTAssertEqual(plain(Formatters.elevation(12.4, units: .metric, locale: us)), "12 m")
        XCTAssertEqual(plain(Formatters.elevation(12.2, units: .imperial, locale: us)), "40 ft")
    }

    // MARK: - Time

    func testDurations() {
        XCTAssertEqual(Formatters.duration(18 * 60, locale: us), "18 min")
        XCTAssertEqual(Formatters.duration(18 * 60 + 20, locale: us), "18 min")
        XCTAssertEqual(Formatters.duration(65 * 60, locale: us), "1 h 05 min")
        XCTAssertEqual(Formatters.duration(2 * 3_600 + 30 * 60, locale: us), "2 h 30 min")
        XCTAssertEqual(Formatters.duration(20, locale: us), "1 min")
        XCTAssertEqual(Formatters.duration(0, locale: us), "0 min")
        XCTAssertEqual(Formatters.duration(.infinity, locale: us), "0 min")
    }

    func testClockTime() {
        let date = Date(timeIntervalSince1970: 15 * 3_600 + 5 * 60)
        XCTAssertEqual(plain(Formatters.clockTime(date, locale: us, timeZone: .gmt)), "3:05 PM")
        XCTAssertEqual(plain(Formatters.clockTime(date, locale: de, timeZone: .gmt)), "15:05")
    }

    // MARK: - Counts & ratios

    func testStepsUseLocaleGrouping() {
        XCTAssertEqual(plain(Formatters.steps(1_898, locale: us)), "1,898 steps")
        XCTAssertEqual(plain(Formatters.steps(-3, locale: us)), "0 steps")
    }

    func testPercent() {
        XCTAssertEqual(plain(Formatters.percent(0.62, locale: us)), "62%")
        XCTAssertEqual(plain(Formatters.percent(1.4, locale: us)), "100%")
        XCTAssertEqual(plain(Formatters.percent(-0.2, locale: us)), "0%")
        XCTAssertEqual(Formatters.percentValue(0.616), 62)
        XCTAssertEqual(Formatters.percentValue(.nan), 0)
    }

    // MARK: - Weather

    func testTemperature() {
        XCTAssertEqual(plain(Formatters.temperature(31.4, units: .metric, locale: us)), "31°C")
        XCTAssertEqual(plain(Formatters.temperature(31.4, units: .imperial, locale: us)), "89°F")
        XCTAssertEqual(plain(Formatters.temperature(31.4, units: .metric, locale: us, showsUnit: false)), "31°")
        XCTAssertEqual(plain(Formatters.temperature(-0.3, units: .metric, locale: us)), "0°C")
    }

    func testUVIndex() {
        XCTAssertEqual(Formatters.uvIndex(7.6), 8)
        XCTAssertEqual(Formatters.uvIndex(-1), 0)
        XCTAssertEqual(Formatters.uvIndex(.nan), 0)
    }

    // MARK: - Errors & display names

    func testEveryShadeErrorHasAMessage() {
        let errors: [ShadeError] = [
            .tooFar(distance: 6_200, limit: 5_000), .originTooFarFromNetwork, .destinationTooFarFromNetwork,
            .noRouteFound, .noWalkableNetwork, .networkUnavailable, .badResponse(status: 503),
            .decodingFailed("detail"), .cancelled,
        ]
        for error in errors {
            XCTAssertFalse(error.localizedMessage.isEmpty, "\(error)")
            XCTAssertFalse(error.systemImage.isEmpty, "\(error)")
        }
        XCTAssertEqual(ShadeError.badResponse(status: 503).localizedMessage,
                       "The map data server returned an error (503).")
        XCTAssertTrue(plain(ShadeError.tooFar(distance: 6_200, limit: 5_000).localizedMessage(units: .metric))
            .contains("6.2 km"))
        XCTAssertTrue(ShadeError.networkUnavailable.isRetryable)
        XCTAssertFalse(ShadeError.tooFar(distance: 6_200, limit: 5_000).isRetryable)
    }

    func testErrorText() {
        XCTAssertEqual(ErrorText.message(for: ShadeError.noRouteFound), ShadeError.noRouteFound.localizedMessage)
        XCTAssertEqual(ErrorText.message(for: CancellationError()), ShadeError.cancelled.localizedMessage)
        XCTAssertFalse(ErrorText.message(for: URLError(.notConnectedToInternet)).isEmpty)
    }

    func testLoadStateDisplayHelpers() {
        let failed: LoadState<Int> = .failure(ShadeError.noRouteFound)
        XCTAssertEqual(failed.localizedErrorMessage, ShadeError.noRouteFound.localizedMessage)
        XCTAssertFalse(failed.isRetryableFailure)
        let offline: LoadState<Int> = .failure(ShadeError.networkUnavailable)
        XCTAssertTrue(offline.isRetryableFailure)
        let loaded: LoadState<Int> = .loaded(1)
        XCTAssertNil(loaded.localizedErrorMessage)
        XCTAssertFalse(loaded.isRetryableFailure)
    }

    func testDisplayNames() {
        XCTAssertEqual(RouteProfile.allCases.map(\.displayName), ["Shadiest", "Balanced", "Fastest"])
        XCTAssertEqual(CoolSpotKind.park.systemImage, "tree.fill")
        XCTAssertEqual(VehicleKind.train.systemImage, "train.side.front.car")
        XCTAssertEqual(ManeuverKind.left.systemImage, "arrow.turn.up.left")
        let turn = Maneuver(kind: .left, streetName: "Linden Avenue", distanceFromStart: 80,
                            coordinate: GeoCoordinate(latitude: 0, longitude: 0))
        XCTAssertEqual(turn.instruction, "Turn left onto Linden Avenue")
        let unnamed = Maneuver(kind: .right, streetName: "  ", distanceFromStart: 80,
                               coordinate: GeoCoordinate(latitude: 0, longitude: 0))
        XCTAssertEqual(unnamed.instruction, "Turn right")
        let here = Place.localizedCurrentLocation(GeoCoordinate(latitude: 1, longitude: 2))
        XCTAssertEqual(here.displayName, "My Location")
        XCTAssertEqual(here.kind, .currentLocation)
    }
}
