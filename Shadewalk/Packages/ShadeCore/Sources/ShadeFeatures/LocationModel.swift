import Foundation
import Observation
import ShadeCore

/// Observable mirror of a `LocationProviding` (authorization and latest fix) for views.
@MainActor @Observable
public final class LocationModel {
    /// Location permission as last read from the provider.
    public private(set) var authorization: LocationAuthorization
    /// Latest known fix.
    public private(set) var lastFix: LocationFix?
    /// Subscribed to location updates.
    public private(set) var isUpdating = false

    @ObservationIgnored private let provider: LocationProviding
    @ObservationIgnored var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var subscription = 0

    public init(provider: LocationProviding) {
        self.provider = provider
        authorization = provider.authorization
        lastFix = provider.lastFix
    }

    /// Latest known coordinate.
    public var coordinate: GeoCoordinate? { lastFix?.coordinate }

    /// Location permission granted.
    public var isAuthorized: Bool { authorization == .authorized }

    /// The user can still be asked for permission.
    public var canRequestAuthorization: Bool { authorization == .notDetermined }

    /// "My Location" place for the latest fix.
    public var currentPlace: Place? { coordinate.map { Place.currentLocation($0) } }

    /// Asks the provider for permission, then re-reads its state.
    public func requestAuthorization() {
        provider.requestAuthorization()
        refresh()
    }

    /// Re-reads authorization and last fix from the provider (e.g. when the app becomes active).
    public func refresh() {
        authorization = provider.authorization
        if let fix = provider.lastFix { lastFix = fix }
    }

    /// Subscribes to location fixes (no-op if already subscribed).
    public func startUpdates() {
        guard updatesTask == nil else { return }
        subscription += 1
        let current = subscription
        isUpdating = true
        let stream = provider.fixes()
        updatesTask = Task { [weak self] in
            for await fix in stream {
                guard let self, self.subscription == current, !Task.isCancelled else { break }
                self.lastFix = fix
                if self.authorization != self.provider.authorization { self.authorization = self.provider.authorization }
            }
            guard let self, self.subscription == current else { return }
            // The provider ended the stream (e.g. permission revoked).
            self.updatesTask = nil
            self.isUpdating = false
            self.authorization = self.provider.authorization
        }
    }

    /// Cancels the subscription.
    public func stopUpdates() {
        subscription += 1
        updatesTask?.cancel()
        updatesTask = nil
        isUpdating = false
    }
}
