import Foundation
import Combine

/// Technical description of the playing track's audio: what the file on the
/// server is, and how it's reaching the device (original bytes, a download,
/// or a server transcode). Shown on Now Playing and, optionally, on the Lock
/// Screen / CarPlay when "Show audio format" is on.
public struct AudioFormat: Equatable, Sendable {
    public var codec: String?
    public var container: String?
    /// Bits per second.
    public var bitrate: Int?
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var channels: Int?

    public init(codec: String?, container: String?, bitrate: Int?,
                sampleRate: Int?, bitDepth: Int?, channels: Int?) {
        self.codec = codec; self.container = container; self.bitrate = bitrate
        self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.channels = channels
    }

    private static let losslessCodecs: Set<String> = [
        "flac", "alac", "wav", "wavpack", "ape", "tta", "dsd", "aiff"
    ]

    public var isLossless: Bool {
        guard let c = codec?.lowercased() else { return false }
        return Self.losslessCodecs.contains(c) || c.hasPrefix("pcm") || c.hasPrefix("dsd")
    }

    /// High-resolution: lossless above CD quality (more than 16-bit or 48 kHz).
    public var isHiRes: Bool {
        isLossless && ((bitDepth ?? 0) > 16 || (sampleRate ?? 0) > 48_000)
    }

    /// "FLAC", "AAC", "MP3", "PCM" …
    public var codecName: String {
        guard let c = codec?.lowercased(), !c.isEmpty else {
            return container?.uppercased() ?? "Unknown"
        }
        if c.hasPrefix("pcm") { return "PCM" }
        switch c {
        case "vorbis": return "Vorbis"
        case "opus": return "Opus"
        case "wavpack": return "WavPack"
        default: return c.uppercased()
        }
    }

    /// "24-bit / 96 kHz" — the part that matters for lossless. Lossy codecs
    /// don't really have a bit depth, so it's left out for them.
    public var resolution: String? {
        var parts: [String] = []
        if isLossless, let d = bitDepth, d > 0 { parts.append("\(d)-bit") }
        if let r = sampleRate, r > 0 { parts.append(Self.kHz(r)) }
        return parts.isEmpty ? nil : parts.joined(separator: " / ")
    }

    public var bitrateText: String? {
        guard let b = bitrate, b > 0 else { return nil }
        return "\(Int((Double(b) / 1000).rounded())) kbps"
    }

    /// "FLAC · 24-bit / 96 kHz · 2,304 kbps"
    public var summary: String {
        [codecName, resolution, bitrateText].compactMap { $0 }.joined(separator: " · ")
    }

    /// Short form for tight spaces like the CarPlay album line:
    /// "FLAC 24/96", "AAC 256k", "MP3 320k".
    public var compact: String {
        if isLossless {
            let depth = bitDepth.map(String.init)
            let rate = sampleRate.map { Self.kHz($0, unit: false) }
            let res = [depth, rate].compactMap { $0 }.joined(separator: "/")
            return res.isEmpty ? codecName : "\(codecName) \(res)"
        }
        if let b = bitrate, b > 0 { return "\(codecName) \(Int((Double(b) / 1000).rounded()))k" }
        return codecName
    }

    static func kHz(_ hz: Int, unit: Bool = true) -> String {
        let k = Double(hz) / 1000
        let s = k == k.rounded() ? String(Int(k)) : String(format: "%.1f", k)
        return unit ? "\(s) kHz" : s
    }
}

/// How the playing track is reaching the device.
public enum AudioDelivery: Equatable, Sendable {
    /// Not known yet (stream still opening).
    case unknown
    /// Original file bytes streamed from the server.
    case original
    /// Original file played from a download.
    case downloaded
    /// The server is re-encoding to AAC at roughly this many kbps (nil when
    /// the player hasn't reported a rate yet).
    case transcoded(kbps: Int?)

    public var label: String? {
        switch self {
        case .unknown, .original: return nil
        case .downloaded: return "Downloaded"
        case .transcoded(let k): return k.map { "Transcoded to AAC \($0) kbps" } ?? "Transcoded to AAC"
        }
    }
}

/// Narrow observable for the audio-format readout, so the views showing it
/// don't have to observe the whole `AudioPlayer` (which ticks 10×/s).
@MainActor
public final class AudioFormatState: ObservableObject {
    public static let shared = AudioFormatState()

    /// UserDefaults key: show the format on the Now Playing screen.
    public nonisolated static let showKey = "bolera.showAudioFormat"
    /// UserDefaults key: also add it to the Lock Screen / CarPlay album line.
    public nonisolated static let showSystemKey = "bolera.showAudioFormatSystem"

    @Published public private(set) var itemId: String?
    @Published public private(set) var source: AudioFormat?
    @Published public private(set) var delivery: AudioDelivery = .unknown

    private var cache: [String: AudioFormat] = [:]
    private var fetch: Task<Void, Never>?

    /// Called whenever either part changes, so the player can refresh the
    /// system Now Playing info when the format is shown there.
    var onChange: (() -> Void)?

    public static var showsOnSystem: Bool {
        UserDefaults.standard.bool(forKey: showSystemKey)
    }

    /// One line for the Lock Screen / CarPlay, or nil when hidden or unknown.
    public var systemLine: String? {
        guard Self.showsOnSystem, let source else { return nil }
        if case .transcoded(let k) = delivery {
            return "\(source.compact) → AAC" + (k.map { " \($0)k" } ?? "")
        }
        return source.compact
    }

    func begin(itemId: String, client: JellyfinClient?, delivery: AudioDelivery) {
        fetch?.cancel()
        self.itemId = itemId
        self.delivery = delivery
        source = cache[itemId]
        onChange?()
        guard source == nil, let client else { return }
        fetch = Task { [weak self] in
            guard let f = try? await client.audioFormat(itemId) else { return }
            guard let self, !Task.isCancelled, self.itemId == itemId else { return }
            self.cache[itemId] = f
            self.source = f
            self.onChange?()
        }
    }

    func update(delivery: AudioDelivery, for itemId: String) {
        guard self.itemId == itemId, self.delivery != delivery else { return }
        self.delivery = delivery
        onChange?()
    }

    /// Re-publish to the Lock Screen / CarPlay after the setting is toggled.
    public func settingsChanged() { onChange?() }

    func clear() {
        fetch?.cancel()
        itemId = nil
        source = nil
        delivery = .unknown
    }
}
