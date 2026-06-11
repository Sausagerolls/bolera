import Foundation
import Combine

/// Offline-tolerant favourite state.
///
/// A toggle updates the in-app belief immediately (optimistic), persists the
/// intent, and attempts the network write now — retrying automatically when
/// connectivity returns. So favouriting in a dead zone (e.g. CarPlay on a drive)
/// is never lost: the heart stays set locally and syncs to Jellyfin later.
///
/// UI reads `isFavorite(_:)` and observes this object; `reconcile` refreshes a
/// track's state from a fresh server read WITHOUT clobbering an unsynced change.
@MainActor
public final class FavoritesSync: ObservableObject {
    public static let shared = FavoritesSync()

    /// The app's current belief of each item's favourite state (optimistic +
    /// confirmed). Wins over a cached `UserData.IsFavorite`.
    @Published public private(set) var state: [String: Bool] = [:]
    /// Ids whose desired state hasn't been confirmed on the server yet. These
    /// are the ones persisted + replayed on reconnect.
    private var pendingIds: Set<String> = []
    private var cancellables = Set<AnyCancellable>()
    private var flushing = false

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("bolera.pendingFavorites.json")
    }()

    private init() {
        load()
        // Replay any queued favourites the moment the server is reachable again.
        ConnectivityStore.shared.didReconnect
            .sink { [weak self] _ in self?.flushNow() }
            .store(in: &cancellables)
    }

    // MARK: - Read

    public func isFavorite(_ item: BaseItem) -> Bool {
        state[item.Id] ?? (item.UserData?.IsFavorite ?? false)
    }

    public func isFavorite(id: String, fallback: Bool) -> Bool {
        state[id] ?? fallback
    }

    // MARK: - Toggle

    /// Set/clear a favourite. Optimistic + queued + retried; safe offline.
    /// Call on the main thread (all UI/CarPlay button handlers are).
    public func setFavorite(_ id: String, favorite: Bool, client: JellyfinClient) {
        state[id] = favorite
        pendingIds.insert(id)
        persist()
        Task { await attempt(id: id, favorite: favorite, client: client) }
    }

    /// Update a track's state from a fresh server read — but never overwrite an
    /// unsynced pending toggle (the offline favourite must win until it syncs).
    public func reconcile(id: String, serverFavorite: Bool) {
        guard !pendingIds.contains(id) else { return }
        if state[id] != serverFavorite { state[id] = serverFavorite }
    }

    private func attempt(id: String, favorite: Bool, client: JellyfinClient) async {
        do {
            try await client.setFavorite(id, favorite: favorite)
            // Only clear if the user hasn't toggled it again since.
            if state[id] == favorite { pendingIds.remove(id); persist() }
        } catch {
            // Keep queued — flushed on the next reconnect / launch.
        }
    }

    // MARK: - Flush

    /// Replay every queued favourite. Call on reconnect / launch / foreground.
    public func flushNow() {
        guard let url = AuthManager.shared.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: AuthManager.shared)
        Task { await flush(client: client) }
    }

    public func flush(client: JellyfinClient) async {
        guard !flushing, !pendingIds.isEmpty else { return }
        flushing = true
        let snapshot = pendingIds.reduce(into: [String: Bool]()) { $0[$1] = state[$1] }
        for (id, fav) in snapshot {
            do {
                try await client.setFavorite(id, favorite: fav)
                if state[id] == fav { pendingIds.remove(id) }
            } catch {
                // Leave queued; a later flush retries.
            }
        }
        flushing = false
        persist()
    }

    // MARK: - Persistence (only the unsynced desired states need to survive)

    private func persist() {
        let snapshot = pendingIds.reduce(into: [String: Bool]()) { acc, id in
            if let v = state[id] { acc[id] = v }
        }
        try? JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode([String: Bool].self, from: data) else { return }
        for (id, v) in snapshot { state[id] = v; pendingIds.insert(id) }
    }
}
