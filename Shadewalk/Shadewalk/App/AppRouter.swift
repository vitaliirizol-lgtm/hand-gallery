import Foundation
import Observation
import ShadeFeatures

/// Top-level tabs.
enum AppTab: String, Hashable, CaseIterable, Identifiable, Sendable {
    case walk, seatSide, saved, settings

    var id: String { rawValue }
}

/// Cross-tab navigation: the selected tab and a destination handed to the Walk tab (e.g. from Saved or a cool spot).
@MainActor @Observable
final class AppRouter {
    /// Tab shown by `RootView`.
    var selectedTab: AppTab
    /// Destination the Walk tab should plan to next; the Walk screen consumes it with `takePendingDestination()`.
    var pendingDestination: Place?

    init(selectedTab: AppTab = .walk) {
        self.selectedTab = selectedTab
    }

    /// Switches to the Walk tab and asks it to plan a route to `place`.
    func planRoute(to place: Place) {
        pendingDestination = place
        selectedTab = .walk
    }

    /// Returns and clears the pending destination.
    @discardableResult
    func takePendingDestination() -> Place? {
        let place = pendingDestination
        pendingDestination = nil
        return place
    }
}
