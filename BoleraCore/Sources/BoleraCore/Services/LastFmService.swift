import Foundation
import CryptoKit
import Combine

/// Last.fm "AudioScrobbler 2.0" client. Implements the calls needed to scrobble
/// from a media player: mobile-session auth, track.updateNowPlaying, track.scrobble.
///
/// API documentation: https://www.last.fm/api/scrobbling
///
/// The user must supply their own API key + shared secret in Settings (Last.fm
/// requires a registered application). Once authenticated, the session key is
/// persisted in the Keychain.
@MainActor
public final class LastFmService: ObservableObject {
    public static let shared = LastFmService()

    /// Bolera's registered Last.fm app credentials. Fill these once after
    /// registering at https://www.last.fm/api/account/create — all users then
    /// sign in with just their Last.fm username + password.
    /// Embedding the secret is standard practice for media-player clients.
    public static let appAPIKey    = LastFmSecrets.apiKey
    public static let appAPISecret = LastFmSecrets.apiSecret

    /// User-supplied override (advanced). Defaults to empty; when empty,
    /// `effectiveAPIKey`/`effectiveAPISecret` fall back to the baked-in app
    /// credentials above.
    @Published public var apiKey: String = UserDefaults.standard.string(forKey: "lastfm.apiKey") ?? "" {
        didSet { UserDefaults.standard.set(apiKey, forKey: "lastfm.apiKey") }
    }
    @Published public var apiSecret: String = UserDefaults.standard.string(forKey: "lastfm.apiSecret") ?? "" {
        didSet { UserDefaults.standard.set(apiSecret, forKey: "lastfm.apiSecret") }
    }
    @Published public private(set) var sessionKey: String? = Keychain.get("lastfm.sessionKey")
    @Published public private(set) var username: String? = UserDefaults.standard.string(forKey: "lastfm.username")
    @Published public var enabled: Bool = UserDefaults.standard.bool(forKey: "lastfm.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "lastfm.enabled") }
    }

    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    /// Resolved key/secret used for every Last.fm call. Prefers user override.
    public var effectiveAPIKey: String {
        apiKey.isEmpty ? Self.appAPIKey : apiKey
    }
    public var effectiveAPISecret: String {
        apiSecret.isEmpty ? Self.appAPISecret : apiSecret
    }

    /// True once Bolera (or the user) has supplied real credentials —
    /// i.e. the placeholders above have been replaced.
    public var hasAppCredentials: Bool {
        let key = effectiveAPIKey
        let secret = effectiveAPISecret
        return !key.isEmpty && !secret.isEmpty &&
               !key.hasPrefix("YOUR_") && !secret.hasPrefix("YOUR_")
    }

    public var isAuthenticated: Bool { sessionKey != nil }

    public func signIn(username: String, password: String) async throws {
        guard hasAppCredentials else {
            throw LastFmError.message("Last.fm is not configured in this build. Contact the developer.")
        }
        var params = [
            "method": "auth.getMobileSession",
            "username": username,
            "password": password,
            "api_key": effectiveAPIKey
        ]
        params["api_sig"] = signature(params)
        params["format"] = "json"
        let response: SessionResponse = try await post(params)
        await MainActor.run {
            self.sessionKey = response.session.key
            self.username = response.session.name
            Keychain.set(response.session.key, for: "lastfm.sessionKey")
            UserDefaults.standard.set(response.session.name, forKey: "lastfm.username")
        }
    }

    public func signOut() {
        sessionKey = nil
        username = nil
        Keychain.delete("lastfm.sessionKey")
        UserDefaults.standard.removeObject(forKey: "lastfm.username")
    }

    public func updateNowPlaying(_ item: BaseItem) async {
        guard enabled, let session = sessionKey, hasAppCredentials else { return }
        var params = [
            "method": "track.updateNowPlaying",
            "artist": item.primaryArtistName,
            "track": item.Name,
            "album": item.Album ?? "",
            "duration": String(Int(item.durationSeconds)),
            "api_key": effectiveAPIKey,
            "sk": session
        ]
        params["api_sig"] = signature(params)
        params["format"] = "json"
        _ = try? await post(params) as VoidResponse
    }

    public func scrobble(_ item: BaseItem, startedAt: Date) async {
        guard enabled, let session = sessionKey, hasAppCredentials else { return }
        var params = [
            "method": "track.scrobble",
            "artist[0]": item.primaryArtistName,
            "track[0]": item.Name,
            "album[0]": item.Album ?? "",
            "timestamp[0]": String(Int(startedAt.timeIntervalSince1970)),
            "duration[0]": String(Int(item.durationSeconds)),
            "api_key": effectiveAPIKey,
            "sk": session
        ]
        params["api_sig"] = signature(params)
        params["format"] = "json"
        _ = try? await post(params) as VoidResponse
    }

