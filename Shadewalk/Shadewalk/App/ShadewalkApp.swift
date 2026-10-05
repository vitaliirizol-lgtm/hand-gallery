import SwiftData
import SwiftUI

@main
@MainActor
struct ShadewalkApp: App {
    @State private var environment: AppEnvironment

    init() {
        _environment = State(initialValue: AppEnvironment.live())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .shadewalkEnvironment(environment)
        }
        .modelContainer(for: SavedPlace.self)
    }
}
