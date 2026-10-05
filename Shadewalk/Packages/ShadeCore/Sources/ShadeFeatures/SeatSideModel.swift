import Foundation
import Observation
import ShadeCore

/// Seat-side computation: `(path, departure, duration, cloudCover) -> SeatSideAdvice`.
public typealias SeatSideAdvising = ([GeoCoordinate], Date, TimeInterval, Double?) -> SeatSideAdvice

/// "Which side should I sit on?" for a bus / tram / train trip.
///
/// Changing any input cancels an in-flight computation and clears the previous result (back to `.idle`), so a shown
/// advice always matches the inputs; call `compute()` again.
@MainActor @Observable
public final class SeatSideModel {
    /// Where the trip starts.
    public var from: Place? {
        didSet { if from != oldValue { invalidate() } }
    }
    /// Where the trip ends.
    public var to: Place? {
        didSet { if to != oldValue { invalidate() } }
    }
    /// Vehicle; scales the car ETA by `travelTimeFactor`.
    public var vehicle: VehicleKind = .bus {
        didSet { if vehicle != oldValue { invalidate() } }
    }
    /// Departure time (defaults to the clock's now).
    public var departure: Date {
        didSet { if departure != oldValue { invalidate() } }
    }

    /// Advice for the current inputs.
    public private(set) var state: LoadState<SeatSideAdvice> = .idle
    /// Road path behind the current advice (for the map).
    public private(set) var path: DrivingPath?
    /// Estimated trip duration behind the current advice, seconds.
    public private(set) var tripDuration: TimeInterval?
    /// Cloud cover used for the current advice, percent (nil if unknown).
    public private(set) var cloudCover: Double?

    @ObservationIgnored private let drivingPaths: DrivingPathProviding
    @ObservationIgnored private let weather: WeatherProviding?
    @ObservationIgnored private let advise: SeatSideAdvising
    @ObservationIgnored var pendingTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - drivingPaths: road path provider (MapKit directions in the app).
    ///   - weather: optional cloud-cover source; failures are ignored.
    ///   - now: clock for the default departure.
    ///   - advise: seat-side computation, defaults to `SeatSideAdvisor.advise`.
    public init(drivingPaths: DrivingPathProviding, weather: WeatherProviding? = nil, now: @escaping () -> Date = { Date() },
                advise: @escaping SeatSideAdvising = SeatSideAdvisor.advise) {
        self.drivingPaths = drivingPaths
        self.weather = weather
        self.advise = advise
        departure = now()
    }

    /// Both ends are set.
    public var canCompute: Bool { from != nil && to != nil }

    /// Swaps `from` and `to`.
    public func swap() {
        (from, to) = (to, from)
    }

    /// Fetches the driving path, estimates the trip duration for `vehicle`, looks up cloud cover at departure and
    /// computes the advice. Replaces any in-flight computation; returns when done or superseded.
    public func compute() async {
        pendingTask?.cancel()
        generation += 1
        let token = generation
        guard let from, let to else {
            state = .idle
            return
        }
        state = .loading
        let vehicle = self.vehicle, departure = self.departure
        let drivingPaths = self.drivingPaths, weather = self.weather
        let task = Task { [weak self] in
            do {
                let path = try await drivingPaths.drivingPath(from: from.coordinate, to: to.coordinate)
                guard let self, token == self.generation, !Task.isCancelled else { return }
                guard path.coordinates.count >= 2, path.expectedTravelTime.isFinite, path.expectedTravelTime > 0 else {
                    self.state = .failure(ShadeError.noRouteFound)
                    return
                }
                let duration = path.expectedTravelTime * vehicle.travelTimeFactor
                var cloud: Double?
                if let weather {
                    cloud = (try? await weather.forecast(at: from.coordinate))?.snapshot(at: departure)?.cloudCover
                    guard token == self.generation, !Task.isCancelled else { return }
                }
                let advice = self.advise(path.coordinates, departure, duration, cloud)
                self.path = path
                self.tripDuration = duration
                self.cloudCover = cloud
                self.state = .loaded(advice)
            } catch {
                guard let self, token == self.generation, !Task.isCancelled else { return }
                self.state = .failure(error)
            }
        }
        pendingTask = task
        await task.value
    }

    private func invalidate() {
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        state = .idle
        path = nil
        tripDuration = nil
        cloudCover = nil
    }
}
