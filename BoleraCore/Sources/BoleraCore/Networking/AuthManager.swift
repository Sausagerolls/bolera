import Foundation
import Security
import Combine

/// Persists Jellyfin server URL + access token + user id in the Keychain,
/// and exposes login / logout to the rest of the app.
public final class AuthManager: ObservableObject {
    /// Process-wide singleton so non-SwiftUI scenes (CarPlay) can read auth state.
    public static let shared = AuthManager()

    public static let deviceId: String = {
        if let existing = UserDefaults.standard.string(forKey: "bolera.deviceId") {
            return existing
        }
        let new = UUID().uuidString
        UserDefaults.standard.set(new, forKey: "bolera.deviceId")
        return new
    }()

    public static let clientName = "Bolera"
    public static let clientVersion = "1.0.0"
    public static let deviceName: String = {
        #if os(iOS)
        return UIDeviceWrapper.modelName
        #else
        return "iOS Device"
        #endif
    }()

    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var serverURL: URL?
    @Published public private(set) var userId: String?
    @Published public private(set) var userName: String?
    @Published public private(set) var accessToken: String?

    public init() {
        load()
    }

    public func load() {
        if let urlString = Keychain.get("server"),
           let url = URL(string: urlString),
           let token = Keychain.get("token"),
           let uid = Keychain.get("userId") {
            self.serverURL = url
            self.accessToken = token
            self.userId = uid
            self.userName = Keychain.get("userName")
            self.isAuthenticated = true
            // We just read successfully (device unlocked at least once), so
            // upgrade any legacy items to AfterFirstUnlock in place.
            Keychain.migrateAccessibilityIfNeeded()
        }
    }

    /// Builds the value used in the `Authorization: MediaBrowser ...` header.
    public func authHeader() -> String {
        var parts = [
            "Client=\"\(Self.clientName)\"",
            "Device=\"\(Self.deviceName)\"",
            "DeviceId=\"\(Self.deviceId)\"",
            "Version=\"\(Self.clientVersion)\""
        ]
        if let token = accessToken {
            parts.append("Token=\"\(token)\"")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    public func login(server: URL, username: String, password: String) async throws {
        let client = JellyfinClient(baseURL: server, auth: self)
        let response = try await client.authenticate(username: username, password: password)
        await MainActor.run {
            self.serverURL = server
            self.accessToken = response.AccessToken
            self.userId = response.User.Id
            self.userName = response.User.Name
            Keychain.set(server.absoluteString, for: "server")
            Keychain.set(response.AccessToken, for: "token")
            Keychain.set(response.User.Id, for: "userId")
            Keychain.set(response.User.Name, for: "userName")
            self.isAuthenticated = true
        }
    }

    public func logout() {
        AudioPlayer.shared.stop()
        Keychain.delete("server")
        Keychain.delete("token")
        Keychain.delete("userId")
        Keychain.delete("userName")
        wipeServerScopedCaches()
        // A full sign-out should clear linked accounts too, not just the
        // Jellyfin session — drop the Last.fm session.
        Task { @MainActor in LastFmService.shared.signOut() }
        // The library cache + artwork were just wiped, so the next login should
        // re-run the prefetch onboarding (and re-show the "Preparing your
        // library" screen). Clear the flags it gates on.
        UserDefaults.standard.removeObject(forKey: "bolera.onboarding.prefetchDone")
        UserDefaults.standard.removeObject(forKey: "bolera.prefetch.lastCompleted")
        NotificationCenter.default.post(name: Notification.Name("boleraDidLogout"), object: nil)
        self.serverURL = nil
        self.accessToken = nil
        self.userId = nil
        self.userName = nil
        self.isAuthenticated = false
    }

    /// Removes disk caches that are scoped to a specific Jellyfin server —
    /// item lookups, downloaded artwork, library snapshots. Pro state and
    /// Last.fm credentials are intentionally preserved (they belong to the
    /// user, not the server).
    private func wipeServerScopedCaches() {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        for sub in ["ImageCache", "LibraryCache", "DailyArtwork"] {
            try? fm.removeItem(at: caches.appendingPathComponent(sub))
        }
    }
}

#if canImport(UIKit)
import UIKit
enum UIDeviceWrapper {
    static var modelName: String { UIDevice.current.name }
}
#endif

// MARK: - Keychain helper

enum Keychain {
    private static let service = "com.bolera.credentials"

    static func set(_ value: String, for key: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        // Readable while the device is locked (after first post-boot unlock) so a
        // background CarPlay relaunch on a locked phone can restore the session
        // instead of dumping the user to the login screen.
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    /// One-time upgrade of legacy items written with the default
    /// kSecAttrAccessibleWhenUnlocked so they survive a locked-phone background
    /// relaunch. Safe to call repeatedly; a no-op once the flag is set.
    static func migrateAccessibilityIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "bolera.keychainAccessibilityMigrated") else { return }
        for key in ["server", "token", "userId", "userName"] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: key
            ]
            let attrs: [String: Any] = [
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        }
        UserDefaults.standard.set(true, forKey: "bolera.keychainAccessibilityMigrated")
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}
