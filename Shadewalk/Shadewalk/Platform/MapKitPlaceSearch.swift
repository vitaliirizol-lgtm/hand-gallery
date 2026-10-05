import CoreLocation
import Foundation
import MapKit
import ShadeFeatures

/// Error raised when a suggestion can't be turned into a place.
enum PlaceSearchError: LocalizedError, Equatable {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return String(localized: "Couldn’t find that place. Try another search.",
                          comment: "Error when a search suggestion has no matching place.")
        }
    }
}

/// `PlaceSearching` backed by MapKit: `MKLocalSearchCompleter` for autocomplete, `MKLocalSearch` to resolve a
/// suggestion and `CLGeocoder` for reverse geocoding.
///
/// Only one autocomplete request is in flight at a time: a new query (or task cancellation) resumes the pending one
/// with `CancellationError`. Suggestion ids are `title|subtitle`, so the same completion keeps its id across queries.
@MainActor
final class MapKitPlaceSearch: NSObject, PlaceSearching {
    /// Autocomplete is biased to a region this many metres across around `near`.
    private static let biasRegionSpan: CLLocationDistance = 30_000
    /// A new bias region is set only when `near` moved further than this.
    private static let biasUpdateDistance: Double = 2_000
    /// Pending autocomplete requests fail after this many seconds without an answer.
    private static let timeout: TimeInterval = 10
    /// The completion cache is reset when it grows beyond this.
    private static let maxCachedCompletions = 300

    private let completer: MKLocalSearchCompleter
    private let geocoder = CLGeocoder()
    private var pending: CheckedContinuation<[MKLocalSearchCompletion], Error>?
    private var pendingToken = 0
    private var timeoutTask: Task<Void, Never>?
    private var completionsByID: [String: MKLocalSearchCompletion] = [:]
    private var biasCenter: GeoCoordinate?

    init(resultTypes: MKLocalSearchCompleter.ResultType = [.address, .pointOfInterest]) {
        completer = MKLocalSearchCompleter()
        super.init()
        completer.delegate = self
        completer.resultTypes = resultTypes
    }

    // MARK: - PlaceSearching

    func suggestions(for query: String, near: GeoCoordinate?) async throws -> [PlaceSuggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        cancelPending()
        guard !text.isEmpty else { return [] }
        updateBias(near)

        // MapKit only calls back when the fragment changes: for the same text answer from the current results
        // (a new bias region applies from the next keystroke).
        if completer.queryFragment == text, !completer.isSearching {
            return suggestions(from: completer.results)
        }

        pendingToken += 1
        let token = pendingToken
        let completions: [MKLocalSearchCompletion] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[MKLocalSearchCompletion], Error>) in
                self.pending = continuation
                self.startTimeout(token: token)
                if self.completer.queryFragment != text {
                    self.completer.queryFragment = text
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPending(token: token)
            }
        }
        return suggestions(from: completions)
    }

    func resolve(_ suggestion: PlaceSuggestion) async throws -> Place {
        let request: MKLocalSearch.Request
        if let completion = completionsByID[suggestion.id] {
            request = MKLocalSearch.Request(completion: completion)
        } else {
            request = MKLocalSearch.Request()
            request.naturalLanguageQuery = [suggestion.title, suggestion.subtitle]
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            request.region = completer.region
        }
        request.resultTypes = [.address, .pointOfInterest]
        let response = try await MKLocalSearch(request: request).start()
        guard let item = response.mapItems.first else { throw PlaceSearchError.notFound }
        let coordinate = GeoCoordinate(item.placemark.coordinate)
        guard coordinate.isValid else { throw PlaceSearchError.notFound }
        let name = item.name.flatMap { $0.isEmpty ? nil : $0 } ?? suggestion.title
        let subtitle = suggestion.subtitle.isEmpty ? nil : suggestion.subtitle
        return Place(id: "mk:\(suggestion.id)", name: name, subtitle: subtitle, coordinate: coordinate,
                     kind: .searchResult)
    }

    func reverseGeocode(_ coordinate: GeoCoordinate) async -> Place? {
        guard coordinate.isValid else { return nil }
        if geocoder.isGeocoding { geocoder.cancelGeocode() }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemarks: [CLPlacemark]
        do {
            placemarks = try await geocoder.reverseGeocodeLocation(location)
        } catch {
            return nil
        }
        guard let placemark = placemarks.first else { return nil }
        let name = placemark.name ?? placemark.thoroughfare ?? PlaceKind.droppedPin.displayName
        let area = [placemark.locality, placemark.administrativeArea, placemark.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty && $0 != name }
        let subtitle = area.isEmpty ? nil : area.joined(separator: ", ")
        let id = String(format: "pin:%.5f,%.5f", coordinate.latitude, coordinate.longitude)
        return Place(id: id, name: name, subtitle: subtitle, coordinate: coordinate, kind: .droppedPin)
    }

    // MARK: - Private

    /// Moves the completer's bias region when `near` moved far enough.
    private func updateBias(_ near: GeoCoordinate?) {
        guard let near, near.isValid else { return }
        if let current = biasCenter, GeoMath.distance(current, near) < MapKitPlaceSearch.biasUpdateDistance {
            return
        }
        biasCenter = near
        completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(near),
                                              latitudinalMeters: MapKitPlaceSearch.biasRegionSpan,
                                              longitudinalMeters: MapKitPlaceSearch.biasRegionSpan)
    }

    private func suggestions(from completions: [MKLocalSearchCompletion]) -> [PlaceSuggestion] {
        if completionsByID.count > MapKitPlaceSearch.maxCachedCompletions { completionsByID.removeAll() }
        var seen = Set<String>()
        var output: [PlaceSuggestion] = []
        for completion in completions {
            let id = "\(completion.title)|\(completion.subtitle)"
            guard seen.insert(id).inserted else { continue }
            completionsByID[id] = completion
            output.append(PlaceSuggestion(id: id, title: completion.title, subtitle: completion.subtitle))
        }
        return output
    }

    private func startTimeout(token: Int) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(MapKitPlaceSearch.timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(token: token, with: .failure(URLError(.timedOut)))
        }
    }

    /// Resumes the pending request (any token) with `CancellationError`.
    private func cancelPending() {
        finish(token: pendingToken, with: .failure(CancellationError()))
    }

    /// Resumes the pending request with `CancellationError` if it is still the one identified by `token`.
    private func cancelPending(token: Int) {
        finish(token: token, with: .failure(CancellationError()))
    }

    private func finish(token: Int, with result: Result<[MKLocalSearchCompletion], Error>) {
        guard token == pendingToken, let continuation = pending else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }

    fileprivate func completerUpdated(_ results: [MKLocalSearchCompletion]) {
        finish(token: pendingToken, with: .success(results))
    }

    fileprivate func completerFailed(_ error: Error) {
        finish(token: pendingToken, with: .failure(error))
    }
}

// MARK: - MKLocalSearchCompleterDelegate

extension MapKitPlaceSearch: MKLocalSearchCompleterDelegate {
    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            self.completerUpdated(completer.results)
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            self.completerFailed(error)
        }
    }
}
