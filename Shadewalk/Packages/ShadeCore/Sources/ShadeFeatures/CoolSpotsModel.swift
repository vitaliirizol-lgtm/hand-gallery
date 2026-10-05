import Foundation
import Observation
import ShadeCore

/// A cool spot with its distance from the reference coordinate.
public struct CoolSpotItem: Hashable, Sendable, Identifiable {
    /// The cool spot.
    public var spot: CoolSpot
    /// Metres from the reference coordinate.
    public var distance: Double

    public init(spot: CoolSpot, distance: Double) {
        self.spot = spot
        self.distance = distance
    }

    public var id: Int64 { spot.id }
}

/// Cool spots (water, cool interiors, shelters, parks) around a coordinate, filterable by kind and sorted by distance.
@MainActor @Observable
public final class CoolSpotsModel {
    /// Raw spots of the latest load.
    public private(set) var state: LoadState<[CoolSpot]> = .idle
    /// Coordinate distances are measured from.
    public private(set) var reference: GeoCoordinate?
    /// Kinds shown in `items` (default: all).
    public var filters: Set<CoolSpotKind> = Set(CoolSpotKind.allCases) {
        didSet { if filters != oldValue { applyFilters() } }
    }
    /// All loaded spots, nearest first, distances precomputed.
    public private(set) var allItems: [CoolSpotItem] = []
    /// `allItems` restricted to `filters`.
    public private(set) var items: [CoolSpotItem] = []

    @ObservationIgnored private let provider: CoolSpotProviding
    @ObservationIgnored var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public init(provider: CoolSpotProviding) {
        self.provider = provider
    }

    /// Loads spots within `radius` metres of `coordinate`, replacing any in-flight load. Returns when done or
    /// superseded.
    public func load(near coordinate: GeoCoordinate, radius: Double = 1_000) async {
        pendingTask?.cancel()
        generation += 1
        let token = generation
        state = .loading
        let provider = self.provider
        let task = Task { [weak self] in
            do {
                let spots = try await provider.coolSpots(near: coordinate, radius: radius)
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.reference = coordinate
                self.state = .loaded(spots)
                self.rebuild(spots)
            } catch {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.state = .failure(error)
                self.allItems = []
                self.items = []
            }
        }
        pendingTask = task
        await task.value
    }

    /// Re-measures and re-sorts the loaded spots from a new reference coordinate (no reload).
    public func updateReference(_ coordinate: GeoCoordinate) {
        reference = coordinate
        rebuild(state.value ?? [])
    }

    /// Shows or hides a kind.
    public func toggle(_ kind: CoolSpotKind) {
        if filters.contains(kind) { filters.remove(kind) } else { filters.insert(kind) }
    }

    /// `kind` is included in `filters`.
    public func isShowing(_ kind: CoolSpotKind) -> Bool { filters.contains(kind) }

    /// Number of loaded spots of `kind` (for filter chip badges).
    public func count(of kind: CoolSpotKind) -> Int {
        allItems.reduce(0) { $0 + ($1.spot.kind == kind ? 1 : 0) }
    }

    // MARK: - Private

    private func rebuild(_ spots: [CoolSpot]) {
        guard let reference else {
            allItems = []
            items = []
            return
        }
        allItems = spots
            .map { CoolSpotItem(spot: $0, distance: GeoMath.distance(reference, $0.coordinate)) }
            .sorted { $0.distance == $1.distance ? $0.spot.id < $1.spot.id : $0.distance < $1.distance }
        applyFilters()
    }

    private func applyFilters() {
        items = allItems.filter { filters.contains($0.spot.kind) }
    }
}
