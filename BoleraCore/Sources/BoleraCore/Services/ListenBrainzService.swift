import Foundation
import Combine

/// ListenBrainz client: "playing now" updates and listen submission.
///
/// API documentation: https://listenbrainz.readthedocs.io/en/latest/users/api/core.html
///
/// Unlike Last.fm there's no app registration or password sign-in — the user
/// pastes the personal User Token from https://listenbrainz.org/settings/ and
/// every request sends it as `Authorization: Token <token>`. The token is kept
/// in the Keychain.
///
/// Listens carry MusicBrainz IDs when Jellyfin has them (looked up per track
/// at submit time), which lets ListenBrainz link the listen to the exact
/// recording instead of matching on text.
@MainActor
public final class ListenBrainzService: ObservableObject {
    public static let shared = ListenBrainzService()

    @Published public private(set) var token: String? = Keychain.get("listenbrainz.token")
    @Published public private(set) var username: String? = UserDefaults.standard.string(forKey: "listenbrainz.username")
    @Published public var enabled: Bool = UserDefaults.standard.bool(forKey: "listenbrainz.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "listenbrainz.enabled") }
    }

    public var isAuthenticated: Bool { token != nil }

    private let api = URL(string: "https://api.listenbrainz.org/1/")!

    public enum LBError: LocalizedError {
        case invalidToken
        case http(Int, String)
        public var errorDescription: String? {
            switch self {
            case .invalidToken: return "That token wasn't accepted. Copy the User Token from listenbrainz.org/settings."
            case .http(let code, let msg): return "ListenBrainz error \(code): \(msg)"
            }
        }
    }

    // MARK: - Listen payload

    /// One listen as ListenBrainz expects it. Codable so failed submissions
    /// can be queued to disk and replayed later with their original timestamp.
    struct Listen: Codable {
        var listened_at: Int?
        let track_metadata: TrackMetadata
    }
    struct TrackMetadata: Codable {
        let artist_name: String
        let track_name: String
        let release_name: String?
        let additional_info: AdditionalInfo
    }
    struct AdditionalInfo: Codable {
        let duration_ms: Int?
        let recording_mbid: String?
        let release_mbid: String?
        let release_group_mbid: String?
        let artist_mbids: [String]?
        let track_mbid: String?
        let tracknumber: Int?
        let media_player: String
        let media_player_version: String
        let submission_client: String
        let submission_client_version: String
    }
    private struct Submission: Encodable {
        let listen_type: String
        let payload: [Listen]
    }

    // MARK: - Offline queue

    private var pendingListens: [Listen] = []
    private var flushing = false
    private var reconnectCancellable: AnyCancellable?
    private static let pendingURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("bolera.pendingListens.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.pendingURL),
           let q = try? JSONDecoder().decode([Listen].self, from: data) {
            pendingListens = q
        }
        // Replay queued listens the moment the network is usable again.
        reconnectCancellable = ConnectivityStore.shared.didReconnect
            .sink { [weak self] in Task { await self?.flushPending() } }
        if !pendingListens.isEmpty { Task { await flushPending() } }
    }

    private func persistPending() {
        // Cap the queue so a long outage can't grow it unboundedly.
        if pendingListens.count > 500 {
            pendingListens.removeFirst(pendingListens.count - 500)
        }
        try? JSONEncoder().encode(pendingListens).write(to: Self.pendingURL, options: .atomic)
    }

    /// Submit queued listens as `import` batches (the API's bulk listen type).
    public func flushPending() async {
        guard enabled, let token, !flushing, !pendingListens.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        while !pendingListens.isEmpty {
            let batch = Array(pendingListens.prefix(100))
            do {
                try await submit(Submission(listen_type: "import", payload: batch), token: token)
                pendingListens.removeFirst(batch.count)
                persistPending()
            } catch {
                DebugLog.write("[ListenBrainz] flush failed, \(pendingListens.count) listens still queued — \(error.localizedDescription)")
                break
            }
        }
    }

    // MARK: - Account

