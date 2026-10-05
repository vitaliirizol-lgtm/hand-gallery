import Foundation
import Observation
import ShadeCore

/// State of the shade overlay.
public enum ShadeOverlayState: Hashable, Sendable {
    /// Disabled, or nothing requested yet.
    case idle
    case loading
    case ready
    /// The visible area is too large to compute shade for; zoom in.
    case tooZoomedOut
    case failed(message: String)
}

/// Shadow polygons for the visible map area at the selected time.
///
/// `update(visible:date:)` is debounced. Areas with a side longer than `maxVisibleSide` (2.3 km) are not computed
/// (`.tooZoomedOut`, polygons cleared). The last good overlay stays visible while a new one loads.
@MainActor @Observable
public final class ShadeOverlayModel {
    /// Show the overlay. Turning it off clears the polygons; turning it on loads the last requested area.
    public var isEnabled: Bool {
        didSet { if isEnabled != oldValue { enabledChanged() } }
    }

    /// Loading state of the overlay.
    public private(set) var state: ShadeOverlayState = .idle
    /// Last good overlay (kept while loading and after a failure).
    public private(set) var overlay: ShadeOverlay?

    @ObservationIgnored private let provider: ShadeOverlayProviding
    @ObservationIgnored private let debounceInterval: TimeInterval
    @ObservationIgnored private let maxVisibleSide: Double
    @ObservationIgnored private let dateTolerance: TimeInterval
    @ObservationIgnored var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// Last visible area / date passed to `update`.
    @ObservationIgnored private var lastRequest: (bbox: BoundingBox, date: Date)?
    /// Area / date covered by `overlay` (or by the in-flight request).
    @ObservationIgnored private var loadedArea: (bbox: BoundingBox, date: Date)?
    @ObservationIgnored private var pendingArea: (bbox: BoundingBox, date: Date)?

    /// - Parameters:
    ///   - provider: shadow polygon source.
    ///   - debounceInterval: delay after the last `update`, seconds (0 in tests).
    ///   - maxVisibleSide: largest visible side that is still computed, metres. The fetched area adds 15 % on each
    ///     side, so the default keeps it within `RoutePlanner.maxOverlaySide` (3 km).
    ///   - dateTolerance: dates closer than this reuse an overlay, seconds.
    public init(provider: ShadeOverlayProviding, isEnabled: Bool = false, debounceInterval: TimeInterval = 0.35,
                maxVisibleSide: Double = 2_300, dateTolerance: TimeInterval = 60) {
        self.provider = provider
        self.isEnabled = isEnabled
        self.debounceInterval = max(0, debounceInterval)
        self.maxVisibleSide = maxVisibleSide
        self.dateTolerance = dateTolerance
    }

    /// Polygons to draw (open rings).
    public var polygons: [[GeoCoordinate]] { overlay?.polygons ?? [] }

    /// Reports the visible map area and the selected time. Loads (debounced) when enabled and the area isn't already
    /// covered.
    public func update(visible bbox: BoundingBox, date: Date) {
        lastRequest = (bbox, date)
        guard isEnabled else { return }
        let side = max(bbox.widthMeters, bbox.heightMeters)
        guard side.isFinite, side <= maxVisibleSide else {
            cancelPending()
            overlay = nil
            loadedArea = nil
            state = .tooZoomedOut
            return
        }
        if let loaded = loadedArea, covers(loaded, bbox, date), state == .ready { return }
        if let pending = pendingArea, covers(pending, bbox, date), state == .loading { return }
        schedule(bbox: bbox, date: date, after: debounceInterval)
    }

    /// Reloads the last requested area now (e.g. after a failure).
    public func retry() {
        guard isEnabled, let request = lastRequest else { return }
        loadedArea = nil
        pendingArea = nil
        let side = max(request.bbox.widthMeters, request.bbox.heightMeters)
        guard side.isFinite, side <= maxVisibleSide else {
            update(visible: request.bbox, date: request.date)
            return
        }
        schedule(bbox: request.bbox, date: request.date, after: 0)
    }

    // MARK: - Private

    private func enabledChanged() {
        if isEnabled {
            if let request = lastRequest { update(visible: request.bbox, date: request.date) }
        } else {
            cancelPending()
            overlay = nil
            loadedArea = nil
            state = .idle
        }
    }

    private func covers(_ area: (bbox: BoundingBox, date: Date), _ bbox: BoundingBox, _ date: Date) -> Bool {
        area.bbox.contains(bbox) && abs(area.date.timeIntervalSince(date)) < dateTolerance
    }

    private func cancelPending() {
        pendingTask?.cancel()
        pendingTask = nil
        pendingArea = nil
        generation += 1
    }

    private func schedule(bbox: BoundingBox, date: Date, after delay: TimeInterval) {
        cancelPending()
        let token = generation
        // Fetch a margin around the visible area so small pans don't refetch.
        let side = max(bbox.widthMeters, bbox.heightMeters)
        let fetchArea = bbox.expanded(byMeters: side * 0.15)
        pendingArea = (fetchArea, date)
        state = .loading
        let provider = self.provider
        pendingTask = Task { [weak self] in
            do {
                try await Debounce.wait(delay)
            } catch {
                return
            }
            do {
                let result = try await provider.shadeOverlay(in: fetchArea, at: date)
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.overlay = result
                self.loadedArea = (fetchArea, date)
                self.state = .ready
                self.pendingArea = nil
                self.pendingTask = nil
            } catch {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.state = .failed(message: ErrorMessages.message(for: error))
                self.pendingArea = nil
                self.pendingTask = nil
            }
        }
    }
}
