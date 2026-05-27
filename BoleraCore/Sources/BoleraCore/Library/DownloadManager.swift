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

    public func download(_ item: BaseItem, using client: JellyfinClient) {
        guard !isDownloaded(item.Id), tasks[item.Id] == nil else { return }
        let url = client.audioStreamURL(for: item.Id)
        let task = session.downloadTask(with: url)
        task.taskDescription = item.Id
        tasks[item.Id] = task
        Task { @MainActor in
            self.inProgress[item.Id] = Progress(received: 0, total: 0)
            self.metadata[item.Id] = item
            self.persistMetadata()
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
            self.persistMetadata()
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
            self.persistMetadata()
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
    }

    @MainActor
    private func persistMetadata() {
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: metadataURL)
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
