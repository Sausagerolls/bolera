import Foundation

/// Thin wrapper around the Jellyfin REST API.
public struct JellyfinClient {
    public let baseURL: URL
    public unowned let auth: AuthManager

    public init(baseURL: URL, auth: AuthManager) {
        self.baseURL = baseURL
        self.auth = auth
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

    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            await ConnectivityStore.shared.noteFailure(error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
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
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else { throw APIError.badResponse(http.statusCode) }
        return data
    }

    // MARK: - Authentication

    public func authenticate(username: String, password: String) async throws -> AuthResponse {
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
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            await ConnectivityStore.shared.noteFailure(error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse(-1) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.message("Invalid username or password.") }
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
