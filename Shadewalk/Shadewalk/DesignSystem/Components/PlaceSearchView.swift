import ShadeFeatures
import SwiftData
import SwiftUI

/// Reusable place-search sheet (Walk "Where to?", Seat side From / To).
///
/// Shows a search field bound to `SearchModel.query`, live suggestions, and — while the field is empty — "My
/// Location" (when a current fix is known), saved places (SwiftData) and recent places. Picking a suggestion resolves
/// it to a `Place` and records it in recents; then `onPick` is called, the query is cleared and the sheet dismisses
/// itself. Cancelling (or dismissing the sheet) while a suggestion resolves drops it.
///
/// Requires `AppEnvironment`, `SearchModel` and `LocationModel` in the environment and a SwiftData container with
/// `SavedPlace`.
struct PlaceSearchView: View {
    private let title: LocalizedStringKey
    private let prompt: LocalizedStringKey
    private let allowsCurrentLocation: Bool
    private let searchCenter: GeoCoordinate?
    private let onPick: (Place) -> Void

    @Environment(AppEnvironment.self) private var app
    @Environment(SearchModel.self) private var search
    @Environment(LocationModel.self) private var location
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedPlace.createdAt, order: .reverse) private var savedPlaces: [SavedPlace]

    @FocusState private var isFieldFocused: Bool
    @State private var resolvingID: String?
    @State private var resolveError: String?
    @State private var resolveTask: Task<Void, Never>?

    /// - Parameters:
    ///   - title: navigation title of the sheet.
    ///   - prompt: placeholder of the search field.
    ///   - allowsCurrentLocation: offer "My Location" as a choice.
    ///   - searchCenter: where suggestions should be near (e.g. the visible map area); nil uses the user's position.
    ///   - onPick: receives the chosen place (before the sheet dismisses).
    init(title: LocalizedStringKey = "Where to?", prompt: LocalizedStringKey = "Search for a place or address",
         allowsCurrentLocation: Bool = true, searchCenter: GeoCoordinate? = nil,
         onPick: @escaping (Place) -> Void) {
        self.title = title
        self.prompt = prompt
        self.allowsCurrentLocation = allowsCurrentLocation
        self.searchCenter = searchCenter
        self.onPick = onPick
    }

    var body: some View {
        NavigationStack {
            List {
                if showsSuggestions {
                    suggestionsSection
                } else {
                    currentLocationSection
                    savedSection
                    recentsSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
            .background(Theme.canvas)
            .safeAreaInset(edge: .top, spacing: 0) {
                searchField
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        resolveTask?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            search.searchCenter = searchCenter ?? location.currentCoordinate()
            isFieldFocused = true
        }
        .onDisappear {
            resolveTask?.cancel()
        }
    }

    // MARK: - Search field

    private var showsSuggestions: Bool {
        search.trimmedQuery.count >= SearchModel.minimumQueryLength
    }

    private var searchField: some View {
        @Bindable var searchModel = search
        return HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.inkSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $searchModel.query)
                .focused($isFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await search.searchNow() } }
                .foregroundStyle(Theme.ink)
            if !search.query.isEmpty {
                Button {
                    search.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, -12)
                .padding(.trailing, -10)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.surface, in: Theme.controlShape)
        .overlay {
            Theme.controlShape.strokeBorder(Theme.hairline, lineWidth: 0.5)
        }
        .padding(.horizontal, Theme.screenPadding)
        .padding(.vertical, 8)
        .background(Theme.canvas)
    }

    // MARK: - Sections

    @ViewBuilder
    private var suggestionsSection: some View {
        Section {
            if let resolveError {
                Label {
                    Text(verbatim: resolveError)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.heat)
                }
                .font(.subheadline)
            }
            switch search.results {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching…")
                        .foregroundStyle(Theme.inkSecondary)
                }
                .accessibilityElement(children: .combine)
            case let .loaded(suggestions):
                if suggestions.isEmpty {
                    Text("No places found. Try a different search.")
                        .foregroundStyle(Theme.inkSecondary)
                } else {
                    ForEach(suggestions) { suggestion in
                        suggestionRow(suggestion)
                    }
                }
            case .failed:
                Button {
                    Task { await search.searchNow() }
                } label: {
                    Label("Search failed. Tap to try again.", systemImage: "arrow.clockwise")
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }

    private func suggestionRow(_ suggestion: PlaceSuggestion) -> some View {
        Button {
            pick(suggestion)
        } label: {
            HStack {
                PlaceRow(title: suggestion.title, subtitle: suggestion.subtitle, systemImage: "mappin",
                         tint: Theme.inkSecondary)
                if resolvingID == suggestion.id {
                    ProgressView()
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(resolvingID != nil)
        .listRowBackground(Theme.surface)
    }

    @ViewBuilder
    private var currentLocationSection: some View {
        if allowsCurrentLocation, let coordinate = location.currentCoordinate() {
            Section {
                placeButton(Place.localizedCurrentLocation(coordinate), recordsRecent: false)
            }
        }
    }

    /// Home, Work, then favorites.
    private var sortedSavedPlaces: [SavedPlace] {
        savedPlaces.sortedForDisplay
    }

    @ViewBuilder
    private var savedSection: some View {
        if !savedPlaces.isEmpty {
            Section {
                ForEach(sortedSavedPlaces) { savedPlace in
                    placeButton(savedPlace.place, recordsRecent: false)
                }
            } header: {
                Text("Saved")
            }
        }
    }

    @ViewBuilder
    private var recentsSection: some View {
        if search.recents.isEmpty {
            if savedPlaces.isEmpty {
                Section {
                    Text("Search for a destination to plan a walk in the shade.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.inkSecondary)
                        .listRowBackground(Color.clear)
                }
            }
        } else {
            Section {
                ForEach(search.recents) { place in
                    placeButton(place, recordsRecent: true)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                search.removeRecent(id: place.id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Button("Clear") { search.clearRecents() }
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                }
            }
        }
    }

    private func placeButton(_ place: Place, recordsRecent: Bool) -> some View {
        Button {
            if recordsRecent { search.addRecent(place) }
            finish(with: place)
        } label: {
            PlaceRow(place: place)
        }
        .buttonStyle(.plain)
        .listRowBackground(Theme.surface)
    }

    // MARK: - Actions

    /// Resolves the suggestion, then picks it, unless the sheet was cancelled meanwhile (the place is then neither
    /// picked nor recorded in recents).
    private func pick(_ suggestion: PlaceSuggestion) {
        guard resolvingID == nil else { return }
        resolvingID = suggestion.id
        resolveError = nil
        let placeSearch = app.placeSearch
        resolveTask = Task {
            do {
                let place = try await placeSearch.resolve(suggestion)
                guard !Task.isCancelled else { return }
                resolvingID = nil
                search.addRecent(place)
                finish(with: place)
            } catch {
                guard !Task.isCancelled else { return }
                resolvingID = nil
                resolveError = ErrorText.message(for: error)
            }
        }
    }

    private func finish(with place: Place) {
        onPick(place)
        search.clear()
        dismiss()
    }
}

#if DEBUG
#Preview("Place search") {
    PlaceSearchView { _ in }
        .previewEnvironment()
}
#endif
