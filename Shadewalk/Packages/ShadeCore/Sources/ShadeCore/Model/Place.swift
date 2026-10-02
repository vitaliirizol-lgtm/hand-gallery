import Foundation

public enum PlaceKind: String, Codable, Sendable, Hashable {
    case currentLocation, searchResult, home, work, favorite, droppedPin, coolSpot
}

public struct Place: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var subtitle: String?
    public var coordinate: GeoCoordinate
    public var kind: PlaceKind

    public init(id: String, name: String, subtitle: String? = nil, coordinate: GeoCoordinate, kind: PlaceKind = .searchResult) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.kind = kind
    }

    public static func currentLocation(_ c: GeoCoordinate, name: String = "My Location") -> Place {
        Place(id: "current-location", name: name, coordinate: c, kind: .currentLocation)
    }
}

/// Autocomplete suggestion; resolve it to a `Place` with `PlaceSearching.resolve`.
public struct PlaceSuggestion: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String

    public init(id: String, title: String, subtitle: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
    }
}

/// A single location update.
public struct LocationFix: Hashable, Sendable {
    public var coordinate: GeoCoordinate
    /// Metres; negative = invalid.
    public var horizontalAccuracy: Double
    /// Degrees clockwise from north; nil if unknown.
    public var course: Double?
    /// Device heading (compass), degrees; nil if unknown.
    public var heading: Double?
    /// m/s; nil if unknown.
    public var speed: Double?
    public var timestamp: Date

    public init(coordinate: GeoCoordinate, horizontalAccuracy: Double = 5, course: Double? = nil, heading: Double? = nil,
                speed: Double? = nil, timestamp: Date = Date()) {
        self.coordinate = coordinate
        self.horizontalAccuracy = horizontalAccuracy
        self.course = course
        self.heading = heading
        self.speed = speed
        self.timestamp = timestamp
    }
}

public enum LocationAuthorization: String, Sendable, Hashable {
    case notDetermined, denied, restricted, authorized
}
