import Foundation
import CryptoKit
import Combine

/// Libre.fm scrobbling. Libre.fm runs GNU FM, which speaks Last.fm's
/// AudioScrobbler 2.0 protocol at https://libre.fm/2.0/ — same methods, same
/// request signing — with two differences:
///
/// - No app registration: any 32-character API key is accepted, and the
///   signing secret isn't checked against a registered app.
/// - `auth.getMobileSession` doesn't take a plain `password`; it wants the
///   legacy `authToken = md5(username + md5(password))` (verified against the
///   live API: `password` returns error 6 "missing parameter", `authToken`
///   with bad credentials returns error 4 "invalid authentication token").
///
/// The session key is kept in the Keychain.
@MainActor
public final class LibreFmService: ObservableObject {
    public static let shared = LibreFmService()

    @Published public private(set) var sessionKey: String? = Keychain.get("librefm.sessionKey")
    @Published public private(set) var username: String? = UserDefaults.standard.string(forKey: "librefm.username")
    @Published public var enabled: Bool = UserDefaults.standard.bool(forKey: "librefm.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "librefm.enabled") }
    }
    /// Latest server rejection worth showing in Settings; cleared by the next
    /// accepted request.
    @Published public private(set) var lastError: String?

    public var isAuthenticated: Bool { sessionKey != nil }

    private let endpoint = URL(string: "https://libre.fm/2.0/")!
    /// Libre.fm accepts any 32-char key; this one identifies Bolera's requests.
    private let apiKey = "b01e7a0000000000000000000000b01e"
    private let apiSecret = "b01e7a0000000000000000000000b01e"

    public enum LibreFmError: LocalizedError {
        case message(String)
        public var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }

    // MARK: - Offline queue

    /// A scrobble that couldn't be submitted. Scrobbles carry their original
    /// timestamp, so late submission lands at the right point in the history.
    private struct PendingScrobble: Codable {
        let artist: String, track: String, album: String
        let duration: Int, timestamp: Int
    }
    private var pendingScrobbles: [PendingScrobble] = []
    private var flushing = false
    private var reconnectCancellable: AnyCancellable?
    private static let pendingURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("bolera.pendingLibreFmScrobbles.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: Self.pendingURL),
           let q = try? JSONDecoder().decode([PendingScrobble].self, from: data) {
            pendingScrobbles = q
        }
        reconnectCancellable = ConnectivityStore.shared.didReconnect
            .sink { [weak self] in Task { await self?.flushPending() } }
        if !pendingScrobbles.isEmpty { Task { await flushPending() } }
    }

    private func persistPending() {
        if pendingScrobbles.count > 500 {
            pendingScrobbles.removeFirst(pendingScrobbles.count - 500)
        }
        try? JSONEncoder().encode(pendingScrobbles).write(to: Self.pendingURL, options: .atomic)
    }

    /// Submit queued scrobbles in batches of 50 (the protocol's limit).
    public func flushPending() async {
        guard enabled, let session = sessionKey, !flushing, !pendingScrobbles.isEmpty else { return }
        flushing = true
        defer { flushing = false }
        while !pendingScrobbles.isEmpty {
            let batch = Array(pendingScrobbles.prefix(50))
            var params = ["method": "track.scrobble", "api_key": apiKey, "sk": session]
            for (i, s) in batch.enumerated() {
                params["artist[\(i)]"] = s.artist
                params["track[\(i)]"] = s.track
                params["album[\(i)]"] = s.album
                params["timestamp[\(i)]"] = String(s.timestamp)
                params["duration[\(i)]"] = String(s.duration)
            }
            do {
                try await call(params)
                pendingScrobbles.removeFirst(batch.count)
                persistPending()
            } catch {
                DebugLog.write("[LibreFm] flush failed, \(pendingScrobbles.count) scrobbles still queued — \(error.localizedDescription)")
                break
            }
        }
    }

    // MARK: - Account

    public func signIn(username: String, password: String) async throws {
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = md5(user + md5(password))
        struct SessionResponse: Decodable {
            struct Session: Decodable { let name: String; let key: String }
            let session: Session
        }
        let data = try await call(["method": "auth.getMobileSession",
                                   "username": user,
                                   "authToken": token,
                                   "api_key": apiKey])
        let s = try JSONDecoder().decode(SessionResponse.self, from: data).session
        sessionKey = s.key
        self.username = s.name
        Keychain.set(s.key, for: "librefm.sessionKey")
        UserDefaults.standard.set(s.name, forKey: "librefm.username")
        enabled = true
        lastError = nil
        DebugLog.write("[LibreFm] signed in as \(s.name)")
    }

    public func signOut() {
        sessionKey = nil
        username = nil
        enabled = false
        lastError = nil
        Keychain.delete("librefm.sessionKey")
        UserDefaults.standard.removeObject(forKey: "librefm.username")
        UserDefaults.standard.removeObject(forKey: "librefm.enabled")
        pendingScrobbles = []
        try? FileManager.default.removeItem(at: Self.pendingURL)
    }

    // MARK: - Scrobbling

    public func updateNowPlaying(_ item: BaseItem) async {
        guard enabled, let session = sessionKey else { return }
        do {
            try await call(["method": "track.updateNowPlaying",
                            "artist": item.primaryArtistName,
                            "track": item.Name,
                            "album": item.Album ?? "",
                            "duration": String(Int(item.durationSeconds)),
                            "api_key": apiKey, "sk": session])
        } catch {
            // Now-playing is ephemeral — not worth queueing.
            DebugLog.write("[LibreFm] updateNowPlaying failed — \(error.localizedDescription)")
        }
    }

    public func scrobble(_ item: BaseItem, startedAt: Date) async {
        guard enabled, let session = sessionKey else { return }
        let s = PendingScrobble(artist: item.primaryArtistName, track: item.Name,
                                album: item.Album ?? "", duration: Int(item.durationSeconds),
                                timestamp: Int(startedAt.timeIntervalSince1970))
        do {
            try await call(["method": "track.scrobble",
                            "artist[0]": s.artist, "track[0]": s.track, "album[0]": s.album,
                            "timestamp[0]": String(s.timestamp), "duration[0]": String(s.duration),
                            "api_key": apiKey, "sk": session])
            if !pendingScrobbles.isEmpty { await flushPending() }
        } catch {
            // Dead zone / outage: queue it.
            pendingScrobbles.append(s)
            persistPending()
            DebugLog.write("[LibreFm] scrobble failed — queued (\(pendingScrobbles.count) pending): \(error.localizedDescription)")
        }
    }

    // MARK: - Signing + POST

    private func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02hhx", $0) }.joined()
    }

    /// Signs (sorted params + secret, MD5; `format` excluded), POSTs as a form,
    /// and returns the body. Throws the server's message on an API error.
    @discardableResult
    private func call(_ params: [String: String]) async throws -> Data {
        var all = params
        all["api_sig"] = md5(params.keys.sorted().map { "\($0)\(params[$0] ?? "")" }.joined() + apiSecret)
        all["format"] = "json"
        // Encode strictly: `+` and `&` in titles must not survive as literals.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = all.map { k, v in
            "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&")
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        struct APIError: Decodable { let error: Int?; let message: String? }
        if let e = try? JSONDecoder().decode(APIError.self, from: data), e.error != nil {
            let msg = e.message ?? "Libre.fm error \(e.error!)"
            lastError = msg
            throw LibreFmError.message(msg)
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            lastError = "Libre.fm returned HTTP \(code)"
            throw LibreFmError.message("HTTP \(code)")
        }
        lastError = nil
        return data
    }
}
