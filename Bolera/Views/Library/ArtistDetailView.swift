import SwiftUI
import BoleraCore

struct ArtistDetailView: View {
    let artist: BaseItem
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lastFm: LastFmService
    @State private var albums: [BaseItem] = []
    @State private var similar: [BaseItem] = []
    @State private var topTracks: [BaseItem] = []
    @State private var bio: LastFmService.ArtistBio?
    @State private var bioExpanded = false
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var isDownloadingAll = false
    /// Track ids enqueued by the most recent "Download All" tap, so the
    /// button can show live progress against DownloadManager state.
    @State private var enqueuedIds: Set<String> = []
    /// True while the Radio queue is being generated (Last.fm + resolve pass).
    @State private var isBuildingRadio = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                JellyfinImage(itemId: artist.Id, tag: artist.ImageTags?["Primary"], maxWidth: 600, cornerRadius: 120)
                    .frame(width: 220, height: 220)
                    .shadow(radius: 20)
                Text(artist.Name).font(.title.bold())

                HStack(spacing: 12) {
                    Button {
                        playAllTopTracks()
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Button {
                        radio()
                    } label: {
                        Group {
                            if isBuildingRadio {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Building…")
                                }
                            } else {
                                Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(isBuildingRadio)
                    Button {
                        downloadAllAlbums()
                    } label: {
                        Group {
                            if downloadAllBusy {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(downloadAllLabel)
                                }
                            } else {
                                Label(downloadAllLabel,
                                      systemImage: downloadAllFinished ? "checkmark.circle.fill" : "arrow.down.circle")
                            }
                        }
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(albums.isEmpty || downloadAllBusy || downloadAllFinished)
                }
                .padding(.horizontal)

                if !topTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top Tracks").font(.title3.bold())
                        LazyVStack(spacing: 0) {
                            ForEach(Array(topTracks.enumerated()), id: \.element.id) { idx, track in
                                Button {
                                    AudioPlayer.shared.play(items: topTracks, startAt: idx)
                                } label: {
                                    HStack(spacing: 12) {
                                        NowPlayingIndexMarker(trackId: track.Id, index: idx + 1)
                                            .frame(width: 22, alignment: .trailing)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(track.Name).font(.body).lineLimit(1)
                                            if let album = track.Album {
                                                Text(album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                if idx < topTracks.count - 1 {
                                    Divider().padding(.leading, 40)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Albums").font(.title3.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(albums) { album in
                                NavigationLink(value: album) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        JellyfinImage(itemId: album.Id, tag: album.ImageTags?["Primary"], maxWidth: 400, cornerRadius: 10)
                                            .frame(width: 150, height: 150)
                                        Text(album.Name).font(.subheadline).lineLimit(1)
                                        if let year = album.ProductionYear {
                                            Text(String(year)).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(width: 150, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    IgnoreAlbumToggleButton(item: album)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal)

                if let bio {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About").font(.title3.bold())
                        Text(bio.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(bioExpanded ? nil : 4)
                            .animation(.easeInOut(duration: 0.2), value: bioExpanded)
                        Button(bioExpanded ? "Show less" : "Read more") {
                            bioExpanded.toggle()
                        }
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                    }
                    .padding(.horizontal)
                }

                if lastFm.hasAppCredentials && !similar.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Similar Artists").font(.title3.bold())
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(similar) { other in
                                    NavigationLink(value: other) {
                                        VStack {
                                            JellyfinImage(itemId: other.Id, tag: other.ImageTags?["Primary"], maxWidth: 300, cornerRadius: 75)
                                                .frame(width: 110, height: 110)
                                            Text(other.Name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                                        }
                                        .frame(width: 110)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
                Color.clear.frame(height: 120)
            }
        }
        .background(BoleraBackground().ignoresSafeArea())
        .navigationDestination(for: BaseItem.self) { item in
            if item.type == "MusicArtist" { ArtistDetailView(artist: item) }
            else { AlbumDetailView(album: item) }
        }
        .navigationTitle(artist.Name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    IgnoreArtistToggleButton(item: artist)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)

        // Run the three Jellyfin-backed fetches in parallel — they're
        // independent and there's no reason to serialise them.
        async let albumsTask: [BaseItem] = (try? await client.albumsForArtist(artist.Id, name: artist.Name)) ?? []
        async let topTracksTask: [BaseItem] = (try? await client.topTracksForArtist(artist.Id, name: artist.Name, limit: 10)) ?? []
        albums = await albumsTask
        topTracks = await topTracksTask

        // Similar artists + bio via Last.fm — only when the user has it
        // configured AND we're viewing an actual artist (defensive guard
        // against the page being shown with an album/playlist BaseItem).
        guard lastFm.hasAppCredentials, artist.type == "MusicArtist" else {
            similar = []
            bio = nil
            return
        }

        async let bioTask: LastFmService.ArtistBio? = try? await lastFm.artistInfo(forName: artist.Name)
        bio = await bioTask

        guard let lfNames = try? await lastFm.similarArtists(forName: artist.Name, limit: 25) else { return }
        // Resolve Last.fm names to local artists concurrently rather than
        // searching one name after another — the old serial loop made the
        // Similar Artists shelf the slowest thing on the page (up to 8
        // sequential round-trips). Fan out a bounded batch, then keep the
        // results in Last.fm rank order.
        let candidates = Array(lfNames.prefix(12))
        let matches = await withTaskGroup(of: (Int, BaseItem?).self) { group -> [BaseItem] in
            for (idx, cand) in candidates.enumerated() {
                group.addTask {
                    let hits = (try? await client.artists(search: cand.name)) ?? []
                    let needle = cand.name.folding(options: .diacriticInsensitive, locale: .current)
                    let match = hits.first(where: {
                        $0.type == "MusicArtist" &&
                        $0.Name.folding(options: .diacriticInsensitive, locale: .current)
                            .compare(needle, options: .caseInsensitive) == .orderedSame
                    })
                    return (idx, match)
                }
            }
            var byIndex: [Int: BaseItem] = [:]
            for await (idx, match) in group where match != nil {
                byIndex[idx] = match
            }
            return candidates.indices.compactMap { byIndex[$0] }
        }
        similar = Array(matches.prefix(8))
    }

    private func playAllTopTracks() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        Task {
            // Fetch every album's songs concurrently, then concatenate in
            // album order (task-group completion order is non-deterministic,
            // so bucket by index before flattening).
            let all = await withTaskGroup(of: (Int, [BaseItem]).self) { group -> [BaseItem] in
                for (idx, album) in albums.enumerated() {
                    group.addTask { (idx, (try? await client.songs(parentId: album.Id)) ?? []) }
                }
                var buckets: [Int: [BaseItem]] = [:]
                for await (idx, songs) in group { buckets[idx] = songs }
                return albums.indices.flatMap { buckets[$0] ?? [] }
            }
            await MainActor.run { AudioPlayer.shared.play(items: all) }
        }
    }

    // Live state of the most recent "Download All", measured against the
    // DownloadManager so the button reflects actual download progress (not
    // just the brief song-list fetch).
    private var enqueuedDoneCount: Int { enqueuedIds.filter { downloads.completed.contains($0) }.count }
    private var enqueuedActiveCount: Int { enqueuedIds.filter { downloads.inProgress.keys.contains($0) }.count }
    private var downloadAllActive: Bool { enqueuedActiveCount > 0 }
    private var downloadAllBusy: Bool { isDownloadingAll || downloadAllActive }
    private var downloadAllFinished: Bool {
        !enqueuedIds.isEmpty && enqueuedActiveCount == 0 && enqueuedDoneCount == enqueuedIds.count
    }

    private var downloadAllLabel: String {
        if isDownloadingAll { return "Queuing…" }
        if downloadAllActive { return "Downloading \(enqueuedDoneCount)/\(enqueuedIds.count)" }
        if downloadAllFinished { return "Downloaded" }
        return "Download All"
    }

    private func downloadAllAlbums() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        isDownloadingAll = true
        enqueuedIds = []
        Task {
            // Resolve each album's track list concurrently, enqueueing tracks
            // as each album resolves. DownloadManager keys everything by
            // *track* id, so we enqueue per track (not per album). Every track
            // id is recorded (downloaded or not) so the button can show live
            // n/N progress and a final "Downloaded" state.
            await withTaskGroup(of: (BaseItem, [BaseItem]).self) { group in
                for album in albums {
                    group.addTask { (album, (try? await client.songs(parentId: album.Id)) ?? []) }
                }
                for await (album, songs) in group {
                    await MainActor.run {
                        for song in songs { enqueuedIds.insert(song.Id) }
                        // Record each album as fully downloaded (and download its
                        // tracks) so they appear under Downloaded → Albums.
                        downloads.downloadAlbum(album, tracks: songs, using: client)
                    }
                }
            }
            await MainActor.run { isDownloadingAll = false }
        }
    }

    private func radio() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        isBuildingRadio = true
        Task {
            var mix: [BaseItem] = []
            // Primary: Last.fm track-level radio — track.getSimilar seeded from
            // the artist's own top tracks + similar artists' top tracks,
            // resolved to the local library. Far more coherent than Jellyfin's
            // genre-random artist InstantMix.
            if lastFm.hasAppCredentials {
                mix = await lastFmRadio(client: client)
            }
            // Top up / fall back with the Jellyfin-side artist radio if Last.fm
            // resolved too few local tracks (small library / niche artist).
            if mix.count < 15 {
                let fallback = (try? await client.artistRadio(
                    artistId: artist.Id, name: artist.Name, extraArtists: similar)) ?? []
                var seen = Set(mix.map { $0.Id })
                mix.append(contentsOf: fallback.filter { seen.insert($0.Id).inserted })
            }
            await MainActor.run {
                isBuildingRadio = false
                let final = Array(LiveFilterStore.shared.filter(mix).prefix(100))
                if !final.isEmpty { AudioPlayer.shared.play(items: final) }
            }
        }
    }

    /// Builds a coherent radio queue from Last.fm recommendations resolved to
    /// the local library: track.getSimilar seeded from the artist's own top
    /// tracks, plus the top tracks of Last.fm similar artists. Only local
    /// (playable) matches survive.
    private func lastFmRadio(client: JellyfinClient) async -> [BaseItem] {
        let localTop = (try? await client.topTracksForArtist(artist.Id, name: artist.Name, limit: 15)) ?? []
        let seedTitles = Array(localTop.prefix(3)).map { $0.Name }

        async let similarTrackRefs: [JellyfinClient.TrackRef] = {
            var out: [JellyfinClient.TrackRef] = []
            for title in seedTitles {
                let sims = (try? await lastFm.similarTracks(artist: artist.Name, track: title, limit: 40)) ?? []
                out.append(contentsOf: sims.map { .init(artist: $0.artist.name, title: $0.name) })
            }
            return out
        }()
        async let peerTrackRefs: [JellyfinClient.TrackRef] = {
            let peers = (try? await lastFm.similarArtists(forName: artist.Name, limit: 20)) ?? []
            var out: [JellyfinClient.TrackRef] = []
            for peer in peers.prefix(12) {
                let tt = (try? await lastFm.topTracks(forName: peer.name, limit: 8)) ?? []
                out.append(contentsOf: tt.map { .init(artist: peer.name, title: $0.name) })
            }
            return out
        }()

        var refs = await similarTrackRefs
        refs.append(contentsOf: await peerTrackRefs)

        var pairSeen = Set<String>()
        let uniqueRefs = refs.filter {
            pairSeen.insert("\($0.artist.lowercased())|\($0.title.lowercased())").inserted
        }

        let resolved = await client.resolveLocalTracks(uniqueRefs, limit: 100)

        var seen = Set<String>()
        var mix = (Array(localTop.prefix(6)) + resolved).filter {
            $0.type == "Audio" && seen.insert($0.Id).inserted
        }
        mix.shuffle()
        return mix
    }
}
