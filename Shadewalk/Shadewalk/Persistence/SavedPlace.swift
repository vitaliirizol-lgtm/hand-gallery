import Foundation
import ShadeFeatures
import SwiftData

/// Kind of a saved place.
enum SavedPlaceKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case home, work, favorite

    var id: String { rawValue }

    /// Matching `PlaceKind` for `Place` values.
    var placeKind: PlaceKind {
        switch self {
        case .home: return .home
        case .work: return .work
        case .favorite: return .favorite
        }
    }

    var displayName: String { placeKind.displayName }
    var systemImage: String { placeKind.systemImage }

    /// Sort order: Home, Work, then favorites.
    var sortRank: Int {
        switch self {
        case .home: return 0
        case .work: return 1
        case .favorite: return 2
        }
    }
}

/// A place the user saved (Home, Work or a favorite), persisted with SwiftData.
///
/// Home and Work have fixed ids (`saved-home`, `saved-work`), so inserting a new Home replaces the old one
/// (`id` is unique → upsert). Favorites use `saved-<place id>`.
@Model
final class SavedPlace {
    @Attribute(.unique) var id: String
    var name: String
    var subtitle: String?
    var latitude: Double
    var longitude: Double
    /// `SavedPlaceKind.rawValue`.
    var kindRaw: String
    var createdAt: Date

    init(id: String, name: String, subtitle: String? = nil, latitude: Double, longitude: Double,
         kindRaw: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.kindRaw = kindRaw
        self.createdAt = createdAt
    }

    /// Saves `place` as `kind` (its name, subtitle and coordinate are copied).
    convenience init(place: Place, kind: SavedPlaceKind, createdAt: Date = Date()) {
        self.init(id: SavedPlace.identifier(for: place, kind: kind),
                  name: place.displayName,
                  subtitle: place.subtitle,
                  latitude: place.coordinate.latitude,
                  longitude: place.coordinate.longitude,
                  kindRaw: kind.rawValue,
                  createdAt: createdAt)
    }

    /// Typed kind (unknown raw values read as `.favorite`).
    var kind: SavedPlaceKind {
        get { SavedPlaceKind(rawValue: kindRaw) ?? .favorite }
        set { kindRaw = newValue.rawValue }
    }

    var coordinate: GeoCoordinate {
        GeoCoordinate(latitude: latitude, longitude: longitude)
    }

    /// The saved place as a ShadeCore `Place` (id = the saved id, kind = home / work / favorite).
    var place: Place {
        Place(id: id, name: name, subtitle: subtitle, coordinate: coordinate, kind: kind.placeKind)
    }

    /// Persistent id for `place` saved as `kind`.
    static func identifier(for place: Place, kind: SavedPlaceKind) -> String {
        switch kind {
        case .home: return "saved-home"
        case .work: return "saved-work"
        case .favorite: return place.id.hasPrefix("saved-") ? place.id : "saved-\(place.id)"
        }
    }
}

extension Array where Element == SavedPlace {
    /// Home, Work, then favorites (newest first).
    var sortedForDisplay: [SavedPlace] {
        sorted { lhs, rhs in
            let l = lhs.kind.sortRank, r = rhs.kind.sortRank
            return l == r ? lhs.createdAt > rhs.createdAt : l < r
        }
    }
}
