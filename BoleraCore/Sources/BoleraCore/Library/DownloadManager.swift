import Foundation
import Combine

/// Manages offline downloads of Jellyfin audio files.
/// Tracks are stored under Library/Application Support/Downloads/{itemId}.
public final class DownloadManager: NSObject, ObservableObject {
    public static let shared = DownloadManager()

    public struct Progress: Equatable {
        public let received: Int64
        public let total: Int64
        public var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }

        public init(received: Int64, total: Int64) {
            self.received = received
            self.total = total
        }
    }

    @Published public private(set) var inProgress: [String: Progress] = [:]
    @Published public private(set) var completed: Set<String> = []
    @Published public private(set) var metadata: [String: BaseItem] = [:]
    /// Track IDs downloaded individually (single-track download), as opposed to
    /// arriving via a bulk album/artist "Download All". Legacy downloads that
    /// predate this marker are absent here and treated as bulk — so they're
    /// excluded from the individual-only "Tracks" list in CarPlay.
    @Published public private(set) var individualDownloads: Set<String> = []

    /// A playlist the user explicitly downloaded, with its ordered track ids so
    /// it can be browsed/played offline. Bulk operation — member tracks are NOT
    /// marked individual.
    public struct DownloadedPlaylist: Codable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let trackIds: [String]
    }
    @Published public private(set) var downloadedPlaylists: [String: DownloadedPlaylist] = [:]

    /// Album ids the user downloaded as a whole (album "Download All", or via an
    /// artist "Download All"). The Downloaded → Albums list shows only these, so
    /// an album appears when it was deliberately downloaded — not when an odd
    /// track from it happens to be saved individually.
    @Published public private(set) var downloadedAlbums: Set<String> = []

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.allowsCellularAccess = true
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private let baseDir: URL = {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var metadataURL: URL { baseDir.appendingPathComponent("metadata.json") }
    private var individualDownloadsURL: URL { baseDir.appendingPathComponent("individual_downloads.json") }
    private var downloadedPlaylistsURL: URL { baseDir.appendingPathComponent("downloaded_playlists.json") }
    private var downloadedAlbumsURL: URL { baseDir.appendingPathComponent("downloaded_albums.json") }

    public override init() {
        super.init()
        scanExistingDownloads()
    }

    // MARK: - Public API

    public func isDownloaded(_ itemId: String) -> Bool { completed.contains(itemId) }

    public func localFileURL(for itemId: String) -> URL? {
        guard isDownloaded(itemId) else { return nil }
        return resolvedFileURL(for: itemId)
    }

    public func download(_ item: BaseItem, using client: JellyfinClient, individual: Bool = false) {
        guard !isDownloaded(item.Id), tasks[item.Id] == nil else { return }
        let url = client.audioStreamURL(for: item.Id)
        let task = session.downloadTask(with: url)
        task.taskDescription = item.Id
        tasks[item.Id] = task
        Task { @MainActor in
            self.inProgress[item.Id] = Progress(received: 0, total: 0)
            self.metadata[item.Id] = item
            self.persistMetadata()
            if individual {
                self.individualDownloads.insert(item.Id)
                self.persistIndividualDownloads()
            }
        }
        // Enrich stored metadata with the full BaseItem (Genres, Overview,
        // etc.) — most list-fetching queries don't request these fields, so
        // the metadata we got from the caller is often incomplete.
        Task { @MainActor in
            if let full = try? await client.item(item.Id) {
                self.metadata[item.Id] = full
                self.persistMetadata()
            }
        }
        task.resume()
    }

    /// Download every track of a playlist (bulk — NOT marked individual) and
    /// record the playlist + its ordered track ids so it can be browsed and
    /// played offline (e.g. CarPlay → Downloaded Music → Playlists). Calling
    /// again refreshes the stored name/order even if all tracks already exist.
    public func downloadPlaylist(_ playlist: BaseItem, tracks: [BaseItem], using client: JellyfinClient) {
        let entry = DownloadedPlaylist(id: playlist.Id,
                                       name: playlist.Name,
                                       trackIds: tracks.map { $0.Id })
        Task { @MainActor in
            self.downloadedPlaylists[playlist.Id] = entry
            self.persistDownloadedPlaylists()
        }
        for track in tracks where !isDownloaded(track.Id) {
            download(track, using: client, individual: false)
        }
    }

    /// Best-effort backfill of album provenance for downloads made before album
    /// tracking existed (or via paths that don't record it). For each album that
    /// has downloaded tracks but isn't yet marked whole-downloaded, fetch its
    /// full track list and record it only if EVERY track is on disk — so partial
    /// (odd-track) downloads stay out of the Albums list. Requires network; a
    /// no-op offline.
    public func backfillDownloadedAlbums(using client: JellyfinClient) async {
        let (candidates, have): (Set<String>, Set<String>) = await MainActor.run {
            var ids = Set<String>()
            for id in completed {
                if let aid = metadata[id]?.AlbumId, !aid.isEmpty, !downloadedAlbums.contains(aid) {
                    ids.insert(aid)
                }
            }
            return (ids, completed)
        }
        guard !candidates.isEmpty else { return }
        for albumId in candidates {
            guard let tracks = try? await client.songs(parentId: albumId), !tracks.isEmpty else { continue }
            guard tracks.allSatisfy({ have.contains($0.Id) }) else { continue }
            await MainActor.run {
                self.downloadedAlbums.insert(albumId)
                self.persistDownloadedAlbums()
            }
        }
    }

    /// Record an album as downloaded-as-a-whole and download its tracks (bulk —
    /// not individual). The Downloaded → Albums list keys off this set.
    public func downloadAlbum(_ album: BaseItem, tracks: [BaseItem], using client: JellyfinClient) {
        Task { @MainActor in
            self.downloadedAlbums.insert(album.Id)
            self.persistDownloadedAlbums()
        }
        for track in tracks where !isDownloaded(track.Id) {
            download(track, using: client, individual: false)
        }
    }

    /// Re-fetch full BaseItem for every downloaded track whose stored
    /// metadata is missing Genres. Use from views that depend on those
    /// fields (e.g. Downloads → Genres tab) to back-fill legacy downloads.
    public func backfillMissingMetadata(using client: JellyfinClient) async {
        let stale = await MainActor.run {
            self.completed.filter { (self.metadata[$0]?.Genres ?? []).isEmpty }
        }
        for id in stale {
            guard let full = try? await client.item(id) else { continue }
            await MainActor.run {
                self.metadata[id] = full
                self.persistMetadata()
            }
        }
    }

    public func cancel(_ itemId: String) {
        tasks[itemId]?.cancel()
        tasks[itemId] = nil
        Task { @MainActor in self.inProgress.removeValue(forKey: itemId) }
    }

    public func delete(_ itemId: String) {
        if let url = resolvedFileURL(for: itemId) {
            try? FileManager.default.removeItem(at: url)
        }
        Task { @MainActor in
            self.completed.remove(itemId)
            self.metadata.removeValue(forKey: itemId)
            self.individualDownloads.remove(itemId)
            self.persistMetadata()
            self.persistIndividualDownloads()
        }
    }

    public func deleteAll() {
        for id in completed {
            if let url = resolvedFileURL(for: id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        Task { @MainActor in
            self.completed.removeAll()
            self.metadata.removeAll()
            self.individualDownloads.removeAll()
            self.downloadedPlaylists.removeAll()
            self.downloadedAlbums.removeAll()
            self.persistMetadata()
            self.persistIndividualDownloads()
            self.persistDownloadedPlaylists()
            self.persistDownloadedAlbums()
        }
    }

    /// Remove a downloaded playlist: drop the playlist record and delete its
    /// track files — but KEEP any track that's still referenced by an
    /// individual download or by another downloaded playlist, so unrelated
    /// downloads aren't collaterally removed.
    public func removeDownloadedPlaylist(_ playlistId: String) {
        guard let p = downloadedPlaylists[playlistId] else { return }
        let keep = individualDownloads.union(
            downloadedPlaylists.values
                .filter { $0.id != playlistId }
                .flatMap { $0.trackIds }
        )
        for tid in p.trackIds where !keep.contains(tid) {
            delete(tid)
        }
        Task { @MainActor in
            self.downloadedPlaylists.removeValue(forKey: playlistId)
            self.persistDownloadedPlaylists()
        }
    }

    public func totalBytesOnDisk() -> Int64 {
        var sum: Int64 = 0
        for id in completed {
            guard let url = resolvedFileURL(for: id),
                  let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64
            else { continue }
            sum += size
        }
        return sum
    }

    // MARK: - Downloaded content accessors (CarPlay)
    //
    // These return real stored track `BaseItem`s (or one representative track
    // per artist/album), so callers reuse the same artwork / row helpers they
    // use for live library data — no synthetic objects needed.

    /// One representative downloaded track per artist, sorted by artist name.
    public func downloadedArtistReps() -> [BaseItem] {
        var byArtist: [String: BaseItem] = [:]
        for id in completed {
            guard let t = metadata[id] else { continue }
            let name = t.primaryArtistName
            guard !name.isEmpty, byArtist[name] == nil else { continue }
            byArtist[name] = t
        }
        return byArtist.values.sorted {
            $0.primaryArtistName.localizedCaseInsensitiveCompare($1.primaryArtistName) == .orderedAscending
        }
    }

    /// One representative downloaded track per album (keyed by AlbumId), sorted by
    /// album name. Only albums downloaded as a whole (in `downloadedAlbums`) — not
    /// albums where just an odd track is downloaded individually.
    public func downloadedAlbumReps() -> [BaseItem] {
        var byAlbum: [String: BaseItem] = [:]
        for id in completed {
            guard let t = metadata[id], let albumId = t.AlbumId, !albumId.isEmpty,
                  downloadedAlbums.contains(albumId) else { continue }
            if byAlbum[albumId] == nil { byAlbum[albumId] = t }
        }
        return byAlbum.values.sorted {
            ($0.Album ?? $0.Name).localizedCaseInsensitiveCompare($1.Album ?? $1.Name) == .orderedAscending
        }
    }

    /// One representative downloaded track per album for a single artist — again
    /// only fully-downloaded albums.
    public func downloadedAlbumReps(forArtist artistName: String) -> [BaseItem] {
        var byAlbum: [String: BaseItem] = [:]
        for id in completed {
            guard let t = metadata[id], t.primaryArtistName == artistName,
                  let albumId = t.AlbumId, !albumId.isEmpty,
                  downloadedAlbums.contains(albumId) else { continue }
            if byAlbum[albumId] == nil { byAlbum[albumId] = t }
        }
        return byAlbum.values.sorted {
            ($0.Album ?? $0.Name).localizedCaseInsensitiveCompare($1.Album ?? $1.Name) == .orderedAscending
        }
    }

    /// Downloaded tracks for an artist, ordered album → disc → track for sensible queue playback.
    public func downloadedTracks(forArtist artistName: String) -> [BaseItem] {
        completed.compactMap { metadata[$0] }
            .filter { $0.primaryArtistName == artistName }
            .sorted {
                ($0.Album ?? "", $0.ParentIndexNumber ?? 0, $0.IndexNumber ?? 0)
                    < ($1.Album ?? "", $1.ParentIndexNumber ?? 0, $1.IndexNumber ?? 0)
            }
    }

    /// Downloaded tracks for an artist that are NOT part of a fully-downloaded
    /// album — the "odd" tracks (individual single downloads, playlist tracks).
    /// Album-whole tracks are reachable via the artist's downloaded albums.
    public func looseDownloadedTracks(forArtist artistName: String) -> [BaseItem] {
        completed.compactMap { metadata[$0] }
            .filter { t in
                t.primaryArtistName == artistName &&
                !(t.AlbumId.map { downloadedAlbums.contains($0) } ?? false)
            }
            .sorted {
                ($0.Album ?? "", $0.IndexNumber ?? 0) < ($1.Album ?? "", $1.IndexNumber ?? 0)
            }
    }

    /// Downloaded tracks for one album (by AlbumId), in disc/track order.
    public func downloadedTracks(forAlbumId albumId: String) -> [BaseItem] {
        completed.compactMap { metadata[$0] }
            .filter { $0.AlbumId == albumId }
            .sorted {
                ($0.ParentIndexNumber ?? 0, $0.IndexNumber ?? 0)
                    < ($1.ParentIndexNumber ?? 0, $1.IndexNumber ?? 0)
            }
    }

    /// ONLY individually-downloaded tracks (excludes bulk album/artist downloads).
    public func individuallyDownloadedTracks() -> [BaseItem] {
        individualDownloads.compactMap { metadata[$0] }
            .sorted {
                ($0.primaryArtistName, $0.Album ?? "", $0.IndexNumber ?? 0)
                    < ($1.primaryArtistName, $1.Album ?? "", $1.IndexNumber ?? 0)
            }
    }

    /// Downloaded playlists that still have at least one downloaded track, by name.
    public func downloadedPlaylistList() -> [DownloadedPlaylist] {
        downloadedPlaylists.values
            .filter { p in p.trackIds.contains { completed.contains($0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Downloaded tracks for a playlist, in playlist order, filtered to what's still on disk.
    public func downloadedTracks(forPlaylist playlistId: String) -> [BaseItem] {
        guard let p = downloadedPlaylists[playlistId] else { return [] }
        return p.trackIds.compactMap { completed.contains($0) ? metadata[$0] : nil }
    }

    // MARK: - Internals

    /// Default download path before the container is known. Kept for
    /// backwards-compat with files saved by previous Bolera versions.
    private func legacyFileURL(for itemId: String) -> URL {
        baseDir.appendingPathComponent("\(itemId).audio")
    }

    /// Locate the on-disk file for an id, regardless of extension. Renames
    /// legacy `.audio` files to their detected container extension so
    /// AVFoundation can play them.
    private func resolvedFileURL(for itemId: String) -> URL? {
        let prefix = "\(itemId)."
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil)) ?? []
        let match = existing.first { $0.lastPathComponent.hasPrefix(prefix) }
        guard let url = match else { return nil }
        if url.pathExtension == "audio" {
            // Legacy file — sniff and rename so AVFoundation can open it.
            if let renamed = renameByDetectedContainer(at: url, itemId: itemId) {
                return renamed
            }
        }
        return url
    }

    /// Read magic bytes from the file at `url` and rename to the proper
    /// audio extension. Returns the new URL on success.
    @discardableResult
    private func renameByDetectedContainer(at url: URL, itemId: String) -> URL? {
        guard let ext = Self.detectAudioExtension(at: url) else { return nil }
        let newURL = baseDir.appendingPathComponent("\(itemId).\(ext)")
        try? FileManager.default.removeItem(at: newURL)
        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            return newURL
        } catch {
            return nil
        }
    }

    /// Sniff the first bytes of an audio file to determine its container.
    static func detectAudioExtension(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        let bytes = [UInt8](head)
        // ID3 tag or MPEG audio sync word → mp3
        if bytes.count >= 3, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 { return "mp3" }
        if bytes.count >= 2, bytes[0] == 0xFF, (bytes[1] & 0xE0) == 0xE0 { return "mp3" }
        // ISO BMFF (mp4/m4a): bytes 4-7 == 'ftyp'
        if bytes.count >= 8,
           bytes[4] == 0x66, bytes[5] == 0x74, bytes[6] == 0x79, bytes[7] == 0x70 {
            // brand at bytes 8-11 → distinguish m4a vs mp4
            if bytes.count >= 12, bytes[8] == 0x4D, bytes[9] == 0x34, bytes[10] == 0x41 {
                return "m4a"   // M4A_
            }
            return "m4a"       // generic ISO BMFF audio — m4a is widely accepted
        }
        // FLAC
        if bytes.count >= 4, bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43 {
            return "flac"
        }
        // Ogg
        if bytes.count >= 4, bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 {
            return "ogg"
        }
        // RIFF / WAV
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x41, bytes[10] == 0x56, bytes[11] == 0x45 {
            return "wav"
        }
        // AIFF
        if bytes.count >= 12,
           bytes[0] == 0x46, bytes[1] == 0x4F, bytes[2] == 0x52, bytes[3] == 0x4D,
           bytes[8] == 0x41, bytes[9] == 0x49, bytes[10] == 0x46, bytes[11] == 0x46 {
            return "aiff"
        }
        return nil
    }

    private func scanExistingDownloads() {
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil)) ?? []
        // Any file under baseDir whose name is `{id}.{anyext}` counts as
        // downloaded — covers both legacy `.audio` and renamed files.
        let audioExts: Set<String> = ["audio", "mp3", "m4a", "mp4", "flac", "ogg", "wav", "aiff", "aac", "opus"]
        let ids = existing.compactMap { url -> String? in
            guard audioExts.contains(url.pathExtension.lowercased()) else { return nil }
            return url.deletingPathExtension().lastPathComponent
        }
        completed = Set(ids)
        if let data = try? Data(contentsOf: metadataURL),
           let saved = try? JSONDecoder().decode([String: BaseItem].self, from: data) {
            metadata = saved.filter { completed.contains($0.key) }
        }
        if let data = try? Data(contentsOf: individualDownloadsURL),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            individualDownloads = Set(saved.filter { completed.contains($0) })
        }
        if let data = try? Data(contentsOf: downloadedPlaylistsURL),
           let saved = try? JSONDecoder().decode([String: DownloadedPlaylist].self, from: data) {
            downloadedPlaylists = saved
        }
        if let data = try? Data(contentsOf: downloadedAlbumsURL),
           let saved = try? JSONDecoder().decode([String].self, from: data) {
            downloadedAlbums = Set(saved)
        }
    }

    @MainActor
    private func persistMetadata() {
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: metadataURL)
        }
    }

    @MainActor
    private func persistIndividualDownloads() {
        if let data = try? JSONEncoder().encode(Array(individualDownloads)) {
            try? data.write(to: individualDownloadsURL)
        }
    }

    @MainActor
    private func persistDownloadedPlaylists() {
        if let data = try? JSONEncoder().encode(downloadedPlaylists) {
            try? data.write(to: downloadedPlaylistsURL)
        }
    }

    @MainActor
    private func persistDownloadedAlbums() {
        if let data = try? JSONEncoder().encode(Array(downloadedAlbums)) {
            try? data.write(to: downloadedAlbumsURL)
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        // Pick extension from Content-Type when possible, else sniff bytes
        // after the move. Falls back to `.audio` so something is on disk
        // even when both detection paths miss.
        var ext = "audio"
        if let mime = (downloadTask.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .components(separatedBy: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased() {
            switch mime {
            case "audio/mpeg", "audio/mp3":           ext = "mp3"
            case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/aac": ext = "m4a"
            case "audio/flac", "audio/x-flac":        ext = "flac"
            case "audio/ogg", "application/ogg":      ext = "ogg"
            case "audio/wav", "audio/x-wav":          ext = "wav"
            case "audio/aiff", "audio/x-aiff":        ext = "aiff"
            default: break
            }
        }
        var dest = baseDir.appendingPathComponent("\(id).\(ext)")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            // If Content-Type was missing or unrecognized, sniff now.
            if ext == "audio",
               let sniffed = Self.detectAudioExtension(at: dest) {
                let renamed = baseDir.appendingPathComponent("\(id).\(sniffed)")
                try? FileManager.default.removeItem(at: renamed)
                if (try? FileManager.default.moveItem(at: dest, to: renamed)) != nil {
                    dest = renamed
                }
            }
        } catch {
            print("Move failed: \(error)")
        }
        Task { @MainActor in
            self.completed.insert(id)
            self.inProgress.removeValue(forKey: id)
            self.tasks.removeValue(forKey: id)
            self.persistMetadata()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in
            self.inProgress[id] = Progress(received: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, error != nil else { return }
        Task { @MainActor in
            self.inProgress.removeValue(forKey: id)
            self.tasks.removeValue(forKey: id)
        }
    }
}
