import Foundation
import ShadeFeatures

extension LocationModel {
    /// A fix older than this no longer stands for where the user is now (e.g. one from before the app was last in the
    /// foreground). While updates run, `CoreLocationProvider` delivers a fix at least every few seconds, even when the
    /// device stands still, so a current position is never older than this.
    static let currentFixMaxAge: TimeInterval = 120

    /// The latest coordinate when its fix is recent enough to be the user's current position ("My Location"); nil
    /// before the first fix and while the last one is stale.
    func currentCoordinate(now: Date = Date()) -> GeoCoordinate? {
        guard let fix = lastFix, abs(fix.timestamp.timeIntervalSince(now)) <= LocationModel.currentFixMaxAge else {
            return nil
        }
        return fix.coordinate
    }
}
