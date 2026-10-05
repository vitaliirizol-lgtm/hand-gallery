import Foundation
import ShadeFeatures

// Localized display names and SF Symbol names for ShadeCore / ShadeFeatures enums.
// Colours for these live in DesignSystem/Theme.swift (`tint`).

extension RouteProfile {
    var displayName: String {
        switch self {
        case .shadiest: return String(localized: "Shadiest", comment: "Route profile: the route with the most shade.")
        case .balanced: return String(localized: "Balanced", comment: "Route profile: trade-off between shade and time.")
        case .fastest: return String(localized: "Fastest", comment: "Route profile: the quickest route.")
        }
    }

    var systemImage: String {
        switch self {
        case .shadiest: return "leaf.fill"
        case .balanced: return "circle.lefthalf.filled"
        case .fastest: return "hare.fill"
        }
    }
}

extension SlopeCategory {
    var displayName: String {
        switch self {
        case .flat: return String(localized: "Flat", comment: "Slope category of a route.")
        case .gentle: return String(localized: "Gentle", comment: "Slope category of a route.")
        case .moderate: return String(localized: "Moderate", comment: "Slope category of a route.")
        case .steep: return String(localized: "Steep", comment: "Slope category of a route.")
        }
    }

    var systemImage: String {
        switch self {
        case .flat: return "arrow.right"
        case .gentle: return "arrow.up.right"
        case .moderate: return "arrow.up.right"
        case .steep: return "arrow.up"
        }
    }
}

extension CoolSpotKind {
    var displayName: String {
        switch self {
        case .drinkingWater: return String(localized: "Drinking water", comment: "Cool spot kind.")
        case .indoorCool: return String(localized: "Cool indoors", comment: "Cool spot kind: libraries, malls, community centres.")
        case .shelter: return String(localized: "Shelter", comment: "Cool spot kind.")
        case .park: return String(localized: "Park", comment: "Cool spot kind.")
        }
    }

    var systemImage: String {
        switch self {
        case .drinkingWater: return "drop.fill"
        case .indoorCool: return "snowflake"
        case .shelter: return "umbrella.fill"
        case .park: return "tree.fill"
        }
    }
}

extension CoolSpot {
    /// The spot's own name, or its kind when unnamed.
    var displayName: String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return kind.displayName
    }
}

extension VehicleKind {
    var displayName: String {
        switch self {
        case .bus: return String(localized: "Bus", comment: "Vehicle kind for the seat-side advisor.")
        case .tram: return String(localized: "Tram", comment: "Vehicle kind for the seat-side advisor.")
        case .train: return String(localized: "Train", comment: "Vehicle kind for the seat-side advisor.")
        }
    }

    var systemImage: String {
        switch self {
        case .bus: return "bus.fill"
        case .tram: return "tram.fill"
        case .train: return "train.side.front.car"
        }
    }
}

extension SeatSide {
    var displayName: String {
        switch self {
        case .left: return String(localized: "Left side", comment: "Recommended seat side.")
        case .right: return String(localized: "Right side", comment: "Recommended seat side.")
        case .either: return String(localized: "Either side", comment: "Recommended seat side when it doesn’t matter.")
        }
    }
}

extension ManeuverKind {
    /// Short instruction without a street name, e.g. "Turn left".
    var displayName: String {
        switch self {
        case .depart: return String(localized: "Head out", comment: "Walking maneuver.")
        case .continueStraight: return String(localized: "Continue straight", comment: "Walking maneuver.")
        case .slightLeft: return String(localized: "Bear left", comment: "Walking maneuver.")
        case .left: return String(localized: "Turn left", comment: "Walking maneuver.")
        case .sharpLeft: return String(localized: "Turn sharp left", comment: "Walking maneuver.")
        case .slightRight: return String(localized: "Bear right", comment: "Walking maneuver.")
        case .right: return String(localized: "Turn right", comment: "Walking maneuver.")
        case .sharpRight: return String(localized: "Turn sharp right", comment: "Walking maneuver.")
        case .uTurn: return String(localized: "Turn around", comment: "Walking maneuver.")
        case .crossStreet: return String(localized: "Cross the street", comment: "Walking maneuver.")
        case .takeStairs: return String(localized: "Take the stairs", comment: "Walking maneuver.")
        case .enterUnderpass: return String(localized: "Enter the underpass", comment: "Walking maneuver.")
        case .arrive: return String(localized: "Arrive at your destination", comment: "Walking maneuver.")
        }
    }

