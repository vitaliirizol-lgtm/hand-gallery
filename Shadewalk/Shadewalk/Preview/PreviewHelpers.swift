#if DEBUG
import ShadeFeatures
import SwiftData
import SwiftUI

@MainActor
extension View {
    /// Preview wiring: injects `environment` (default `AppEnvironment.preview()`) and an in-memory SwiftData container
    /// seeded with sample saved places.
    ///
    ///     #if DEBUG
    ///     #Preview { WalkView().previewEnvironment() }
    ///     #endif
    func previewEnvironment(_ environment: AppEnvironment? = nil, seedsSavedPlaces: Bool = true) -> some View {
        shadewalkEnvironment(environment ?? AppEnvironment.preview())
            .modelContainer(for: SavedPlace.self, inMemory: true) { result in
                guard seedsSavedPlaces, case let .success(container) = result else { return }
                // SwiftUI calls this on the main thread.
                MainActor.assumeIsolated {
                    PreviewData.seedSavedPlaces(in: container.mainContext)
                }
            }
    }
}

extension PreviewData {
    /// Home, Work and one favorite.
    @MainActor
    static func seedSavedPlaces(in context: ModelContext) {
        let home = Place(id: "preview-home", name: "Home", subtitle: "Cedar Lane 12", coordinate: point(-380, -240))
        let work = Place(id: "preview-work", name: "Studio", subtitle: "Market Row 5", coordinate: point(540, 420))
        context.insert(SavedPlace(place: home, kind: .home, createdAt: referenceDate))
        context.insert(SavedPlace(place: work, kind: .work, createdAt: referenceDate))
        context.insert(SavedPlace(place: destinationPlace, kind: .favorite, createdAt: referenceDate))
    }
}
#endif
