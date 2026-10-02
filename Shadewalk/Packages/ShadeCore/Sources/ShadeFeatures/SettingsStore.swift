import Foundation
import Observation
import ShadeCore

/// Walking-speed presets.
public enum WalkingSpeed: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case slow, normal, fast

    public var id: String { rawValue }

    /// Metres per second.
    public var metersPerSecond: Double {
        switch self {
        case .slow: 1.1
        case .normal: 1.35
        case .fast: 1.6
        }
    }
}

/// Distance units shown in the UI.
public enum UnitPreference: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    /// Follow the device locale.
    case system
    case metric
    case imperial

    public var id: String { rawValue }
}

/// User settings persisted as JSON.
public struct AppSettings: Hashable, Codable, Sendable {
    /// Allowed range for `maxDetourFraction`.
    public static let maxDetourRange: ClosedRange<Double> = 0...0.5

    public var walkingSpeed: WalkingSpeed
    /// Extra length accepted for a shadier route, `[0, 0.5]` of the fastest route.
    public var maxDetourFraction: Double
    public var avoidStairs: Bool
    public var units: UnitPreference
    public var showShadeOverlayByDefault: Bool
    public var hasCompletedOnboarding: Bool

    public init(walkingSpeed: WalkingSpeed = .normal, maxDetourFraction: Double = 0.25, avoidStairs: Bool = false,
                units: UnitPreference = .system, showShadeOverlayByDefault: Bool = false,
                hasCompletedOnboarding: Bool = false) {
        self.walkingSpeed = walkingSpeed
        self.maxDetourFraction = AppSettings.clampDetour(maxDetourFraction)
        self.avoidStairs = avoidStairs
        self.units = units
        self.showShadeOverlayByDefault = showShadeOverlayByDefault
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    public static let `default` = AppSettings()

    /// Preferences passed to route planning.
    public var routingPreferences: RoutingPreferences {
        RoutingPreferences(walkingSpeed: walkingSpeed.metersPerSecond, maxDetourFraction: maxDetourFraction,
                           avoidStairs: avoidStairs)
    }

    static func clampDetour(_ value: Double) -> Double {
        guard value.isFinite else { return 0.25 }
        return min(max(value, maxDetourRange.lowerBound), maxDetourRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case walkingSpeed, maxDetourFraction, avoidStairs, units, showShadeOverlayByDefault, hasCompletedOnboarding
    }

    /// Tolerant decoding: missing or unreadable fields fall back to their defaults instead of failing the whole value.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        self.init(
            walkingSpeed: (try? c.decodeIfPresent(WalkingSpeed.self, forKey: .walkingSpeed)) ?? d.walkingSpeed,
            maxDetourFraction: (try? c.decodeIfPresent(Double.self, forKey: .maxDetourFraction)) ?? d.maxDetourFraction,
            avoidStairs: (try? c.decodeIfPresent(Bool.self, forKey: .avoidStairs)) ?? d.avoidStairs,
            units: (try? c.decodeIfPresent(UnitPreference.self, forKey: .units)) ?? d.units,
            showShadeOverlayByDefault: (try? c.decodeIfPresent(Bool.self, forKey: .showShadeOverlayByDefault))
                ?? d.showShadeOverlayByDefault,
            hasCompletedOnboarding: (try? c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding))
                ?? d.hasCompletedOnboarding)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(walkingSpeed, forKey: .walkingSpeed)
        try c.encode(maxDetourFraction, forKey: .maxDetourFraction)
        try c.encode(avoidStairs, forKey: .avoidStairs)
        try c.encode(units, forKey: .units)
        try c.encode(showShadeOverlayByDefault, forKey: .showShadeOverlayByDefault)
        try c.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
    }
}

/// Keys used in the `KeyValueStore`.
public enum ShadeFeaturesStorageKeys {
    /// Settings JSON.
    public static let settings = "shadewalk.settings.v1"
    /// Recent places JSON.
    public static let recentPlaces = "shadewalk.recentPlaces.v1"
}

/// Observable user settings, persisted as JSON in a `KeyValueStore` on every change.
@MainActor @Observable
public final class SettingsStore {
    /// Current settings. Mutate through the typed properties or `update(_:)`.
    public private(set) var settings: AppSettings

    @ObservationIgnored private let store: KeyValueStore
    @ObservationIgnored private let key: String

    /// Loads settings from `store` (defaults when missing or unreadable).
    public init(store: KeyValueStore, key: String = ShadeFeaturesStorageKeys.settings) {
        self.store = store
        self.key = key
        if let data = store.data(forKey: key), let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .default
        }
    }

    /// Walking-speed preset.
    public var walkingSpeed: WalkingSpeed {
        get { settings.walkingSpeed }
        set { update { $0.walkingSpeed = newValue } }
    }

    /// Clamped to `AppSettings.maxDetourRange`.
    public var maxDetourFraction: Double {
        get { settings.maxDetourFraction }
        set { update { $0.maxDetourFraction = newValue } }
    }

    /// Penalise stairs when routing.
    public var avoidStairs: Bool {
        get { settings.avoidStairs }
        set { update { $0.avoidStairs = newValue } }
    }

    /// Distance units for display.
    public var units: UnitPreference {
        get { settings.units }
        set { update { $0.units = newValue } }
    }

    /// Shade overlay on when the map opens.
    public var showShadeOverlayByDefault: Bool {
        get { settings.showShadeOverlayByDefault }
        set { update { $0.showShadeOverlayByDefault = newValue } }
    }

    /// Onboarding has been shown.
    public var hasCompletedOnboarding: Bool {
        get { settings.hasCompletedOnboarding }
        set { update { $0.hasCompletedOnboarding = newValue } }
    }

    /// Preferences for route planning derived from the settings.
    public var routingPreferences: RoutingPreferences { settings.routingPreferences }

    /// Applies several changes at once and persists them (only if something changed).
    public func update(_ body: (inout AppSettings) -> Void) {
        var next = settings
        body(&next)
        next.maxDetourFraction = AppSettings.clampDetour(next.maxDetourFraction)
        guard next != settings else { return }
        settings = next
        persist()
    }

    /// Restores defaults, keeping the onboarding flag.
    public func resetToDefaults() {
        let onboarded = settings.hasCompletedOnboarding
        update { $0 = AppSettings(hasCompletedOnboarding: onboarded) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        store.set(data, forKey: key)
    }
}
