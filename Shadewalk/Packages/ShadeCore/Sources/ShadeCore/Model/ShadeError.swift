import Foundation

public enum ShadeError: Error, Hashable, Sendable {
    /// Origin and destination are too far apart for walking (> `limit` metres straight line).
    case tooFar(distance: Double, limit: Double)
    /// Origin or destination is more than 250 m from any walkable way.
    case originTooFarFromNetwork
    case destinationTooFarFromNetwork
    /// No path between origin and destination in the walk graph.
    case noRouteFound
    /// The area has no walkable ways (or data failed to load).
    case noWalkableNetwork
    /// All Overpass/Open-Meteo endpoints failed.
    case networkUnavailable
    case badResponse(status: Int)
    case decodingFailed(String)
    case cancelled
}

extension ShadeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .tooFar(distance, limit):
            return String(format: "That's %.1f km away — walking routes are limited to %.0f km.", distance / 1000, limit / 1000)
        case .originTooFarFromNetwork:
            return "The start point is too far from any footpath."
        case .destinationTooFarFromNetwork:
            return "The destination is too far from any footpath."
        case .noRouteFound:
            return "Couldn't find a walking route between these places."
        case .noWalkableNetwork:
            return "No walkable streets found in this area."
        case .networkUnavailable:
            return "Map data is unavailable right now. Check your connection and try again."
        case let .badResponse(status):
            return "The map data server returned an error (\(status))."
        case let .decodingFailed(detail):
            return "Couldn't read map data (\(detail))."
        case .cancelled:
            return "Cancelled."
        }
    }
}
