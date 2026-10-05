import Foundation
import ShadeFeatures

extension ShadeError {
    /// Localized, user-facing message (distances follow the device locale).
    var localizedMessage: String { localizedMessage(units: .system) }

    /// Localized, user-facing message with distances in `units`.
    func localizedMessage(units: UnitPreference) -> String {
        switch self {
        case let .tooFar(distance, limit):
            let distanceText = Formatters.distance(distance, units: units)
            let limitText = Formatters.distance(limit, units: units)
            return String(localized: "That’s \(distanceText) away — walking routes are limited to \(limitText).",
                          comment: "Route planning error. First value: straight-line distance; second: the limit.")
        case .originTooFarFromNetwork:
            return String(localized: "The start point is too far from any footpath.",
                          comment: "Route planning error.")
        case .destinationTooFarFromNetwork:
            return String(localized: "The destination is too far from any footpath.",
                          comment: "Route planning error.")
        case .noRouteFound:
            return String(localized: "Couldn’t find a walking route between these places.",
                          comment: "Route planning error.")
        case .noWalkableNetwork:
            return String(localized: "No walkable streets found in this area.",
                          comment: "Route planning error.")
        case .networkUnavailable:
            return String(localized: "Map data is unavailable right now. Check your connection and try again.",
                          comment: "Network error while loading map or weather data.")
        case let .badResponse(status):
            return String(localized: "The map data server returned an error (\(status)).",
                          comment: "Server error. The value is the HTTP status code.")
        case .decodingFailed:
            return String(localized: "Couldn’t read the map data. Please try again.",
                          comment: "Error when map data could not be parsed.")
        case .cancelled:
            return String(localized: "Cancelled.", comment: "A request was cancelled.")
        }
    }

    /// SF Symbol for an error card.
    var systemImage: String {
        switch self {
        case .networkUnavailable, .badResponse, .decodingFailed:
            return "wifi.exclamationmark"
        case .tooFar:
            return "ruler"
        case .originTooFarFromNetwork, .destinationTooFarFromNetwork, .noRouteFound, .noWalkableNetwork:
            return "point.topleft.down.curvedto.point.bottomright.up"
        case .cancelled:
            return "xmark.circle"
        }
    }

    /// Trying the same request again may succeed (transient network / server problems).
    var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .badResponse, .decodingFailed, .noWalkableNetwork:
            return true
        case .tooFar, .originTooFarFromNetwork, .destinationTooFarFromNetwork, .noRouteFound, .cancelled:
            return false
        }
    }
}

/// Error → localized, user-facing text for any error the app shows.
enum ErrorText {
    static func message(for error: Error, units: UnitPreference = .system) -> String {
        if let shadeError = error as? ShadeError {
            return shadeError.localizedMessage(units: units)
        }
        if error is CancellationError {
            return ShadeError.cancelled.localizedMessage(units: units)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return String(localized: "You appear to be offline. Check your connection and try again.",
                              comment: "Error when the device has no internet connection.")
            case .timedOut:
                return String(localized: "The request took too long. Please try again.",
                              comment: "Error when a network request timed out.")
            default:
                return ShadeError.networkUnavailable.localizedMessage(units: units)
            }
        }
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return String(localized: "Something went wrong. Please try again.", comment: "Generic error message.")
    }
}

// MARK: - LoadState display helpers

extension LoadState {
    /// Localized failure message: `ShadeError`s are re-localized, other failures keep the model's message.
    var localizedErrorMessage: String? {
        guard case let .failed(message, error) = self else { return nil }
        if let error { return error.localizedMessage }
        return message
    }

    /// A failure worth offering "Try again" for (non-`ShadeError` failures are assumed transient).
    var isRetryableFailure: Bool {
        guard case let .failed(_, error) = self else { return false }
        return error?.isRetryable ?? true
    }
}
