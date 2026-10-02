import XCTest
@testable import ShadeFeatures

final class ShadeFeaturesSmokeTests: XCTestCase {
    func testModuleLinks() {
        XCTAssertEqual(RoutingPreferences.default.maxDetourFraction, 0.25)
    }
}