    /// Validates the token with ListenBrainz and stores it on success.
    public func signIn(token raw: String) async throws {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { throw LBError.invalidToken }
        struct Validation: Decodable { let valid: Bool; let user_name: String? }
        var req = URLRequest(url: api.appendingPathComponent("validate-token"))
        req.setValue("Token \(candidate)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw LBError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let v = try JSONDecoder().decode(Validation.self, from: data)
        guard v.valid else { throw LBError.invalidToken }
        Keychain.set(candidate, for: "listenbrainz.token")
        token = candidate
        username = v.user_name
        UserDefaults.standard.set(v.user_name, forKey: "listenbrainz.username")
        enabled = true
        DebugLog.write("[ListenBrainz] signed in as \(v.user_name ?? "?")")
    }

    public func signOut() {
        token = nil
        username = nil
        enabled = false
        Keychain.delete("listenbrainz.token")
        UserDefaults.standard.removeObject(forKey: "listenbrainz.username")
        UserDefaults.standard.removeObject(forKey: "listenbrainz.enabled")
        pendingListens = []
        try? FileManager.default.removeItem(at: Self.pendingURL)
    }

    // MARK: - Submission

    /// `client` is used to look up the track's MusicBrainz IDs; pass nil for
    /// a text-only listen.
    public func updateNowPlaying(_ item: BaseItem, client: JellyfinClient?) async {
        guard enabled, let token else { return }
        let listen = await makeListen(item, listenedAt: nil, client: client)
        do {
            try await submit(Submission(listen_type: "playing_now", payload: [listen]), token: token)
        } catch {
            // Now-playing is ephemeral — not worth queueing.
            DebugLog.write("[ListenBrainz] playing_now failed — \(error.localizedDescription)")
        }
    }

    public func submitListen(_ item: BaseItem, startedAt: Date, client: JellyfinClient?) async {
        guard enabled, let token else { return }
        let listen = await makeListen(item, listenedAt: Int(startedAt.timeIntervalSince1970), client: client)
        do {
            try await submit(Submission(listen_type: "single", payload: [listen]), token: token)
            if !pendingListens.isEmpty { await flushPending() }
        } catch LBError.http(let code, let msg) where (400..<500).contains(code) && code != 429 {
            // Rejected (bad token, malformed listen) — retrying won't help.
            DebugLog.write("[ListenBrainz] listen rejected \(code): \(msg)")
        } catch {
            // Dead zone / outage: queue it. Listens carry their own timestamp,
            // so late submission lands at the right point in the history.
            pendingListens.append(listen)
            persistPending()
            DebugLog.write("[ListenBrainz] listen failed — queued (\(pendingListens.count) pending)")
        }
    }

    private func makeListen(_ item: BaseItem, listenedAt: Int?, client: JellyfinClient?) async -> Listen {
        let ids = await client?.providerIds(itemId: item.Id) ?? [:]
        func id(_ key: String) -> String? {
            guard let v = ids[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        // Jellyfin stores multiple artist MBIDs as one "/"-separated string.
        let artistMbids = id("MusicBrainzArtist")?
            .split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let artist = (item.Artists?.isEmpty == false ? item.Artists!.joined(separator: ", ") : item.primaryArtistName)
        let duration = item.durationSeconds > 0 ? Int(item.durationSeconds * 1000) : nil
        let version = AuthManager.clientVersion
        return Listen(
            listened_at: listenedAt,
            track_metadata: TrackMetadata(
                artist_name: artist,
                track_name: item.Name,
                release_name: (item.Album?.isEmpty == false) ? item.Album : nil,
                additional_info: AdditionalInfo(
                    duration_ms: duration,
                    recording_mbid: id("MusicBrainzRecording"),
                    release_mbid: id("MusicBrainzAlbum"),
                    release_group_mbid: id("MusicBrainzReleaseGroup"),
                    artist_mbids: (artistMbids?.isEmpty == false) ? artistMbids : nil,
                    track_mbid: id("MusicBrainzTrack"),
                    tracknumber: item.IndexNumber,
                    media_player: "Bolera",
                    media_player_version: version,
                    submission_client: "Bolera",
                    submission_client_version: version)))
    }

    private func submit(_ submission: Submission, token: String) async throws {
        var req = URLRequest(url: api.appendingPathComponent("submit-listens"))
        req.httpMethod = "POST"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15
        req.httpBody = try JSONEncoder().encode(submission)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            throw LBError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
