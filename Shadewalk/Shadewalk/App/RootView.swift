import ShadeFeatures
import SwiftUI

/// Onboarding until it's completed, then the four tabs. Also forwards scene-phase changes to `AppEnvironment`.
struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .animation(transitionAnimation, value: settings.hasCompletedOnboarding)
            .onChange(of: scenePhase, initial: true) { _, phase in
                handle(phase)
            }
    }

    @ViewBuilder
    private var content: some View {
        if settings.hasCompletedOnboarding {
            MainTabView()
                .transition(.opacity)
        } else {
            OnboardingView()
                .transition(.opacity)
        }
    }

    private var transitionAnimation: Animation? {
        reduceMotion ? nil : Theme.spring
    }

    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .active:
            app.appDidBecomeActive()
        case .background:
            app.appDidEnterBackground()
        case .inactive:
            break
        @unknown default:
            break
        }
    }
}

/// The four top-level tabs; selection lives in `AppRouter`.
struct MainTabView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var tabRouter = router
        TabView(selection: $tabRouter.selectedTab) {
            WalkView()
                .tabItem { Label("Walk", systemImage: "figure.walk") }
                .tag(AppTab.walk)
            SeatSideView()
                .tabItem { Label("Seat side", systemImage: "bus.fill") }
                .tag(AppTab.seatSide)
            SavedView()
                .tabItem { Label("Saved", systemImage: "bookmark.fill") }
                .tag(AppTab.saved)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(Theme.shade)
    }
}

#if DEBUG
#Preview("Root") {
    RootView()
        .previewEnvironment()
}

#Preview("Root – onboarding") {
    RootView()
        .previewEnvironment(AppEnvironment.preview(onboarded: false))
}
#endif
