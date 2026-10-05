import Foundation
import ShadeFeatures

/// `KeyValueStore` backed by `UserDefaults` (settings JSON, recent places).
final class UserDefaultsStore: KeyValueStore, @unchecked Sendable {
    // UserDefaults is documented as thread-safe; the wrapper holds no other state.
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        if let data {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
