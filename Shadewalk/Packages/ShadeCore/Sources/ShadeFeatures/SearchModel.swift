import Foundation
import Observation
import ShadeCore

/// Place search with debounced autocomplete and persisted recent places.
@MainActor @Observable
public final class SearchModel {
    /// Queries shorter than this (after trimming) don't hit the search service.
    public static let minimumQueryLength = 2
    /// Maximum number of recent places kept.
    public static let maxRecents = 10

    /// Search text. Changing it schedules a debounced suggestion lookup.
    public var query: String = "" {
        didSet { if query != oldValue { queryChanged() } }
    }

    /// Biases suggestions towards this coordinate (e.g. the map centre or the user's location).
    public var searchCenter: GeoCoordinate?

    /// Suggestions for the current query.
    public private(set) var results: LoadState<[PlaceSuggestion]> = .idle
    /// Recently chosen places, most recent first.
    public private(set) var recents: [Place]
    /// Number of `resolve` calls in flight.
    private var activeResolutions = 0

    @ObservationIgnored private let search: PlaceSearching
    @ObservationIgnored private let store: KeyValueStore
    @ObservationIgnored private let recentsKey: String
    @ObservationIgnored private let debounceInterval: TimeInterval
    @ObservationIgnored var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - search: autocomplete / geocoding service.
    ///   - store: persistence for recent places.
    ///   - debounceInterval: delay after the last keystroke, seconds (0 in tests).
    public init(search: PlaceSearching, store: KeyValueStore, recentsKey: String = ShadeFeaturesStorageKeys.recentPlaces,
                debounceInterval: TimeInterval = 0.25) {
        self.search = search
        self.store = store
        self.recentsKey = recentsKey
        self.debounceInterval = max(0, debounceInterval)
        if let data = store.data(forKey: recentsKey), let decoded = try? JSONDecoder().decode([Place].self, from: data) {
            recents = SearchModel.normalized(decoded)
        } else {
            recents = []
        }
    }

    /// Trimmed query.
    public var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Suggestions of the current query (empty unless loaded).
    public var suggestions: [PlaceSuggestion] { results.value ?? [] }

    /// A suggestion is being resolved.
    public var isResolving: Bool { activeResolutions > 0 }

    /// Runs the lookup for the current query immediately and returns when done (or superseded).
    public func searchNow() async {
        schedule(after: 0)
        await pendingTask?.value
    }

    /// Clears the query and results.
    public func clear() {
        query = ""
    }

    /// Resolves a suggestion to a place and records it in `recents`.
    public func resolve(_ suggestion: PlaceSuggestion) async throws -> Place {
        activeResolutions += 1
        defer { activeResolutions -= 1 }
        let place = try await search.resolve(suggestion)
        addRecent(place)
        return place
    }

    /// Records `place` as the most recent one (deduplicated by id, max `maxRecents`). The current location is never
    /// recorded.
    public func addRecent(_ place: Place) {
        guard place.kind != .currentLocation else { return }
        var next = recents.filter { $0.id != place.id }
        next.insert(place, at: 0)
        setRecents(next)
    }

    /// Removes a recent place.
    public func removeRecent(id: String) {
        setRecents(recents.filter { $0.id != id })
    }

    /// Removes all recent places.
    public func clearRecents() {
        setRecents([])
    }

    // MARK: - Private

    private static func normalized(_ places: [Place]) -> [Place] {
        var seen = Set<String>()
        var out: [Place] = []
        for place in places where place.kind != .currentLocation {
            guard seen.insert(place.id).inserted else { continue }
            out.append(place)
            if out.count == maxRecents { break }
        }
        return out
    }

    private func setRecents(_ places: [Place]) {
        let next = SearchModel.normalized(places)
        guard next != recents else { return }
        recents = next
        if let data = try? JSONEncoder().encode(next) {
            store.set(data, forKey: recentsKey)
        }
    }

    private func queryChanged() {
        schedule(after: debounceInterval)
    }

    private func schedule(after delay: TimeInterval) {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        let token = generation
        let text = trimmedQuery
        guard text.count >= SearchModel.minimumQueryLength else {
            results = .idle
            return
        }
        results = .loading
        let center = searchCenter
        pendingTask = Task { [weak self] in
            do {
                try await Debounce.wait(delay)
            } catch {
                return
            }
            await self?.perform(text, center: center, token: token)
        }
    }

    private func perform(_ text: String, center: GeoCoordinate?, token: Int) async {
        guard token == generation else { return }
        do {
            let found = try await search.suggestions(for: text, near: center)
            guard token == generation, !Task.isCancelled else { return }
            results = .loaded(found)
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            results = .failure(error)
        }
        if token == generation { pendingTask = nil }
    }
}
