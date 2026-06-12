import Foundation

/// Caches the resolved IPv4 of a `.local` (mDNS / Bonjour) server host. `.local`
/// names only resolve on the home LAN, so off-network (Tailscale, other Wi-Fi,
/// cellular) the app can't connect. We resolve it while at home and reuse the
/// IP everywhere after — the user's configured address stays `baldur.local`;
/// the app just connects by the cached IP, which is reachable over Tailscale.
enum ServerHostCache {
    static func cachedIP(for host: String) -> String? {
        UserDefaults.standard.string(forKey: "bolera.hostip.\(host)")
    }

    /// Resolve `name` to an IPv4 and, on success, cache it under `key`. BLOCKING
    /// (getaddrinfo) — call off the main thread. Returns whether it resolved.
    @discardableResult
    static func tryResolve(_ name: String, key: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &res) == 0 else { return false }
        defer { freeaddrinfo(res) }
        var node = res
        while let cur = node {
            if cur.pointee.ai_family == AF_INET, let sa = cur.pointee.ai_addr {
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    var addr = sin.pointee.sin_addr
                    inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
                }
                let ip = String(cString: buf)
                if !ip.isEmpty, ip != "0.0.0.0" {
                    UserDefaults.standard.set(ip, forKey: "bolera.hostip.\(key)")
                    DebugLog.write("[Host] resolved \(name) -> \(ip) (for \(key))")
                    return true
                }
            }
            node = cur.pointee.ai_next
        }
        return false
    }

    /// Resolve the configured server host (if it's a `.local` name) in the
    /// background and cache its IP. Tries the `.local` mDNS name (resolves on the
    /// home LAN) and, if that fails, the bare machine name — which Tailscale
    /// MagicDNS may resolve off-network, so it can work out-of-the-box when away
    /// without a prior home session. No-op for IPs / non-.local hostnames.
    static func refreshIfLocal() {
        guard let host = AuthManager.shared.serverURL?.host, host.hasSuffix(".local") else { return }
        let bare = String(host.dropLast(".local".count))
        DispatchQueue.global(qos: .utility).async {
            if !tryResolve(host, key: host), !bare.isEmpty {
                tryResolve(bare, key: host)
            }
        }
    }
}

/// Thin wrapper around the Jellyfin REST API.
public struct JellyfinClient {
    private let configuredBaseURL: URL
    public unowned let auth: AuthManager

    public init(baseURL: URL, auth: AuthManager) {
        self.configuredBaseURL = baseURL
        self.auth = auth
    }

    /// Base URL used for all requests. A `.local` host is swapped for its cached
    /// resolved IP (works over Tailscale, unlike the mDNS name); everything else
    /// passes through unchanged.
    public var baseURL: URL { Self.resolvedURL(configuredBaseURL) }

    static func resolvedURL(_ url: URL) -> URL {
        guard let host = url.host, host.hasSuffix(".local"),
              let ip = ServerHostCache.cachedIP(for: host),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.host = ip
        return comps.url ?? url
    }

    /// Dedicated session for JSON API calls. A 15s idle timeout (vs
    /// URLSession.shared's 60s default) so a dropped link — e.g. a momentary
    /// Tailscale blip — fails fast and the connectivity probe can recover,
    /// instead of the request hanging for a minute. `timeoutIntervalForRequest`
    /// is an INTER-PACKET timeout that resets as data arrives, so large library
    /// fetches over a slow-but-alive link aren't cut off. `waitsForConnectivity`
    /// is off so a request surfaces the failure immediately rather than silently
    /// waiting. Streaming (AVPlayer) and downloads use their own sessions and
    /// are untouched.
    private static func makeAPISession() -> URLSession {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }
    private static var apiSession: URLSession = makeAPISession()

    /// Tear down and recreate the API session. A long-lived URLSession can hold
    /// connections that went stale across a network transition (Wi-Fi↔cellular,
    /// Tailscale up/down) — requests then keep failing even though the server is
    /// reachable, and only an app restart cleared it. Calling this on
    /// reconnect/foreground gives a fresh session with fresh connections, so
    /// recovery no longer needs a reboot.
    public static func resetSession() {
        apiSession.invalidateAndCancel()
        apiSession = makeAPISession()
    }

