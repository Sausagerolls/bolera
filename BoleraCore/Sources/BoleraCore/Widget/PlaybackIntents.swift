import AppIntents

// Interactive widget controls. These conform to `AudioPlaybackIntent` (not
// plain `AppIntent`) so WidgetKit runs `perform()` in the HOST APP's process —
// the one that owns the `AVAudioSession` and holds `AudioPlayer.shared`'s
// in-memory queue. A plain `AppIntent` would run inside the widget extension,
// where it could not touch audio playback at all.
//
// v1 limitation: if the host app was fully terminated and the queue is empty,
// "play" wakes the app but has nothing to resume (the queue lives only in
// memory). Toggling pause/play and skipping work whenever the player has a
// live queue. Cold-start restore (persisting the last queue) is a follow-up.

@available(iOS 17.0, macOS 14.0, *)
public struct PlayPauseIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play / Pause"
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AudioPlayer.shared.togglePlayPause()
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, *)
public struct NextTrackIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Next Track"
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AudioPlayer.shared.next()
        return .result()
    }
}

@available(iOS 17.0, macOS 14.0, *)
public struct PreviousTrackIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Previous Track"
    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AudioPlayer.shared.previous()
        return .result()
    }
}

/// Tap a Recently Played tile → start the recents queue at that track. Reads
/// the shared `BaseItem`s so playback works without re-fetching from the server.
@available(iOS 17.0, macOS 14.0, *)
public struct PlayRecentTrackIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Recent Track"

    @Parameter(title: "Track ID") public var trackId: String

    public init() {}
    public init(trackId: String) { self.trackId = trackId }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let items = RecentTracksSharedStore.read()
        if let index = items.firstIndex(where: { $0.Id == trackId }) {
            AudioPlayer.shared.play(items: items, startAt: index)
        }
        return .result()
    }
}

/// Tap a Mixes tile → play that daily mix, resolving the live tracks + endless
/// extender from `DailyPlaylistStore.shared`.
@available(iOS 17.0, macOS 14.0, *)
public struct PlayMixIntent: AudioPlaybackIntent {
    public static var title: LocalizedStringResource = "Play Mix"

    @Parameter(title: "Mix ID") public var mixId: String

    public init() {}
    public init(mixId: String) { self.mixId = mixId }

    @MainActor
    public func perform() async throws -> some IntentResult {
        let store = DailyPlaylistStore.shared
        if let uuid = UUID(uuidString: mixId),
           let mix = store.playlists.first(where: { $0.id == uuid }) {
            AudioPlayer.shared.playMix(items: mix.tracks, extender: store.extender(for: mix))
        }
        return .result()
    }
}