    // MARK: - Similar artists (artist.getSimilar — read-only, no session needed)

    public struct SimilarArtist: Codable, Hashable, Identifiable, Sendable {
        public let name: String
        public let mbid: String?
        public let url: String?
        public var id: String {
            if let m = mbid, !m.isEmpty { return m }
            if let u = url, !u.isEmpty { return u }
            return name
        }
    }

    /// Returns Last.fm's curated similar artists for the given artist name.
    /// Requires only an API key (no user session).
    public func similarArtists(forName name: String, limit: Int = 5) async throws -> [SimilarArtist] {
        guard hasAppCredentials else {
            throw LastFmError.message("Last.fm not configured")
        }
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "artist.getsimilar"),
            URLQueryItem(name: "artist", value: name),
            URLQueryItem(name: "api_key", value: effectiveAPIKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "autocorrect", value: "1")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LastFmError.message("Last.fm HTTP error")
        }
        struct Wrapper: Decodable {
            struct SimilarArtists: Decodable {
                let artist: [SimilarArtist]
            }
            let similarartists: SimilarArtists
        }
        let wrapped = try JSONDecoder().decode(Wrapper.self, from: data)
        return wrapped.similarartists.artist
    }

    // MARK: - Top artists for a tag (tag.getTopArtists)

    public struct TagArtist: Codable, Hashable, Identifiable, Sendable {
        public let name: String
        public let mbid: String?
        public var id: String { mbid?.isEmpty == false ? mbid! : name }
    }

    /// Returns the most popular artists on Last.fm for a given tag.
    /// Read-only; only needs an API key. Useful for mood-based mixes —
    /// "chill" or "synthwave" → curated artist list that we can intersect
    /// with the user's Jellyfin library.
    public func topArtists(forTag tag: String, limit: Int = 30) async throws -> [TagArtist] {
        guard hasAppCredentials else {
            throw LastFmError.message("Last.fm not configured")
        }
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "tag.gettopartists"),
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "api_key", value: effectiveAPIKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "format", value: "json")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LastFmError.message("Last.fm HTTP error")
        }
        struct Wrapper: Decodable {
            struct Top: Decodable { let artist: [TagArtist] }
            let topartists: Top
        }
        let wrapped = try JSONDecoder().decode(Wrapper.self, from: data)
        return wrapped.topartists.artist
    }

    // MARK: - Top tracks for a tag (tag.getTopTracks)

    public struct TagTrack: Codable, Hashable, Identifiable, Sendable {
        public struct Artist: Codable, Hashable, Sendable {
            public let name: String
        }
        public let name: String
        public let artist: Artist
        public var id: String { "\(artist.name.lowercased())|\(name.lowercased())" }
    }

    /// Returns the most popular tracks tagged with `tag` worldwide. Use to
    /// expand mood tags (e.g. "chill", "morning") into concrete track names
    /// you can then match against the user's library by title + artist.
    public func topTracks(forTag tag: String, limit: Int = 50) async throws -> [TagTrack] {
        guard hasAppCredentials else {
            throw LastFmError.message("Last.fm not configured")
        }
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "tag.gettoptracks"),
            URLQueryItem(name: "tag", value: tag),
            URLQueryItem(name: "api_key", value: effectiveAPIKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "format", value: "json")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LastFmError.message("Last.fm HTTP error")
        }
        struct Wrapper: Decodable {
            struct Top: Decodable { let track: [TagTrack] }
            let tracks: Top
        }
        let wrapped = try JSONDecoder().decode(Wrapper.self, from: data)
        return wrapped.tracks.track
    }

    // MARK: - Top tracks (artist.getTopTracks)

    public struct TopTrack: Codable, Hashable, Identifiable, Sendable {
        public let name: String
        public let mbid: String?
        public let url: String?
        public var id: String {
            if let m = mbid, !m.isEmpty { return m }
            return name
        }
    }

    /// Returns Last.fm's globally most-played tracks for the artist.
    /// Read-only, only needs an API key.
    public func topTracks(forName name: String, limit: Int = 10) async throws -> [TopTrack] {
        guard hasAppCredentials else {
            throw LastFmError.message("Last.fm not configured")
        }
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "artist.gettoptracks"),
            URLQueryItem(name: "artist", value: name),
            URLQueryItem(name: "api_key", value: effectiveAPIKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "autocorrect", value: "1")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LastFmError.message("Last.fm HTTP error")
        }
        struct Wrapper: Decodable {
            struct TopTracks: Decodable { let track: [TopTrack] }
            let toptracks: TopTracks
        }
        let wrapped = try JSONDecoder().decode(Wrapper.self, from: data)
        return wrapped.toptracks.track
    }

    // MARK: - Similar tracks (track.getSimilar)

    public struct SimilarTrack: Codable, Hashable, Sendable {
        public struct Artist: Codable, Hashable, Sendable { public let name: String }
        public let name: String
        public let artist: Artist
    }

    /// Last.fm's track-level "sounds-like" recommendations for a specific
    /// (artist, track). This is the strongest radio signal — far better than
    /// artist/genre similarity for a coherent mix — because it's derived from
    /// real co-listening data. Read-only; only needs an API key. Returns []
    /// (not an error) when Last.fm has no matches for the seed.
    public func similarTracks(artist: String, track: String, limit: Int = 50) async throws -> [SimilarTrack] {
        guard hasAppCredentials else { throw LastFmError.message("Last.fm not configured") }
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "track.getsimilar"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "track", value: track),
            URLQueryItem(name: "api_key", value: effectiveAPIKey),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "autocorrect", value: "1")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LastFmError.message("Last.fm HTTP error")
        }
        struct Wrapper: Decodable {
            struct Similar: Decodable { let track: [SimilarTrack]? }
            let similartracks: Similar?
        }
        // track.getsimilar returns an empty/object-less `similartracks` when
        // there are no matches, so decode leniently and default to [].
        let wrapped = try? JSONDecoder().decode(Wrapper.self, from: data)
        return wrapped?.similartracks?.track ?? []
    }

    // MARK: - Artist info / bio (artist.getInfo)

    public struct ArtistBio: Sendable {
        public let summary: String  // plain text, HTML stripped
        public let url: String?
    }

    /// Returns Last.fm's bio summary for the given artist, plain text.
    /// Returns nil if unavailable.
    public func artistInfo(forName name: String) async throws -> ArtistBio? {
        guard hasAppCredentials else { return nil }
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "method", value: "artist.getinfo"),
            URLQueryItem(name: "artist", value: name),
            URLQueryItem(name: "api_key", value: effectiveAPIKey),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "autocorrect", value: "1")
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LastFmError.message("Last.fm HTTP error")
        }
        struct Wrapper: Decodable {
            struct Artist: Decodable {
                struct Bio: Decodable {
                    let summary: String?
                    let content: String?
                }
                let bio: Bio?
                let url: String?
            }
            let artist: Artist?
        }
        let wrapped = try JSONDecoder().decode(Wrapper.self, from: data)
        guard let raw = wrapped.artist?.bio?.summary, !raw.isEmpty else { return nil }
        let cleaned = Self.stripHTML(raw)
        guard !cleaned.isEmpty else { return nil }
        return ArtistBio(summary: cleaned, url: wrapped.artist?.url)
    }

    /// Strip basic HTML tags (Last.fm bio summaries contain `<a>` tags).
    /// Also removes the trailing "Read more on Last.fm" link text that
    /// remains after the surrounding `<a>` is stripped.
    private static func stripHTML(_ s: String) -> String {
        let withoutTags = s.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        let decoded = withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        // Drop the trailing "Read more on Last.fm" call-to-action and any
        // dangling whitespace/punctuation that surrounded the link.
        let trimmed = decoded.replacingOccurrences(
            of: "\\s*\\.{0,3}\\s*Read more on Last\\.fm\\.?\\s*$",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Signing + POST

    /// Last.fm signs requests by concatenating all params (sorted), then the secret,
    /// then taking the MD5 of the result. `api_sig` and `format` are excluded.
    private func signature(_ params: [String: String]) -> String {
        let keys = params.keys.sorted()
        let concat = keys.map { "\($0)\(params[$0] ?? "")" }.joined() + effectiveAPISecret
        let digest = Insecure.MD5.hash(data: Data(concat.utf8))
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    private func post<T: Decodable>(_ params: [String: String]) async throws -> T {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw LastFmError.message("Invalid response") }
        if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data), err.error != nil {
            throw LastFmError.message(err.message ?? "Last.fm error")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LastFmError.message("HTTP \(http.statusCode)")
        }
        if T.self == VoidResponse.self { return VoidResponse() as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Codable

    struct SessionResponse: Decodable {
        struct Session: Decodable { let name: String; let key: String }
        let session: Session
    }
    struct VoidResponse: Decodable {}
    struct ErrorResponse: Decodable { let error: Int?; let message: String? }

    public enum LastFmError: LocalizedError {
        case message(String)
        public var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }
}
