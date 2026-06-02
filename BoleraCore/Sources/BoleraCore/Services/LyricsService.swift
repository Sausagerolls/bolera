import Foundation
import CryptoKit

public struct LyricsLine: Identifiable, Hashable {
    public let id = UUID()
    public let timestamp: TimeInterval?
    public let text: String

    public init(timestamp: TimeInterval?, text: String) {
        self.timestamp = timestamp
        self.text = text
    }
}

public struct Lyrics: Equatable {
    public let lines: [LyricsLine]
    public var isSynced: Bool { lines.contains { $0.timestamp != nil } }
    public var isEmpty: Bool { lines.isEmpty }

    public static let empty = Lyrics(lines: [])

    public init(lines: [LyricsLine]) {
        self.lines = lines
    }
}

public enum LyricsParser {
    /// Parses a `.lrc` lyrics file. Lines without timestamps become unsynced lines.
    public static func parseLRC(_ text: String) -> Lyrics {
        var out: [LyricsLine] = []
        // Matches one or more [mm:ss.xx] timestamps followed by lyric text.
        let timestampPattern = try? NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{2})(?:\\.(\\d{1,3}))?\\]", options: [])
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            guard let regex = timestampPattern else { continue }
            let ns = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                out.append(LyricsLine(timestamp: nil, text: line))
                continue
            }
            let lastEnd = matches.last!.range.location + matches.last!.range.length
            let body = ns.substring(from: lastEnd).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                let frac: Double
                if m.range(at: 3).location != NSNotFound {
                    let s = ns.substring(with: m.range(at: 3))
                    let v = Double(s) ?? 0
                    frac = v / pow(10.0, Double(s.count))
                } else { frac = 0 }
                let t = minutes * 60 + seconds + frac
                out.append(LyricsLine(timestamp: t, text: body))
            }
        }
        return Lyrics(lines: out.sorted { ($0.timestamp ?? -1) < ($1.timestamp ?? -1) })
    }
}

// MARK: - JellyfinClient extension

private struct JellyfinLyricsResponse: Decodable {
    let Lyrics: [Line]?
    struct Line: Decodable {
        let Text: String
        let Start: Int64?
    }
}

public extension JellyfinClient {
    /// Lyrics for a track. Tries the Jellyfin server first; if it has none stored,
    /// falls back to LRCLIB (lrclib.net) — a free, key-less community lyrics
    /// database — matching on artist/title/album/duration. Synced (LRC) lyrics are
    /// preferred over plain. Results are cached to disk so they survive offline.
    func lyrics(for item: BaseItem) async throws -> Lyrics {
        let server = (try? await lyrics(for: item.Id)) ?? .empty
        if !server.isEmpty { return server }
        return await LrcLibService.shared.lyrics(for: item)
    }

    func lyrics(for itemId: String) async throws -> Lyrics {
        let url = baseURL
            .appendingPathComponent("Audio/\(itemId)/Lyrics")
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(auth.authHeader(), forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return .empty
        }
        if let decoded = try? JSONDecoder().decode(JellyfinLyricsResponse.self, from: data),
           let lines = decoded.Lyrics, !lines.isEmpty {
            return Lyrics(lines: lines.map {
                let t: TimeInterval? = $0.Start.map { Double($0) / 10_000_000 }
                return LyricsLine(timestamp: t, text: $0.Text)
            })
        }
        // Fallback: server returned plain text (possibly LRC).
        if let text = String(data: data, encoding: .utf8) {
            return LyricsParser.parseLRC(text)
        }
        return .empty
    }
}

// MARK: - LRCLIB fallback

/// Fetches lyrics from LRCLIB (https://lrclib.net), a free community lyrics
/// database that needs no API key. Used when the Jellyfin server has no lyrics
/// for a track. Successful results are cached on disk (keyed by artist+title+
/// duration) so a track that's been viewed once still shows lyrics offline.
public actor LrcLibService {
    public static let shared = LrcLibService()

    private let base = URL(string: "https://lrclib.net")!
    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    private struct Response: Decodable {
        let plainLyrics: String?
        let syncedLyrics: String?
        let instrumental: Bool?
    }

    public func lyrics(for item: BaseItem) async -> Lyrics {
        let title = item.Name.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (item.Artists?.first ?? item.AlbumArtist ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !artist.isEmpty else { return .empty }
        let album = (item.Album ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let duration = item.RunTimeTicks.map { Int((Double($0) / 10_000_000).rounded()) }

        let key = cacheKey(artist: artist, title: title, duration: duration)
        if let cached = readCache(key) { return cached }

        // Exact match first (artist + title + album + duration, ±2s server-side).
        if let text = await fetchExact(artist: artist, title: title, album: album, duration: duration) {
            return store(text, key: key)
        }
        // Looser search if the exact lookup misses (e.g. duration/album mismatch).
        if let text = await fetchSearch(artist: artist, title: title) {
            return store(text, key: key)
        }
        return .empty
    }

    // MARK: Network

    private func fetchExact(artist: String, title: String, album: String, duration: Int?) async -> String? {
        var comps = URLComponents(url: base.appendingPathComponent("api/get"), resolvingAgainstBaseURL: false)!
        var q = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if !album.isEmpty { q.append(URLQueryItem(name: "album_name", value: album)) }
        if let duration { q.append(URLQueryItem(name: "duration", value: String(duration))) }
        comps.queryItems = q
        guard let url = comps.url, let resp = await get(url, decode: Response.self) else { return nil }
        return pickText(resp)
    }

    private func fetchSearch(artist: String, title: String) async -> String? {
        var comps = URLComponents(url: base.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let url = comps.url, let results = await get(url, decode: [Response].self) else { return nil }
        // Prefer the first result that actually has synced lyrics, else any plain.
        if let synced = results.first(where: { !($0.syncedLyrics ?? "").isEmpty }) {
            return pickText(synced)
        }
        return results.first.flatMap(pickText)
    }

    private func get<T: Decodable>(_ url: URL, decode: T.Type) async -> T? {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Synced lyrics win; fall back to plain. Instrumental tracks return nil.
    private func pickText(_ r: Response) -> String? {
        if r.instrumental == true { return nil }
        if let s = r.syncedLyrics, !s.isEmpty { return s }
        if let p = r.plainLyrics, !p.isEmpty { return p }
        return nil
    }

    private func store(_ text: String, key: String) -> Lyrics {
        writeCache(key, text)
        return LyricsParser.parseLRC(text)
    }

    private static let userAgent: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "Bolera/\(v) (https://giantmushroom.studio/bolera)"
    }()

    // MARK: Disk cache

    private func cacheKey(artist: String, title: String, duration: Int?) -> String {
        let raw = "\(artist.lowercased())|\(title.lowercased())|\(duration ?? 0)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func cacheDir() -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("LyricsCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readCache(_ key: String) -> Lyrics? {
        guard let url = cacheDir()?.appendingPathComponent(key + ".lrc"),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        let parsed = LyricsParser.parseLRC(text)
        return parsed.isEmpty ? nil : parsed
    }

    private func writeCache(_ key: String, _ text: String) {
        guard let url = cacheDir()?.appendingPathComponent(key + ".lrc") else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
