import Foundation
import Security

/// Lazy wrapper around `NSUbiquitousKeyValueStore` that no-ops when the
/// `com.apple.developer.ubiquity-kvstore-identifier` entitlement is missing.
/// Without this, KVS prints a "BUG IN CLIENT" warning on first access.
public enum CloudKVS {

    public static let isAvailable: Bool = {
        #if canImport(AppKit)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.ubiquity-kvstore-identifier" as CFString, nil
        )
        return value != nil
        #else
        // iOS: assume available; KVS calls no-op gracefully without the
        // entitlement and don't spam "BUG IN CLIENT" warnings the way the
        // Mac runtime does.
        return true
        #endif
    }()

    public static func stringArray(forKey key: String) -> [String]? {
        guard isAvailable else { return nil }
        return NSUbiquitousKeyValueStore.default.array(forKey: key) as? [String]
    }

    public static func dictionary(forKey key: String) -> [String: String]? {
        guard isAvailable else { return nil }
        return NSUbiquitousKeyValueStore.default.dictionary(forKey: key) as? [String: String]
    }

    public static func data(forKey key: String) -> Data? {
        guard isAvailable else { return nil }
        return NSUbiquitousKeyValueStore.default.data(forKey: key)
    }

    public static func removeObject(forKey key: String) {
        guard isAvailable else { return }
        NSUbiquitousKeyValueStore.default.removeObject(forKey: key)
    }

    public static func set(_ value: Any?, forKey key: String) {
        guard isAvailable else { return }
        NSUbiquitousKeyValueStore.default.set(value, forKey: key)
    }

    public static func synchronize() {
        guard isAvailable else { return }
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    public static func addObserver(_ observer: Any, selector: Selector) {
        guard isAvailable else { return }
        NotificationCenter.default.addObserver(
            observer, selector: selector,
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
    }
}
