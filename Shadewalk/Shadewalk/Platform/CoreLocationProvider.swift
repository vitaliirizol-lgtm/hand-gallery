import CoreLocation
import Foundation
import ShadeFeatures

/// `LocationProviding` backed by `CLLocationManager`.
///
/// Every open `fixes()` stream receives every fix (fan-out). The GPS and compass run only while at least one stream is
/// open *and* permission is granted. A fix is passed on when the device has moved `minimumDistance`, when its accuracy
/// improved, or after `heartbeatInterval`, so a device that isn't moving keeps a current fix. The manager is created
/// on the main thread, so its delegate callbacks arrive on the main thread and hop into the main actor with
/// `MainActor.assumeIsolated`.
@MainActor
final class CoreLocationProvider: NSObject, LocationProviding {
    private(set) var authorization: LocationAuthorization
    private(set) var lastFix: LocationFix?

    /// Called on the main actor whenever the authorization changes.
    var onAuthorizationChange: (@MainActor (LocationAuthorization) -> Void)?

    private let manager: CLLocationManager
    private var continuations: [UUID: AsyncStream<LocationFix>.Continuation] = [:]
    private var lastHeading: Double?
    private var lastDelivered: CLLocation?
    private var isRunning = false

    /// Fixes older than this are not replayed to a new stream.
    private static let replayMaxAge: TimeInterval = 15
    /// The system's cached position seeds `lastFix` only when it is at most this old.
    private static let initialFixMaxAge: TimeInterval = 120
    /// Movement that passes a new fix on, metres.
    private static let minimumDistance: CLLocationDistance = 2
    /// A fix is passed on at least this often while updates run, seconds.
    private static let heartbeatInterval: TimeInterval = 10

    init(desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyBest) {
        let manager = CLLocationManager()
        self.manager = manager
        authorization = CoreLocationProvider.map(manager.authorizationStatus)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = desiredAccuracy
        // Filtered in `shouldDeliver` instead, which also passes on a periodic fix while standing still.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.headingFilter = 5
        manager.pausesLocationUpdatesAutomatically = false
        // A cached position from an earlier session may be far from where the user is now.
        if let location = manager.location, location.horizontalAccuracy >= 0,
           abs(location.timestamp.timeIntervalSinceNow) <= CoreLocationProvider.initialFixMaxAge {
            lastFix = CoreLocationProvider.fix(from: location, heading: nil)
        }
    }

    /// Keeps location updates running while the app is in the background (follow mode), with the system's location
    /// indicator. Needs `location` in `UIBackgroundModes`; without it the request is ignored (setting the flag would
    /// raise an exception).
    func setBackgroundUpdatesEnabled(_ enabled: Bool) {
        let allowed = enabled && CoreLocationProvider.hasBackgroundLocationMode
        guard manager.allowsBackgroundLocationUpdates != allowed else { return }
        manager.allowsBackgroundLocationUpdates = allowed
        manager.showsBackgroundLocationIndicator = allowed
    }

    private static var hasBackgroundLocationMode: Bool {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        return modes.contains("location")
    }

    // MARK: - LocationProviding

    func requestAuthorization() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func fixes() -> AsyncStream<LocationFix> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: LocationFix.self, bufferingPolicy: .bufferingNewest(16))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.removeContinuation(id)
            }
        }
        continuations[id] = continuation
        if let lastFix, abs(lastFix.timestamp.timeIntervalSinceNow) <= CoreLocationProvider.replayMaxAge {
            continuation.yield(lastFix)
        }
        updateMonitoring()
        return stream
    }

    // MARK: - Private

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
        updateMonitoring()
    }

    /// Runs location + heading updates while any stream is open and permission is granted.
    private func updateMonitoring() {
        let shouldRun = !continuations.isEmpty && authorization == .authorized
        if shouldRun, !isRunning {
            isRunning = true
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        } else if !shouldRun, isRunning {
            isRunning = false
            lastDelivered = nil
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
        }
    }

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        let mapped = CoreLocationProvider.map(status)
        let changed = mapped != authorization
        authorization = mapped
        updateMonitoring()
        if changed { onAuthorizationChange?(mapped) }
    }

    private func handle(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate) else { return }
        if let previous = lastDelivered, !CoreLocationProvider.shouldDeliver(location, after: previous) { return }
        lastDelivered = location
        let fix = CoreLocationProvider.fix(from: location, heading: lastHeading)
        lastFix = fix
        for continuation in continuations.values {
            continuation.yield(fix)
        }
    }

    /// Moved far enough, markedly more accurate, or due for the periodic fix.
    private static func shouldDeliver(_ location: CLLocation, after previous: CLLocation) -> Bool {
        location.distance(from: previous) >= minimumDistance
            || location.horizontalAccuracy < previous.horizontalAccuracy - 5
            || location.timestamp.timeIntervalSince(previous.timestamp) >= heartbeatInterval
    }

    private func handleHeading(_ trueHeading: Double) {
        lastHeading = trueHeading >= 0 ? trueHeading : nil
    }

    private static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        @unknown default: return .denied
        }
    }

    private static func fix(from location: CLLocation, heading: Double?) -> LocationFix {
        LocationFix(coordinate: GeoCoordinate(location.coordinate),
                    horizontalAccuracy: location.horizontalAccuracy,
                    course: location.course >= 0 ? location.course : nil,
                    heading: heading,
                    speed: location.speed >= 0 ? location.speed : nil,
                    timestamp: location.timestamp)
    }
}

// MARK: - CLLocationManagerDelegate

extension CoreLocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            self.handleAuthorization(manager.authorizationStatus)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            for location in locations {
                self.handle(location)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        MainActor.assumeIsolated {
            self.handleHeading(newHeading.trueHeading)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `.locationUnknown` is transient (CoreLocation keeps trying); a denial arrives through the authorization
        // callback. Nothing to do here.
    }

    nonisolated func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
        false
    }
}