    public enum APIError: LocalizedError {
        case badResponse(Int)
        case noData
        case invalidURL
        case message(String)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Server returned status \(code)."
            case .noData: return "No data returned by server."
            case .invalidURL: return "Invalid URL."
            case .message(let m): return m
            }
        }
    }

    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(auth.authHeader(), forHTTPHeaderField: "Authorization")
        return req
    }

    /// Consecutive 401s from AUTHENTICATED requests. Jellyfin tokens don't
    /// expire client-side but can be revoked server-side (admin, password
    /// change) — without this, every call just fails forever with no path back
    /// to the login screen. Three in a row (not one — a proxy hiccup or a
    /// single race shouldn't log anyone out) marks the session expired.
    private static var consecutive401s = 0
    private static let expiredThreshold = 3

    private func track401(_ statusCode: Int) {
        if statusCode == 401 {
            Self.consecutive401s += 1
            if Self.consecutive401s >= Self.expiredThreshold {
                Self.consecutive401s = 0
                DebugLog.write("[JellyfinClient] \(Self.expiredThreshold) consecutive 401s — session revoked, signing out")
                Task { @MainActor in AuthManager.shared.handleSessionExpired() }
            }
        } else {
            Self.consecutive401s = 0
        }
    }

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.apiSession.data(for: req)
        } catch {
            await ConnectivityStore.shared.noteFailure(error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        track401(http.statusCode)
        guard (200..<300).contains(http.statusCode) else {
            print("[JellyfinClient] HTTP \(http.statusCode) for \(req.url?.absoluteString ?? "?")")
            throw APIError.badResponse(http.statusCode)
        }
        await ConnectivityStore.shared.noteSuccess()
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            let preview = String(data: data.prefix(500), encoding: .utf8) ?? "<binary>"
            print("[JellyfinClient] Decode failed for \(T.self) at \(req.url?.absoluteString ?? "?"): \(error)\nBody preview: \(preview)")
            throw APIError.message("Decode error: \(error)")
        }
    }

    @discardableResult
    private func sendVoid(_ req: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            // Report transport failures/successes like send() — mutations
            // (favourites, playback reports, playlist edits) previously never
            // fed ConnectivityStore, so a dead link discovered via a mutation
            // didn't flip the app offline or start the reconnect probe.
            (data, response) = try await Self.apiSession.data(for: req)
        } catch {
            await ConnectivityStore.shared.noteFailure(error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        track401(http.statusCode)
        guard (200..<300).contains(http.statusCode) else { throw APIError.badResponse(http.statusCode) }
        await ConnectivityStore.shared.noteSuccess()
        return data
    }

    // MARK: - Authentication

    /// Authenticate, with optional 2FA `code`.
    ///
    /// When a `code` is supplied we first try JellyfinSecurity's native code
    /// endpoint `POST /TwoFactorAuth/Authenticate` — it takes a SEPARATE code
    /// field, verifies the session server-side, and returns a normal Jellyfin
    /// token (the proper "type your authenticator code" path). If that endpoint
    /// isn't present (404 — plugin not installed) we fall back to the append
    /// convention some other TOTP plugins use (`Pw = password + code`). With no
    /// code we just do a plain `AuthenticateByName`.
    public func authenticate(username: String, password: String, code: String? = nil) async throws -> AuthResponse {
        let trimmedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCode.isEmpty {
            if let res = try await authenticateTwoFactor(username: username, password: password, code: trimmedCode) {
                return res
            }
            // Endpoint absent → append-style TOTP plugin fallback.
            return try await authenticateByName(username: username, password: password + trimmedCode, codeProvided: true)
        }
        return try await authenticateByName(username: username, password: password, codeProvided: false)
    }

    /// JellyfinSecurity native one-shot code login. Returns the token on success,
    /// `nil` if the endpoint is absent (404 → caller falls back), throws a clear
    /// error for bad credentials / wrong code / rate-limit.
    private func authenticateTwoFactor(username: String, password: String, code: String) async throws -> AuthResponse? {
        struct Body: Encodable { let Username: String; let Password: String; let Code: String; let TrustDevice: Bool }
        let url = baseURL.appendingPathComponent("TwoFactorAuth/Authenticate")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(auth.authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(Body(Username: username, Password: password, Code: code, TrustDevice: true))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.apiSession.data(for: req)
        } catch {
            await ConnectivityStore.shared.noteFailure(error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        switch http.statusCode {
        case 200..<300:
            await ConnectivityStore.shared.noteSuccess()
            return try JSONDecoder().decode(AuthResponse.self, from: data)
        case 404:
            return nil   // plugin not installed — fall back to AuthenticateByName
        case 429:
            throw APIError.message("Too many sign-in attempts. Wait a minute, then try again.")
        case 401, 403:
            let body = (String(data: data, encoding: .utf8) ?? "").lowercased()
            if body.contains("username or password") {
                throw APIError.message("Invalid username or password.")
            }
            if body.contains("blocked") {
                throw APIError.message("Sign-in temporarily blocked (too many attempts). Wait a minute, then try again.")
            }
            throw APIError.message("Two-factor code incorrect or expired — open your authenticator app and enter a fresh 6-digit code.")
        default:
            throw APIError.badResponse(http.statusCode)
        }
    }

    private func authenticateByName(username: String, password: String, codeProvided: Bool) async throws -> AuthResponse {
        let url = baseURL.appendingPathComponent("Users/AuthenticateByName")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15   // fail fast (default 60s) so offline login surfaces quickly
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(auth.authHeader(), forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(AuthRequest(Username: username, Pw: password))
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.apiSession.data(for: req)
        } catch {
            await ConnectivityStore.shared.noteFailure(error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 {
                if codeProvided {
                    throw APIError.message("Two-factor code incorrect or expired — open your authenticator app and enter a fresh code.")
                }
                throw APIError.message("Sign-in failed. If your server uses two-factor auth, turn on the code field below and enter your authenticator code.")
            }
            if http.statusCode >= 500 {
                throw APIError.message("The server rejected sign-in (error \(http.statusCode)). If it uses a two-factor plugin, turn on the code field and enter your authenticator code.")
            }
            throw APIError.badResponse(http.statusCode)
        }
        await ConnectivityStore.shared.noteSuccess()
        return try JSONDecoder().decode(AuthResponse.self, from: data)
    }

    // MARK: - Library

    private var userId: String { auth.userId ?? "" }

    public func recentlyAdded(limit: Int = 24) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "SortBy", value: "DateCreated,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary")
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    public func recentlyPlayed(limit: Int = 24) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SortBy", value: "DatePlayed"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Filters", value: "IsPlayed"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    /// Albums the user recently played (most-recent first).
    public func recentlyPlayedAlbums(limit: Int = 24) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "SortBy", value: "DatePlayed"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Filters", value: "IsPlayed"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    /// The user's most-played tracks, by play count.
    public func topPlayedTracks(limit: Int = 24) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SortBy", value: "PlayCount,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Filters", value: "IsPlayed"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items.filter { $0.type == "Audio" }
    }

    public func frequentlyPlayed(limit: Int = 24) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "SortBy", value: "PlayCount,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    public func favorites(type: String, limit: Int = 100) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: type),
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    public func artists(startIndex: Int = 0, limit: Int = 200, search: String? = nil, parentId: String? = nil) async throws -> [BaseItem] {
        // `/Artists/AlbumArtists` returns only artists who have at
        // least one album in the user's library — Jellyfin filters out
        // the "phantom" MusicArtist entities it creates for track-level
        // contributors (features, remixers, compilation guests).
        // Plain `/Items?IncludeItemTypes=MusicArtist` would surface
        // those too and clutter the A-Z list.
        var q: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: "ImageTags")
        ]
        if let s = search, !s.isEmpty {
            q.append(URLQueryItem(name: "SearchTerm", value: s))
        }
        if let p = parentId, !p.isEmpty {
            q.append(URLQueryItem(name: "ParentId", value: p))
        }
        let req = try request("Artists/AlbumArtists", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    public func albums(startIndex: Int = 0, limit: Int = 200, search: String? = nil, parentId: String? = nil) async throws -> [BaseItem] {
        var q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        if let s = search, !s.isEmpty {
            q.append(URLQueryItem(name: "SearchTerm", value: s))
        }
        if let p = parentId, !p.isEmpty {
            q.append(URLQueryItem(name: "ParentId", value: p))
        }
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    /// Returns the top-level Jellyfin "Views" (libraries) for the current user.
    /// CollectionType indicates kind ("music", "movies", etc).
    public func userViews() async throws -> [BaseItem] {
        let req = try request("Users/\(userId)/Views")
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    public func playlists() async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
            // Music only — exclude video / TV-show playlists, whose MediaType is
            // Video (e.g. a 200-episode "Arrowverse" playlist).
            URLQueryItem(name: "MediaTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Fields", value: "ChildCount"),
            URLQueryItem(name: "SortBy", value: "SortName")
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        // Jellyfin tags EMPTY playlists as MediaType=Audio by default, so an empty
        // "watchlist" / TV stub slips past the Audio filter above. Drop playlists
        // with no tracks — a music playlist worth showing has at least one song.
        return res.Items.filter { ($0.SongCount ?? $0.ChildCount ?? 0) > 0 }
    }

    public func albumsForArtist(_ artistId: String, name: String? = nil) async throws -> [BaseItem] {
        // Cast a wide net server-side, then filter strictly client-side so
        // only albums actually credited to THIS artist survive.
        async let strict = albumsQuery(params: [("AlbumArtistIds", artistId)])
        async let loose  = albumsQuery(params: [("ArtistIds", artistId)])
        async let byNameTask: [BaseItem] = {
            guard let n = name, !n.isEmpty else { return [] }
            return (try? await albumsQuery(params: [("AlbumArtists", n)])) ?? []
        }()
        let s = (try? await strict) ?? []
        let l = (try? await loose) ?? []
        let n = await byNameTask
        let combined = s + l + n

        let targetName = name?.lowercased()
        var seen: Set<String> = []
        return combined.filter { album in
            guard album.type == "MusicAlbum", seen.insert(album.Id).inserted else { return false }
            // Strict ID match.
            if let aids = album.AlbumArtists, aids.contains(where: { $0.Id == artistId }) {
                return true
            }
            // Name-based fallback for albums missing AlbumArtists ID links.
            guard let target = targetName else { return false }
            if (album.AlbumArtist ?? "").lowercased() == target { return true }
            if let aaNames = album.AlbumArtists?.map({ $0.Name.lowercased() }),
               aaNames.contains(target) { return true }
            return false
        }
    }

    /// IDs of MusicAlbums carrying `tag` as either a Tag or a Genre. Used to
    /// exclude live recordings from generated mixes: the user tags/genres their
    /// live albums on the server, we fetch those album IDs once, and tracks whose
    /// AlbumId is in the set are filtered out. Empty tag → empty set.
    public func albumIds(taggedOrGenred tag: String) async -> Set<String> {
        let t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return [] }
        async let byTag = (try? albumsQuery(params: [("Tags", t)])) ?? []
        async let byGenre = (try? albumsQuery(params: [("Genres", t)])) ?? []
        let albums = await byTag + byGenre
        return Set(albums.map { $0.Id })
    }

    // MARK: - Genres & Tags browsing

    /// All music genres in the user's library (items with Name/Id).
    public func musicGenres() async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Limit", value: "500")
        ]
        let req = try request("MusicGenres", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    /// All tags applied to music items on the server (names only — Jellyfin's
    /// legacy filters endpoint aggregates them across the queried item types).
    public func musicTags() async throws -> [String] {
        struct FiltersResponse: Decodable { let Tags: [String]? }
        let q: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum,MusicArtist,Audio"),
            URLQueryItem(name: "Recursive", value: "true")
        ]
        let req = try request("Items/Filters", query: q)
        let res: FiltersResponse = try await send(req, as: FiltersResponse.self)
        return (res.Tags ?? []).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public func albums(genre: String) async throws -> [BaseItem] {
        try await albumsQuery(params: [("Genres", genre)])
    }

    public func albums(tag: String) async throws -> [BaseItem] {
        try await albumsQuery(params: [("Tags", tag)])
    }

    public func artists(genre: String) async throws -> [BaseItem] {
        try await artistsFiltered(("Genres", genre))
    }

    public func artists(tag: String) async throws -> [BaseItem] {
        try await artistsFiltered(("Tags", tag))
    }

    /// Album artists matching a Genres/Tags filter. Same `/Artists/AlbumArtists`
    /// endpoint as the A-Z list so phantom track-contributor artists stay out.
    private func artistsFiltered(_ param: (String, String)) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "500"),
            URLQueryItem(name: "Fields", value: "ImageTags"),
            URLQueryItem(name: param.0, value: param.1)
        ]
        let req = try request("Artists/AlbumArtists", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    /// Album + artist IDs that live inside `libraryId` (a CollectionFolder).
    /// A track carries its *album* as ParentId, not the library, so to honour a
    /// hidden library in generated mixes / home rows we resolve the library's
    /// album + artist IDs once and filter membership against those sets
    /// (mirrors the live-album-id approach). Empty / failed → empty sets.
    public func contentIds(inLibrary libraryId: String) async -> (albums: Set<String>, artists: Set<String>) {
        let lib = libraryId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lib.isEmpty else { return ([], []) }
        // Paginate both — a large hidden library (e.g. >500 albums) would
        // otherwise be silently truncated, leaking the overflow back into
        // generated content.
        async let albumIds = allItemIds(parentId: lib, itemType: "MusicAlbum")
        async let artistIds = allItemIds(parentId: lib, itemType: "MusicArtist")
        return (await albumIds, await artistIds)
    }

    /// All item IDs of `itemType` under `parentId`, paged until exhausted.
    private func allItemIds(parentId: String, itemType: String) async -> Set<String> {
        var out: Set<String> = []
        var start = 0
        let page = 500
        while true {
            let q: [URLQueryItem] = [
                URLQueryItem(name: "IncludeItemTypes", value: itemType),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "ParentId", value: parentId),
                URLQueryItem(name: "StartIndex", value: String(start)),
                URLQueryItem(name: "Limit", value: String(page))
            ]
            guard let req = try? request("Users/\(userId)/Items", query: q),
                  let res = try? await send(req, as: ItemsResponse<BaseItem>.self)
            else { break }
            out.formUnion(res.Items.map { $0.Id })
            if res.Items.count < page { break }   // last page
            start += res.Items.count
        }
        return out
    }

    private func albumsQuery(params: [(String, String)]) async throws -> [BaseItem] {
        var q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "SortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "500")
        ]
        for (k, v) in params { q.append(URLQueryItem(name: k, value: v)) }
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    public func topTracksForArtist(_ artistId: String, name: String? = nil, limit: Int = 10) async throws -> [BaseItem] {
        // Pull broad set, filter client-side by exact artist match.
        async let byId = tracksQuery(params: [("ArtistIds", artistId)], limit: limit * 3)
        async let byNameTask: [BaseItem] = {
            guard let n = name, !n.isEmpty else { return [] }
            return (try? await tracksQuery(params: [("Artists", n)], limit: limit * 3)) ?? []
        }()
        let s = (try? await byId) ?? []
        let n2 = await byNameTask
        let combined = s + n2

        let targetName = name?.lowercased()
        var seen: Set<String> = []
        let filtered = combined.filter { track in
            guard track.type == "Audio", seen.insert(track.Id).inserted else { return false }
            // Strict ID match.
            if let aids = track.ArtistItems, aids.contains(where: { $0.Id == artistId }) { return true }
            if let aaids = track.AlbumArtists, aaids.contains(where: { $0.Id == artistId }) { return true }
            // Name match.
            guard let target = targetName else { return false }
            if (track.AlbumArtist ?? "").lowercased() == target { return true }
            if let names = track.Artists?.map({ $0.lowercased() }), names.contains(target) { return true }
            if let aaNames = track.AlbumArtists?.map({ $0.Name.lowercased() }), aaNames.contains(target) { return true }
            if let aiNames = track.ArtistItems?.map({ $0.Name.lowercased() }), aiNames.contains(target) { return true }
            return false
        }
        return Array(filtered.prefix(limit))
    }

    private func tracksQuery(params: [(String, String)], limit: Int) async throws -> [BaseItem] {
        var q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SortBy", value: "PlayCount,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        for (k, v) in params { q.append(URLQueryItem(name: k, value: v)) }
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items.filter { $0.type == "Audio" }
    }

    public func songs(parentId: String) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "ParentId", value: parentId),
            URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName")
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    /// Flat (capped) list of every audio track in the library — used by the
    /// onboarding prefetch to cache track names for fast/offline browsing.
    public func allTracks(limit: Int = 10000) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "Fields", value: "ImageTags")
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items.filter { $0.type == "Audio" }
    }

    public func playlistItems(_ playlistId: String) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userId)
        ]
        let req = try request("Playlists/\(playlistId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    public func item(_ itemId: String) async throws -> BaseItem {
        let req = try request("Users/\(userId)/Items/\(itemId)")
        return try await send(req, as: BaseItem.self)
    }

    public func similarArtists(_ id: String, limit: Int = 20) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        let req = try request("Artists/\(id)/Similar", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items
    }

    public func instantMix(itemId: String, limit: Int = 100) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        let req = try request("Items/\(itemId)/InstantMix", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items.filter { $0.type == "Audio" }
    }

    /// Client-side artist radio anchored to the artist and its musical peers.
    /// Jellyfin's artist InstantMix is a genre-only random shuffle over the
    /// whole library (`InstantMixFromGenres(artist.Genres)`, `OrderBy=Random`,
    /// no artist filter), so it drifts wildly off-genre for soundtrack /
    /// compilation / multi-style artists whose genre tags are broad. Instead:
    ///   1. Seed with the artist's own top tracks (keeps it about them).
    ///   2. Blend top tracks from similar artists — Jellyfin's `Similar` plus
    ///      any caller-supplied peers (e.g. Last.fm-resolved composers).
    ///   3. Dedupe by track Id, shuffle, cap to `limit`.
    ///   4. Fall back to song-seeded → artist-seeded InstantMix → shuffled seed
    ///      so Radio never returns empty.
    public func artistRadio(artistId: String,
                            name: String? = nil,
                            extraArtists: [BaseItem] = [],
                            limit: Int = 100) async throws -> [BaseItem] {
        let seed = (try? await topTracksForArtist(artistId, name: name, limit: 25)) ?? []

        var peers = (try? await similarArtists(artistId, limit: 12)) ?? []
        peers.append(contentsOf: extraArtists)
        var peerSeen: Set<String> = [artistId]
        peers = peers.filter { $0.type == "MusicArtist" && peerSeen.insert($0.Id).inserted }
        peers = Array(peers.prefix(10))

        let peerTracks: [BaseItem] = await withTaskGroup(of: [BaseItem].self) { group in
            for p in peers {
                group.addTask {
                    (try? await self.topTracksForArtist(p.Id, name: p.Name, limit: 5)) ?? []
                }
            }
            var acc: [BaseItem] = []
            for await t in group { acc.append(contentsOf: t) }
            return acc
        }

        var seen: Set<String> = []
        var mix = (seed + peerTracks).filter {
            $0.type == "Audio" && seen.insert($0.Id).inserted
        }
        mix.shuffle()
        mix = Array(mix.prefix(limit))
        if !mix.isEmpty { return mix }

        if let first = seed.first,
           let m = try? await instantMix(itemId: first.Id), !m.isEmpty { return m }
        if let m = try? await instantMix(itemId: artistId), !m.isEmpty { return m }
        return seed.shuffled()
    }

    /// An external track reference (e.g. from Last.fm) to resolve against the
    /// user's library by title + artist.
    public struct TrackRef: Sendable, Hashable {
        public let artist: String
        public let title: String
        public init(artist: String, title: String) {
            self.artist = artist
            self.title = title
        }
    }

    /// Resolve external (artist, title) references to concrete tracks in the
    /// user's library, matching by title then artist. Used to turn Last.fm
    /// similar-track / similar-artist recommendations into playable local
    /// items. Runs searches in small concurrent batches so a big seed list
    /// doesn't hammer the server with hundreds of simultaneous requests.
    public func resolveLocalTracks(_ refs: [TrackRef], limit: Int = 100) async -> [BaseItem] {
        let bounded = Array(refs.prefix(60))
        var found: [BaseItem] = []
        let chunkSize = 8
        var i = 0
        while i < bounded.count {
            let chunk = Array(bounded[i..<min(i + chunkSize, bounded.count)])
            let batch: [BaseItem] = await withTaskGroup(of: BaseItem?.self) { group in
                for ref in chunk {
                    group.addTask { await self.resolveOneTrack(ref) }
                }
                var acc: [BaseItem] = []
                for await item in group { if let item { acc.append(item) } }
                return acc
            }
            found.append(contentsOf: batch)
            if found.count >= limit { break }
            i += chunkSize
        }
        var seen: Set<String> = []
        return found.filter { seen.insert($0.Id).inserted }
    }

    private func resolveOneTrack(_ ref: TrackRef) async -> BaseItem? {
        let hits = (try? await searchTracks(ref.title, limit: 6)) ?? []
        let wantTitle = Self.norm(ref.title)
        let wantArtist = Self.norm(ref.artist)
        let exact = hits.filter { Self.norm($0.Name) == wantTitle }
        let pool = exact.isEmpty ? hits.filter { Self.norm($0.Name).contains(wantTitle) } : exact
        return pool.first { Self.artistNames(of: $0).contains { Self.norm($0) == wantArtist } } ?? pool.first
    }

    private static func norm(_ s: String) -> String {
        s.folding(options: .diacriticInsensitive, locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func artistNames(of item: BaseItem) -> [String] {
        var names: [String] = []
        if let a = item.AlbumArtist { names.append(a) }
        if let a = item.Artists { names.append(contentsOf: a) }
        if let a = item.ArtistItems { names.append(contentsOf: a.map { $0.Name }) }
        if let a = item.AlbumArtists { names.append(contentsOf: a.map { $0.Name }) }
        return names
    }

    // MARK: - Search

    public func search(_ term: String, limit: Int = 50) async throws -> [SearchHint] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "SearchTerm", value: term),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio,MusicAlbum,MusicArtist,Playlist")
        ]
        let req = try request("Search/Hints", query: q)
        return try await send(req, as: SearchHintsResponse.self).SearchHints
    }

    // MARK: - Favorites

    public func setFavorite(_ itemId: String, favorite: Bool) async throws {
        var req = try request("Users/\(userId)/FavoriteItems/\(itemId)")
        req.httpMethod = favorite ? "POST" : "DELETE"
        _ = try await sendVoid(req)
    }

    // MARK: - Ratings

    public func setUserRating(_ itemId: String, rating: Int?) async throws {
        if let rating = rating {
            var comps = URLComponents()
            comps.queryItems = [URLQueryItem(name: "rating", value: String(rating))]
            var req = try request("Users/\(userId)/Items/\(itemId)/Rating", query: comps.queryItems ?? [])
            req.httpMethod = "POST"
            _ = try await sendVoid(req)
        } else {
            var req = try request("Users/\(userId)/Items/\(itemId)/Rating")
            req.httpMethod = "DELETE"
            _ = try await sendVoid(req)
        }
    }

    // MARK: - Playlists (mutation)

    /// Create a new playlist with optional initial items. Returns the new playlist Id.
    public func createPlaylist(name: String, itemIds: [String] = []) async throws -> String {
        struct CreateBody: Encodable {
            let Name: String
            let Ids: [String]
            let UserId: String
            let MediaType: String
        }
        let body = CreateBody(Name: name, Ids: itemIds, UserId: userId, MediaType: "Audio")
        var req = try request("Playlists")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        struct CreateResponse: Decodable { let Id: String }
        let res: CreateResponse = try await send(req, as: CreateResponse.self)
        return res.Id
    }

    /// Append items to an existing playlist.
    public func addToPlaylist(playlistId: String, itemIds: [String]) async throws {
        let q = [URLQueryItem(name: "ids", value: itemIds.joined(separator: ",")),
                 URLQueryItem(name: "userId", value: userId)]
        var req = try request("Playlists/\(playlistId)/Items", query: q)
        req.httpMethod = "POST"
        _ = try await sendVoid(req)
    }

    /// Search audio tracks in the user's library by title. Used by mood-based
    /// mix generation to resolve Last.fm-suggested track titles to local items.
    public func searchTracks(_ term: String, limit: Int = 8) async throws -> [BaseItem] {
        guard !term.isEmpty else { return [] }
        let q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "SearchTerm", value: term),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "UserId", value: userId)
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items.filter { $0.type == "Audio" }
    }

    /// Fetch audio tracks tagged with the given genre. Used by mood-based
    /// mix generation — caller typically requests a handful of genres and
    /// combines / dedupes the results.
    public func audioByGenre(_ genre: String, limit: Int = 60) async throws -> [BaseItem] {
        let q: [URLQueryItem] = [
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Genres", value: genre),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "Random"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Fields", value: "Genres")
        ]
        let req = try request("Users/\(userId)/Items", query: q)
        let res: ItemsResponse<BaseItem> = try await send(req, as: ItemsResponse<BaseItem>.self)
        return res.Items.filter { $0.type == "Audio" }
    }

    /// Delete an item from the user's library. Jellyfin removes the item
    /// metadata server-side; for playlists this removes the playlist itself.
    public func deleteItem(_ itemId: String) async throws {
        var req = try request("Items/\(itemId)")
        req.httpMethod = "DELETE"
        _ = try await sendVoid(req)
    }

    // MARK: - Playback reporting

    public func reportPlaybackStart(_ info: PlaybackStartInfo) async throws {
        var req = try request("Sessions/Playing")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(info)
        _ = try await sendVoid(req)
    }

    public func reportPlaybackProgress(_ info: PlaybackProgressInfo) async throws {
        var req = try request("Sessions/Playing/Progress")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(info)
        _ = try await sendVoid(req)
    }

    public func reportPlaybackStopped(_ info: PlaybackStopInfo) async throws {
        var req = try request("Sessions/Playing/Stopped")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(info)
        _ = try await sendVoid(req)
    }

    // MARK: - URLs

    /// Streaming URL for an audio item.
    /// Uses the direct `/Audio/{id}/stream` endpoint with `Static=true` so the server
    /// serves the original file bytes without transcoding. This is required for
    /// AVPlayer's MTAudioProcessingTap (the visualizer + EQ) to enumerate audio
    /// tracks — Jellyfin's `/universal` transcoded stream returns 0 tracks to
    /// AVAsset and silently disables the tap.
    /// Direct, full-quality stream (no transcode). Used for DOWNLOADS (always
    /// lossless) and for playback on Wi-Fi/LAN.
    public func audioStreamURL(for itemId: String) -> URL {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent("Audio/\(itemId)/stream"), resolvingAgainstBaseURL: false) else {
            return baseURL
        }
        comps.queryItems = [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "api_key", value: auth.accessToken ?? "")
        ]
        return comps.url ?? baseURL
    }

    /// Max bitrate (kbps) the app will ever stream over a metered (cellular /
    /// hotspot / Tailscale-over-cellular) path, regardless of the user's quality
    /// setting. Raw FLAC over cellular to a LAN-only server was the #1 cause of
    /// mid-drive stalls — a 320kbps progressive transcode is ~4× lighter and
    /// actually sustains over a flaky link. Wi-Fi/LAN still streams full quality.
    public static let cellularBitrateCeiling = 320

    /// Stream URL for PLAYBACK.
    /// - On Wi-Fi/LAN (not metered): the direct original file (full quality,
    ///   byte-range seekable, lowest latency).
    /// - On a METERED path: ALWAYS a bitrate-capped progressive transcode via
    ///   Jellyfin's `universal` endpoint — even when the user picked Lossless,
    ///   because raw FLAC over cellular stalls constantly. Progressive (not HLS)
    ///   keeps the EQ tap working. `maxBitrateOverride` lets stall-recovery step
    ///   the bitrate down further on a marginal link until it finds one that
    ///   holds. Downloads always use `audioStreamURL` (full quality).
    public func playbackStreamURL(for itemId: String, maxBitrateOverride: Int? = nil) -> URL {
        // Optional CarPlay bitrate: when connected to CarPlay and the user has
        // opted in, force a (typically lower) reliable rate so playback keeps up
        // through patchy signal while driving — even on Wi-Fi, since they're
        // about to leave it. This takes precedence over the normal path logic.
        let carplayOverride = UserDefaults.standard.bool(forKey: "bolera.carplayBitrateEnabled")
            && AudioPlayer.isCarPlayActive

        // Not metered AND no CarPlay override → full-quality direct stream, which
        // (unlike the progressive transcode) is byte-range seekable so a recovery
        // reload resumes exactly. A flaky home Wi-Fi stalls rarely; reopening the
        // same direct stream is the right move — don't drop to transcode here.
        guard ConnectivityStore.pathIsExpensive || carplayOverride else {
            return audioStreamURL(for: itemId)
        }
        // Baseline cap: an explicit CarPlay bitrate wins; otherwise the metered
        // ceiling capping the user's quality setting.
        let baseline: Int
        if carplayOverride {
            let cp = UserDefaults.standard.object(forKey: "bolera.carplayBitrate") as? Int ?? 192
            baseline = min(cp, Self.cellularBitrateCeiling)
        } else {
            let userMax = UserDefaults.standard.object(forKey: "bolera.maxBitrate") as? Int ?? 320
            baseline = min(userMax, Self.cellularBitrateCeiling)
        }
        // Stall recovery can only step the rate DOWN from the baseline, never up.
        let cap = max(48, min(maxBitrateOverride ?? baseline, baseline))
        guard var comps = URLComponents(url: baseURL.appendingPathComponent("Audio/\(itemId)/universal"), resolvingAgainstBaseURL: false) else {
            return audioStreamURL(for: itemId)
        }
        comps.queryItems = [
            URLQueryItem(name: "UserId", value: auth.userId ?? ""),
            URLQueryItem(name: "DeviceId", value: AuthManager.deviceId),
            URLQueryItem(name: "MaxStreamingBitrate", value: String(cap * 1000)),
            URLQueryItem(name: "Container", value: "mp3,aac,m4a,flac,alac,wav,ogg,opus,webma"),
            URLQueryItem(name: "TranscodingContainer", value: "mp3"),
            URLQueryItem(name: "TranscodingProtocol", value: "http"),
            URLQueryItem(name: "AudioCodec", value: "mp3"),
            URLQueryItem(name: "EnableRedirection", value: "true"),
            URLQueryItem(name: "api_key", value: auth.accessToken ?? "")
        ]
        return comps.url ?? audioStreamURL(for: itemId)
    }

    /// Primary image URL for an item. Falls back to album art if the item has no primary tag.
    public func imageURL(for itemId: String, tag: String? = nil, maxWidth: Int = 600) -> URL? {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent("Items/\(itemId)/Images/Primary"), resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "fillWidth", value: String(maxWidth)),
            URLQueryItem(name: "fillHeight", value: String(maxWidth)),
            URLQueryItem(name: "quality", value: "90")
        ]
        if let tag = tag { items.append(URLQueryItem(name: "tag", value: tag)) }
        comps.queryItems = items
        return comps.url
    }
}
