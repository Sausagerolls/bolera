import Foundation
import Combine

/// Per-user set of Jellyfin library IDs that the user has chosen to hide.
/// Persists to UserDefaults + iCloud-KVS so toggles roam across devices.
@MainActor
public final class LibraryVisibilityStore: ObservableObject {

    public static let shared = LibraryVisibilityStore()

    @Published public private(set) var hidden: Set<String>

    private static let key = "bolera.pro.hiddenLibraries"

    private init() {
        let defaults = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        let cloud = CloudKVS.stringArray(forKey: Self.key) ?? []
        self.hidden = Set(defaults).union(cloud)
        persistLocal()
        CloudKVS.synchronize()
        CloudKVS.addObserver(self, selector: #selector(cloudChanged))
    }

    @objc private nonisolated func cloudChanged(_ note: Notification) {
        Task { @MainActor in
            let updated = CloudKVS.stringArray(forKey: Self.key) ?? []
            self.hidden.formUnion(updated)
            self.persistLocal()
        }
    }

    public func isHidden(_ libraryId: String) -> Bool { hidden.contains(libraryId) }

    public func setHidden(_ libraryId: String, _ on: Bool) {
        if on { hidden.insert(libraryId) } else { hidden.remove(libraryId) }
        persistLocal()
        CloudKVS.set(Array(hidden), forKey: Self.key)
        CloudKVS.synchronize()
    }

    /// Drops items whose ParentId is in the hidden set.
    public func filter(_ items: [BaseItem]) -> [BaseItem] {
        guard !hidden.isEmpty else { return items }
        return items.filter { item in
            guard let pid = item.ParentId else { return true }
            return !hidden.contains(pid)
        }
    }

    private func persistLocal() {
        UserDefaults.standard.set(Array(hidden), forKey: Self.key)
    }
}
