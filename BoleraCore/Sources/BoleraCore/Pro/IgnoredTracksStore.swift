import Foundation
import Combine

/// Per-user set of Jellyfin track item IDs to silently skip.
/// Persists to UserDefaults + iCloud-KVS.
@MainActor
public final class IgnoredTracksStore: ObservableObject {

    public static let shared = IgnoredTracksStore()

    @Published public private(set) var ignored: Set<String>
    /// User-friendly display map: id → "Track Name — Artist" populated by the
    /// app as tracks get added so the ignore-list UI can render rows even
    /// when the user is offline.
    @Published public private(set) var labels: [String: String]

    private static let idsKey = "bolera.pro.ignoredTracks"
    private static let labelsKey = "bolera.pro.ignoredTrackLabels"

    private init() {
        let local = UserDefaults.standard.stringArray(forKey: Self.idsKey) ?? []
        let cloud = CloudKVS.stringArray(forKey: Self.idsKey) ?? []
        self.ignored = Set(local).union(cloud)
        let localLabels = UserDefaults.standard.dictionary(forKey: Self.labelsKey) as? [String: String] ?? [:]
        let cloudLabels = CloudKVS.dictionary(forKey: Self.labelsKey) ?? [:]
        self.labels = localLabels.merging(cloudLabels) { $1 }
        persistLocal()
        CloudKVS.synchronize()
        CloudKVS.addObserver(self, selector: #selector(cloudChanged))
    }

    @objc private nonisolated func cloudChanged(_ note: Notification) {
        Task { @MainActor in
            let ids = CloudKVS.stringArray(forKey: Self.idsKey) ?? []
            let lbl = CloudKVS.dictionary(forKey: Self.labelsKey) ?? [:]
            self.ignored.formUnion(ids)
            self.labels.merge(lbl) { $1 }
            self.persistLocal()
        }
    }

    public func isIgnored(_ id: String) -> Bool { ignored.contains(id) }

    public func ignore(_ item: BaseItem) {
        ignored.insert(item.Id)
        labels[item.Id] = "\(item.Name) — \(item.primaryArtistName)"
        persistLocal()
        sync()
    }

    public func unignore(_ id: String) {
        ignored.remove(id)
        labels.removeValue(forKey: id)
        persistLocal()
        sync()
    }

    /// Drops ignored items from a list. Cheap O(n).
    public func filter(_ items: [BaseItem]) -> [BaseItem] {
        guard !ignored.isEmpty else { return items }
        return items.filter { !ignored.contains($0.Id) }
    }

    private func persistLocal() {
        UserDefaults.standard.set(Array(ignored), forKey: Self.idsKey)
        UserDefaults.standard.set(labels, forKey: Self.labelsKey)
    }

    private func sync() {
        CloudKVS.set(Array(ignored), forKey: Self.idsKey)
        CloudKVS.set(labels, forKey: Self.labelsKey)
        CloudKVS.synchronize()
    }
}
