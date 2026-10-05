import ShadeFeatures
import SwiftData
import SwiftUI

/// Saved tab (SPEC F9): Home & Work, favorites (SwiftData) and recent searches. Tapping any place plans a shady walk
/// there on the Walk tab.
struct SavedView: View {
    @Environment(AppEnvironment.self) private var app
    @Environment(AppRouter.self) private var router
    @Environment(SearchModel.self) private var search
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(filter: #Predicate<SavedPlace> { saved in saved.kindRaw == "favorite" },
           sort: \SavedPlace.createdAt, order: .reverse)
    private var favorites: [SavedPlace]

    @Query(filter: #Predicate<SavedPlace> { saved in saved.kindRaw != "favorite" },
           sort: \SavedPlace.createdAt, order: .reverse)
    private var anchors: [SavedPlace]

    @State private var pickingKind: SavedPlaceKind?
    @State private var renamingPlace: SavedPlace?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                if isEmpty {
                    emptySection
                }
                anchorsSection
                if !isEmpty {
                    favoritesSection
                }
                recentsSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .navigationTitle("Saved")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        pickingKind = .favorite
                    } label: {
                        Label("Add a favorite", systemImage: "plus")
                    }
                }
            }
            .sheet(item: $pickingKind) { kind in
                PlaceSearchView(title: kind.searchTitle, allowsCurrentLocation: true) { place in
                    save(place, as: kind)
                }
            }
            .alert("Rename place", isPresented: isRenaming) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    commitRename()
                }
                Button("Cancel", role: .cancel) {
                    renamingPlace = nil
                }
            } message: {
                Text("Choose a name you’ll recognize at a glance.")
            }
        }
    }

    // MARK: - Sections

    private var isEmpty: Bool {
        favorites.isEmpty && anchors.isEmpty && search.recents.isEmpty
    }

    private var emptySection: some View {
        Section {
            EmptyStateView(systemImage: "bookmark",
                           title: "Your places, one tap away",
                           message: "Save Home, Work and favorite spots, then tap one to plan a shady walk there.",
                           actionTitle: "Add a favorite") {
                pickingKind = .favorite
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var anchorsSection: some View {
        Section {
            anchorRow(.home)
            anchorRow(.work)
        } header: {
            Text("Home & Work")
        }
        .listRowBackground(Theme.surface)
    }

    private var favoritesSection: some View {
        Section {
            if favorites.isEmpty {
                Button {
                    pickingKind = .favorite
                } label: {
                    SavedPlaceLabel(title: String(localized: "Add a favorite"),
                                    subtitle: String(localized: "Places you walk to often"),
                                    systemImage: "star", tint: Theme.inkSecondary, accessory: .add)
                }
                .buttonStyle(.plain)
            } else {
                ForEach(favorites) { saved in
                    favoriteRow(saved)
                }
            }
        } header: {
            Text("Favorites")
        } footer: {
            if !favorites.isEmpty {
                Text("Tap a place to plan a shady walk there. Touch and hold for more options.")
            }
        }
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder
    private var recentsSection: some View {
        if !search.recents.isEmpty {
            Section {
                ForEach(search.recents) { place in
                    recentRow(place)
                }
            } header: {
                HStack {
                    Text("Recent searches")
                    Spacer()
                    Button("Clear") {
                        withMotionAwareAnimation(reduceMotion: reduceMotion) {
                            search.clearRecents()
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .textCase(nil)
                    .accessibilityLabel(Text("Clear recent searches"))
                }
            }
            .listRowBackground(Theme.surface)
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func anchorRow(_ kind: SavedPlaceKind) -> some View {
        if let saved = anchor(kind) {
            Button {
                router.planRoute(to: saved.place)
            } label: {
                SavedPlaceLabel(title: kind.displayName, subtitle: saved.name, systemImage: kind.systemImage,
                                tint: kind.placeKind.tint, accessory: .walk)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Plans a shady walk there"))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    delete(saved)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                Button {
                    pickingKind = kind
                } label: {
                    Label("Change", systemImage: "pencil")
                }
                .tint(Theme.shade)
            }
            .contextMenu {
                Button {
                    router.planRoute(to: saved.place)
                } label: {
                    Label("Plan a shady walk", systemImage: "figure.walk")
                }
                Button {
                    pickingKind = kind
                } label: {
                    Label("Change address", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    delete(saved)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
        } else {
            Button {
                pickingKind = kind
            } label: {
                SavedPlaceLabel(title: kind.setTitle,
                                subtitle: String(localized: "Add an address for one-tap walks"),
                                systemImage: kind.systemImage, tint: Theme.inkSecondary, accessory: .add)
            }
            .buttonStyle(.plain)
        }
    }

    private func favoriteRow(_ saved: SavedPlace) -> some View {
        Button {
            router.planRoute(to: saved.place)
        } label: {
            SavedPlaceLabel(title: saved.name, subtitle: saved.subtitle,
                            systemImage: SavedPlaceKind.favorite.systemImage,
                            tint: PlaceKind.favorite.tint, accessory: .walk)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Plans a shady walk there"))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                delete(saved)
            } label: {
                Label("Remove", systemImage: "trash")
            }
            Button {
                startRenaming(saved)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(Theme.shade)
        }
        .contextMenu {
            Button {
                router.planRoute(to: saved.place)
            } label: {
                Label("Plan a shady walk", systemImage: "figure.walk")
            }
            Button {
                startRenaming(saved)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                delete(saved)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func recentRow(_ place: Place) -> some View {
        Button {
            router.planRoute(to: place)
        } label: {
            SavedPlaceLabel(title: place.displayName, subtitle: place.subtitle,
                            systemImage: "clock.arrow.circlepath", tint: Theme.inkSecondary, accessory: .walk)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Plans a shady walk there"))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                search.removeRecent(id: place.id)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading) {
            if !isFavorite(place) {
                Button {
                    save(place, as: .favorite)
                } label: {
                    Label("Add to favorites", systemImage: "star.fill")
                }
                .tint(Theme.sunFill)
            }
        }
        .contextMenu {
            Button {
                router.planRoute(to: place)
            } label: {
                Label("Plan a shady walk", systemImage: "figure.walk")
            }
            if !isFavorite(place) {
                Button {
                    save(place, as: .favorite)
                } label: {
                    Label("Add to favorites", systemImage: "star")
                }
            }
            Button(role: .destructive) {
                search.removeRecent(id: place.id)
            } label: {
                Label("Remove from recents", systemImage: "trash")
            }
        }
    }

    // MARK: - Lookups

    private func anchor(_ kind: SavedPlaceKind) -> SavedPlace? {
        anchors.first { $0.kind == kind }
    }

    private func isFavorite(_ place: Place) -> Bool {
        let id = SavedPlace.identifier(for: place, kind: .favorite)
        return favorites.contains { $0.id == id }
    }

    // MARK: - Editing

    /// Saves `place` as `kind`. "My Location" is first turned into a named place, so Home isn't saved as
    /// "My Location".
    private func save(_ place: Place, as kind: SavedPlaceKind) {
        guard place.kind == .currentLocation else {
            store(place, as: kind)
            return
        }
        Task {
            let named = await app.placeSearch.reverseGeocode(place.coordinate)
            store(named ?? SavedView.pinnedPlace(at: place.coordinate), as: kind)
        }
    }

    /// Inserts or updates the saved place. Home / Work have fixed ids, so a new address replaces the old one; an
    /// existing favorite keeps its (possibly renamed) name and moves to the top.
    private func store(_ place: Place, as kind: SavedPlaceKind) {
        let id = SavedPlace.identifier(for: place, kind: kind)
        let descriptor = FetchDescriptor<SavedPlace>(predicate: #Predicate<SavedPlace> { saved in saved.id == id })
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            if kind != .favorite {
                existing.name = place.displayName
                existing.subtitle = place.subtitle
                existing.latitude = place.coordinate.latitude
                existing.longitude = place.coordinate.longitude
                existing.kind = kind
            }
            existing.createdAt = Date()
        } else {
            modelContext.insert(SavedPlace(place: place, kind: kind))
        }
        try? modelContext.save()
    }

    private func delete(_ saved: SavedPlace) {
        withMotionAwareAnimation(reduceMotion: reduceMotion) {
            modelContext.delete(saved)
        }
        try? modelContext.save()
    }

    private func startRenaming(_ saved: SavedPlace) {
        renameText = saved.name
        renamingPlace = saved
    }

    private func commitRename() {
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved = renamingPlace, !name.isEmpty {
            saved.name = name
            try? modelContext.save()
        }
        renamingPlace = nil
    }

    private var isRenaming: Binding<Bool> {
        Binding(
            get: { renamingPlace != nil },
            set: { isPresented in
                if !isPresented { renamingPlace = nil }
            })
    }

    /// Fallback when reverse geocoding finds no name.
    private static func pinnedPlace(at coordinate: GeoCoordinate) -> Place {
        Place(id: String(format: "pin-%.5f,%.5f", coordinate.latitude, coordinate.longitude),
              name: PlaceKind.droppedPin.displayName, coordinate: coordinate, kind: .droppedPin)
    }
}

// MARK: - Row label

/// Trailing hint on a saved-place row.
private enum SavedRowAccessory {
    /// Tapping plans a walk.
    case walk
    /// Tapping adds a place.
    case add
}

/// `PlaceRow` plus a trailing hint icon (decorative; the row's hint explains the action).
private struct SavedPlaceLabel: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    let accessory: SavedRowAccessory

    var body: some View {
        HStack(spacing: 8) {
            PlaceRow(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint)
            accessoryIcon
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.shade)
                .accessibilityHidden(true)
        }
    }

    private var accessoryIcon: Image {
        switch accessory {
        case .walk: return Image(systemName: "figure.walk")
        case .add: return Image(systemName: "plus.circle.fill")
        }
    }
}

// MARK: - Copy

private extension SavedPlaceKind {
    /// Title of the place-search sheet.
    var searchTitle: LocalizedStringKey {
        switch self {
        case .home: return "Set Home"
        case .work: return "Set Work"
        case .favorite: return "Add a favorite"
        }
    }

    /// Row title while Home / Work isn't set.
    var setTitle: String {
        switch self {
        case .home: return String(localized: "Set Home", comment: "Row that sets the Home address.")
        case .work: return String(localized: "Set Work", comment: "Row that sets the Work address.")
        case .favorite: return String(localized: "Add a favorite", comment: "Row that adds a favorite place.")
        }
    }
}

#if DEBUG
private enum SavedPreviewSupport {
    /// No recents (and, with `seedsSavedPlaces: false`, no saved places): the empty state.
    @MainActor
    static func emptyEnvironment() -> AppEnvironment {
        let environment = AppEnvironment.preview(planned: false)
        environment.search.clearRecents()
        return environment
    }
}

#Preview("Saved") {
    SavedView()
        .previewEnvironment()
}

#Preview("Saved – empty") {
    SavedView()
        .previewEnvironment(SavedPreviewSupport.emptyEnvironment(), seedsSavedPlaces: false)
}
#endif
