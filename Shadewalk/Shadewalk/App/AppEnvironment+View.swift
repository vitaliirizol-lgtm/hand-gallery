import ShadeFeatures
import SwiftUI

extension View {
    /// Injects the environment and every model so views can read them with `@Environment(Type.self)`:
    /// `AppEnvironment`, `SettingsStore`, `LocationModel`, `RoutePlannerModel`, `SearchModel`, `NavigationModel`,
    /// `CoolSpotsModel`, `SeatSideModel`, `WeatherModel`, `ShadeOverlayModel`, `DepartureTimeModel`, `AppRouter`.
    @MainActor
    func shadewalkEnvironment(_ environment: AppEnvironment) -> some View {
        self
            .environment(environment)
            .environment(environment.settings)
            .environment(environment.location)
            .environment(environment.planner)
            .environment(environment.search)
            .environment(environment.navigation)
            .environment(environment.coolSpots)
            .environment(environment.seatSide)
            .environment(environment.weather)
            .environment(environment.shadeOverlay)
            .environment(environment.departureTime)
            .environment(environment.router)
            .tint(Theme.shade)
    }
}
