import Foundation

/// Genre / tag radio: plays random tracks drawn ONLY from one genre or server
/// tag, and arms the endless-mix extender to keep drawing from the SAME
/// genre/tag as the queue runs down — the originating filter is captured by
/// the extender closure, so it's remembered for the whole listening session.
@MainActor
public enum GenreTagRadio {

    public enum Source: String { case genre, tag }

    /// Fetch a starting batch and begin playback as an endless mix.
    public static func start(_ source: Source, name: String, client: JellyfinClient) async {
        let initial = await fetch(source, name: name, client: client, limit: 100)
        let tracks = Array(initial.shuffled().prefix(50))
        guard !tracks.isEmpty else { return }
        AudioPlayer.shared.playMix(items: tracks) { existing in
            // Sticky extension: same genre/tag, minus what's already queued.
            let more = await fetch(source, name: name, client: client, limit: 60)
            return more.filter { !existing.contains($0.Id) }.shuffled()
        }
    }

    /// Random tracks for the filter, with the user's ignore/visibility/live
    /// filters applied (matches how daily mixes build their pools).
    private static func fetch(_ source: Source, name: String,
                              client: JellyfinClient, limit: Int) async -> [BaseItem] {
        let raw: [BaseItem]
        switch source {
        case .genre: raw = (try? await client.audioByGenre(name, limit: limit)) ?? []
        case .tag:   raw = (try? await client.audioByTag(name, limit: limit)) ?? []
        }
        return IgnoredTracksStore.shared.filter(
            LibraryVisibilityStore.shared.filter(
                LiveFilterStore.shared.filter(raw)))
    }
}