    var systemImage: String {
        switch self {
        case .depart: return "figure.walk"
        case .continueStraight: return "arrow.up"
        case .slightLeft: return "arrow.up.left"
        case .left: return "arrow.turn.up.left"
        case .sharpLeft: return "arrow.down.left"
        case .slightRight: return "arrow.up.right"
        case .right: return "arrow.turn.up.right"
        case .sharpRight: return "arrow.down.right"
        case .uTurn: return "arrow.uturn.left"
        case .crossStreet: return "arrow.left.and.right"
        case .takeStairs: return "figure.stairs"
        case .enterUnderpass: return "arrow.down.to.line"
        case .arrive: return "flag.checkered"
        }
    }
}

extension Maneuver {
    /// Full instruction, e.g. "Turn left onto Linden Avenue" (falls back to the kind's short text without a street).
    var instruction: String {
        guard let street = streetName?.trimmingCharacters(in: .whitespacesAndNewlines), !street.isEmpty else {
            return kind.displayName
        }
        switch kind {
        case .depart:
            return String(localized: "Head out on \(street)", comment: "Walking maneuver with a street name.")
        case .continueStraight:
            return String(localized: "Continue onto \(street)", comment: "Walking maneuver with a street name.")
        case .slightLeft:
            return String(localized: "Bear left onto \(street)", comment: "Walking maneuver with a street name.")
        case .left:
            return String(localized: "Turn left onto \(street)", comment: "Walking maneuver with a street name.")
        case .sharpLeft:
            return String(localized: "Turn sharp left onto \(street)", comment: "Walking maneuver with a street name.")
        case .slightRight:
            return String(localized: "Bear right onto \(street)", comment: "Walking maneuver with a street name.")
        case .right:
            return String(localized: "Turn right onto \(street)", comment: "Walking maneuver with a street name.")
        case .sharpRight:
            return String(localized: "Turn sharp right onto \(street)", comment: "Walking maneuver with a street name.")
        case .uTurn:
            return String(localized: "Turn around onto \(street)", comment: "Walking maneuver with a street name.")
        case .crossStreet:
            return String(localized: "Cross \(street)", comment: "Walking maneuver with a street name.")
        case .takeStairs:
            return String(localized: "Take the stairs to \(street)", comment: "Walking maneuver with a street name.")
        case .enterUnderpass:
            return String(localized: "Take the underpass to \(street)", comment: "Walking maneuver with a street name.")
        case .arrive:
            return kind.displayName
        }
    }
}

extension PlaceKind {
    var displayName: String {
        switch self {
        case .currentLocation: return String(localized: "My Location", comment: "The user's current location.")
        case .searchResult: return String(localized: "Place", comment: "Kind of a place found by search.")
        case .home: return String(localized: "Home", comment: "Saved place kind.")
        case .work: return String(localized: "Work", comment: "Saved place kind.")
        case .favorite: return String(localized: "Favorite", comment: "Saved place kind.")
        case .droppedPin: return String(localized: "Dropped pin", comment: "A place marked by long-pressing the map.")
        case .coolSpot: return String(localized: "Cool spot", comment: "A place to cool down (water, shade, indoors).")
        }
    }

    var systemImage: String {
        switch self {
        case .currentLocation: return "location.fill"
        case .searchResult: return "mappin"
        case .home: return "house.fill"
        case .work: return "briefcase.fill"
        case .favorite: return "star.fill"
        case .droppedPin: return "mappin.and.ellipse"
        case .coolSpot: return "leaf.fill"
        }
    }
}

extension Place {
    /// Name for display; the current location always reads "My Location" in the user's language.
    var displayName: String {
        kind == .currentLocation ? PlaceKind.currentLocation.displayName : name
    }

    /// Localized "My Location" place for `coordinate`.
    static func localizedCurrentLocation(_ coordinate: GeoCoordinate) -> Place {
        Place.currentLocation(coordinate, name: PlaceKind.currentLocation.displayName)
    }
}

extension UnitPreference {
    var displayName: String {
        switch self {
        case .system: return String(localized: "Automatic", comment: "Distance units follow the device region.")
        case .metric: return String(localized: "Metric", comment: "Distance units: metres and kilometres.")
        case .imperial: return String(localized: "Imperial", comment: "Distance units: feet and miles.")
        }
    }
}

extension WalkingSpeed {
    var displayName: String {
        switch self {
        case .slow: return String(localized: "Relaxed", comment: "Walking speed preset (slow).")
        case .normal: return String(localized: "Normal", comment: "Walking speed preset.")
        case .fast: return String(localized: "Brisk", comment: "Walking speed preset (fast).")
        }
    }

    var systemImage: String {
        switch self {
        case .slow: return "tortoise.fill"
        case .normal: return "figure.walk"
        case .fast: return "hare.fill"
        }
    }
}
