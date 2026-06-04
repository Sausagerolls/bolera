import Foundation

/// The slice of playback state the Now Playing widget needs, written by the
/// app into the shared App Group container and read back by the widget
/// extension. Deliberately small and self-contained (no `BaseItem`) so the
/// widget never has to reach into the player or the network.
///
/// `elapsed` is sampled at `anchorDate`; the widget extrapolates the live
/// position from those two plus `isPlaying` (see `projectedElapsed`), so the
/// progress bar keeps moving between timeline reloads without the extension
/// being woken on every tick.
public struct NowPlayingSnapshot: Codable, Equatable, Sendable {
    public var hasTrack: Bool
    public var trackId: String
    public var title: String
    public var artist: String
    public var album: String?
    public var isPlaying: Bool
    public var duration: Double
    public var elapsed: Double
    public var anchorDate: Date
    /// File name (not full path) of the artwork JPEG inside the App Group
    /// container. nil when there's no track / no artwork yet.
    public var artworkRelativePath: String?

    public init(hasTrack: Bool, trackId: String, title: String, artist: String,
                album: String?, isPlaying: Bool, duration: Double, elapsed: Double,
                anchorDate: Date, artworkRelativePath: String?) {
        self.hasTrack = hasTrack
        self.trackId = trackId
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.duration = duration
        self.elapsed = elapsed
        self.anchorDate = anchorDate
        self.artworkRelativePath = artworkRelativePath
    }

    public static let empty = NowPlayingSnapshot(
        hasTrack: false, trackId: "", title: "", artist: "", album: nil,
        isPlaying: false, duration: 0, elapsed: 0, anchorDate: .distantPast,
        artworkRelativePath: nil
    )

    /// Live elapsed position projected to `now`, clamped to `[0, duration]`.
    /// While paused the sampled `elapsed` is returned as-is.
    public func projectedElapsed(at now: Date = Date()) -> Double {
        guard hasTrack else { return 0 }
        guard isPlaying else { return clampToDuration(elapsed) }
        let advanced = elapsed + max(0, now.timeIntervalSince(anchorDate))
        return clampToDuration(advanced)
    }

    /// Fractional progress in `[0, 1]` projected to `now`.
    public func progress(at now: Date = Date()) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(projectedElapsed(at: now) / duration, 0), 1)
    }

    /// The wall-clock window the track plays over, for `ProgressView(timerInterval:)`
    /// / `Text(_:style:.timer)` so the widget animates smoothly between reloads.
    /// nil when paused or duration is unknown.
    public var playbackInterval: ClosedRange<Date>? {
        guard hasTrack, isPlaying, duration > 0 else { return nil }
        let start = anchorDate.addingTimeInterval(-elapsed)
        let end = start.addingTimeInterval(duration)
        guard end > start else { return nil }
        return start...end
    }

    private func clampToDuration(_ value: Double) -> Double {
        guard duration > 0 else { return max(0, value) }
        return min(max(0, value), duration)
    }
}
