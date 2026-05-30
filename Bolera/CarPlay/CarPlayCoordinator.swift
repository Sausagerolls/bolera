import UIKit
import CarPlay
import Combine
import BoleraCore

/// Owns Bolera's CarPlay template hierarchy.
///
/// Top-level tabs (left → right). **Recents is first, so it's the
/// default page the head unit shows on connect**, mirroring the phone
/// app's Home tab:
///   1. **Recents** — the same sections as the phone Home: Recent
///      Tracks, Recent Albums, Recently Added, Top Played Tracks, and
///      Favorites. Backed by a shared `LibraryStore` so the filtering
///      (visibility/ignored) and the derived Recent Albums match the
///      phone exactly. Tap a track to play in context; tap an album to
///      open its detail.
///   2. **Make a Mix** — predefined mood prompts feed the same
///      `MoodMixGenerator` the in-app sheet uses, then jump to Now
///      Playing once tracks have been resolved.
///   3. **Library** — drill-down to Albums or Artists. Each lists rows
///      with artwork thumbnails + alphabetised section headers so a
///      large library stays navigable. Album rows push a detail
///      template with Play All / Shuffle and a per-track list; artist
///      rows push a detail with Top Tracks + Albums (which themselves
///      open the album detail template).
///   4. **Playlists** — Daily Mixes section + the user's Jellyfin
///      playlists, both with artwork.
///
/// Playback is delegated to the shared `AudioPlayer`, so auto-advance,
/// scrobbling, and lock-screen / Now Playing integration all behave the
/// same as the phone UI.
@MainActor
final class CarPlayCoordinator {

    private let interfaceController: CPInterfaceController
    private var cancellables = Set<AnyCancellable>()

    /// Drives the Recents tab. Reusing `LibraryStore` keeps CarPlay's Recents
    /// identical to the phone Home — same section data, same visibility/ignore
    /// filtering, same derived Recent Albums — and shares the on-disk cache so
    /// the tab populates instantly from cache before the server refresh lands.
    private let recentsStore = LibraryStore()

    init(interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
    }

    func start() {
        interfaceController.setRootTemplate(buildRootTabBar(), animated: false, completion: nil)
        Task { await loadRecents() }
        Task { await refreshDailyMixesIfNeeded(); await loadPlaylists() }
        // Reload the server-backed tabs whenever connectivity flips, so CarPlay
        // shows downloaded content offline and repopulates from the server on
        // reconnect. (Library Albums/Artists are loaded on tap, so they read
        // live connectivity then.)
        ConnectivityStore.shared.$isOnline
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.loadRecents()
                    await self?.loadPlaylists()
                }
            }
            .store(in: &cancellables)
        // Sign-out must hide ALL content (including downloaded items) — pop any
        // pushed downloaded list and reload the tabs into the sign-in prompt.
        AuthManager.shared.$isAuthenticated
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.interfaceController.popToRootTemplate(animated: false, completion: nil)
                    await self?.loadRecents()
                    await self?.loadPlaylists()
                }
            }
            .store(in: &cancellables)
    }

    /// CarPlay can connect before the user opens the phone app, in
    /// which case `DailyPlaylistStore` won't have hydrated yet and the
    /// Playlists tab would be empty. Kick a refresh so the Daily Mixes
    /// section appears as soon as Jellyfin responds.
    private func refreshDailyMixesIfNeeded() async {
        guard let client = client,
              DailyPlaylistStore.shared.playlists.isEmpty else { return }
        await DailyPlaylistStore.shared.refreshIfNeeded(
            client: client,
            auth: AuthManager.shared,
            lastFm: LastFmService.shared
        )
    }

    // MARK: - Top-level templates

    private lazy var makeMixTemplate: CPListTemplate = {
        let rows: [CPListItem] = Self.moodSuggestions.map { suggestion in
            let row = CPListItem(text: suggestion,
                                 detailText: nil,
                                 image: UIImage(systemName: "wand.and.stars"))
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await self?.runMoodMix(prompt: suggestion)
                    completion()
                }
            }
            return row
        }
        let section = CPListSection(items: rows,
                                    header: "Pick a vibe — Apple Intelligence builds the mix",
                                    sectionIndexTitle: nil)
        let t = CPListTemplate(title: "Make a Mix", sections: [section])
        t.tabImage = UIImage(systemName: "wand.and.stars")
        t.tabTitle = "Make a Mix"
        return t
    }()

    private lazy var recentsTemplate: CPListTemplate = {
        let t = CPListTemplate(title: "Recents", sections: [])
        t.tabImage = UIImage(systemName: "clock")
        t.tabTitle = "Recents"
        return t
    }()

    private lazy var libraryTemplate: CPListTemplate = {
        let albumsRow = CPListItem(text: "Albums",
                                   detailText: nil,
                                   image: UIImage(systemName: "square.stack"))
        albumsRow.handler = { [weak self] _, completion in
            Task { @MainActor in
                // Downloaded fallback only when signed IN but offline. Signed
                // out → the server loader, which shows the sign-in prompt.
                if ConnectivityStore.shared.isOnline || !AuthManager.shared.isAuthenticated {
                    await self?.pushAllAlbums()
                } else {
                    await self?.pushDownloadedAlbums()
                }
                completion()
            }
        }
        let artistsRow = CPListItem(text: "Artists",
                                    detailText: nil,
                                    image: UIImage(systemName: "person.circle"))
        artistsRow.handler = { [weak self] _, completion in
            Task { @MainActor in
                if ConnectivityStore.shared.isOnline || !AuthManager.shared.isAuthenticated {
                    await self?.pushAllArtists()
                } else {
                    await self?.pushDownloadedArtists()
                }
                completion()
            }
        }
        let downloadedRow = CPListItem(text: "Downloaded Music",
                                       detailText: nil,
                                       image: UIImage(systemName: "arrow.down.circle"))
        downloadedRow.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.pushDownloadedMusic()
                completion()
            }
        }
        let section = CPListSection(items: [albumsRow, artistsRow, downloadedRow], header: nil, sectionIndexTitle: nil)
        let t = CPListTemplate(title: "Library", sections: [section])
        t.tabImage = UIImage(systemName: "music.note.list")
        t.tabTitle = "Library"
        return t
    }()

    private lazy var playlistsTemplate: CPListTemplate = {
        let t = CPListTemplate(title: "Playlists", sections: [])
        t.tabImage = UIImage(systemName: "text.badge.star")
        t.tabTitle = "Playlists"
        return t
    }()

    private func buildRootTabBar() -> CPTabBarTemplate {
        // Recents first → CarPlay selects it by default on connect.
        return CPTabBarTemplate(templates: [
            recentsTemplate,
            makeMixTemplate,
            libraryTemplate,
            playlistsTemplate
        ])
    }

    // MARK: - Loaders

    private var client: JellyfinClient? {
        guard let url = AuthManager.shared.serverURL else { return nil }
        return JellyfinClient(baseURL: url, auth: AuthManager.shared)
    }

    private func loadRecents() async {
        guard AuthManager.shared.isAuthenticated else {
            recentsTemplate.updateSections([signInPromptSection()])
            return
        }
        if !ConnectivityStore.shared.isOnline {
            recentsTemplate.updateSections(downloadedRecentsSections())
            return
        }
        guard let client = client else {
            recentsTemplate.updateSections([signInPromptSection()])
            return
        }
        // Show cached sections instantly (LibraryStore hydrates from disk on
        // init); a bare loading row only when there's nothing cached yet.
        if recentsStoreIsEmpty {
            recentsTemplate.updateSections([CPListSection(items: [loadingRow()],
                                                          header: nil, sectionIndexTitle: nil)])
        } else {
            renderRecentsSections()
        }
        // Refresh from the server, then re-render. refresh() swallows network
        // errors and keeps prior state, so a brief LAN drop just leaves the
        // cached sections in place rather than blanking the tab.
        await recentsStore.refresh(client: client)
        renderRecentsSections()
    }

    private var recentsStoreIsEmpty: Bool {
        recentsStore.recentlyPlayed.isEmpty
            && recentsStore.recentlyPlayedAlbums.isEmpty
            && recentsStore.topPlayedTracks.isEmpty
            && recentsStore.recentlyAdded.isEmpty
            && recentsStore.favoriteAlbums.isEmpty
    }

    /// Build the Recents tab's sections from `recentsStore`, mirroring the
    /// phone Home order: Recent Tracks, Recent Albums, Top Played Tracks,
    /// Recently Added, Favorites. Track rows play in their section's context;
    /// album rows open the album detail.
    private func renderRecentsSections() {
        var sections: [CPListSection] = []
        func trackSection(_ title: String, _ tracks: [BaseItem]) {
            let capped = Array(tracks.prefix(24))
            guard !capped.isEmpty else { return }
            let rows = makeListItems(for: capped, playInContext: capped)
            sections.append(CPListSection(items: rows, header: title, sectionIndexTitle: nil))
            loadArtwork(for: capped, into: rows)
        }
        func albumSection(_ title: String, _ albums: [BaseItem]) {
            let capped = Array(albums.prefix(24))
            guard !capped.isEmpty else { return }
            let rows = makeListItems(for: capped, playInContext: nil)
            sections.append(CPListSection(items: rows, header: title, sectionIndexTitle: nil))
            loadArtwork(for: capped, into: rows)
        }
        trackSection("Recent Tracks", recentsStore.recentlyPlayed)
        albumSection("Recent Albums", recentsStore.recentlyPlayedAlbums)
        trackSection("Top Played Tracks", recentsStore.topPlayedTracks)
        albumSection("Recently Added", recentsStore.recentlyAdded)
        albumSection("Favorites", recentsStore.favoriteAlbums)

        if sections.isEmpty {
            sections = [emptySection("Nothing recent yet — play something on your phone first.")]
        }
        recentsTemplate.updateSections(sections)
    }

    private func loadPlaylists() async {
        guard AuthManager.shared.isAuthenticated else {
            playlistsTemplate.updateSections([signInPromptSection()])
            return
        }
        if !ConnectivityStore.shared.isOnline {
            let pls = DownloadManager.shared.downloadedPlaylistList()
            guard !pls.isEmpty else {
                playlistsTemplate.updateSections([emptySection("Offline — no downloaded playlists.")])
                return
            }
            let rows: [CPListItem] = pls.map { pl in
                let tracks = DownloadManager.shared.downloadedTracks(forPlaylist: pl.id)
                let row = CPListItem(text: pl.name,
                                     detailText: "\(tracks.count) track\(tracks.count == 1 ? "" : "s")",
                                     image: placeholderImage)
                row.handler = { [weak self] _, completion in
                    Task { @MainActor in
                        await self?.pushDownloadedPlaylistDetail(id: pl.id, title: pl.name)
                        completion()
                    }
                }
                return row
            }
            playlistsTemplate.updateSections([CPListSection(items: rows, header: "Downloaded", sectionIndexTitle: nil)])
            return
        }
        var sections: [CPListSection] = []

        // Daily Mixes (always first if any exist)
        let dailyMixes = DailyPlaylistStore.shared.playlists
        if !dailyMixes.isEmpty {
            let dailyRows: [CPListItem] = dailyMixes.map { mix in
                let row = CPListItem(text: mix.name,
                                     detailText: "\(mix.tracks.count) tracks",
                                     image: dailyMixArtwork(for: mix))
                row.handler = { [weak self] _, completion in
                    Task { @MainActor in
                        await self?.playDailyMix(mix)
                        completion()
                    }
                }
                return row
            }
            sections.append(CPListSection(items: dailyRows,
                                          header: "Daily Mixes",
                                          sectionIndexTitle: nil))
        }

        // Jellyfin user playlists
        if let client = client {
            let userPlaylists = (try? await client.playlists()) ?? []
            if !userPlaylists.isEmpty {
                let rows = makeListItems(for: userPlaylists, playInContext: nil)
                sections.append(CPListSection(items: rows,
                                              header: "Your Playlists",
                                              sectionIndexTitle: nil))
                loadArtwork(for: userPlaylists, into: rows)
            }
        } else if sections.isEmpty {
            sections = [signInPromptSection()]
        }

        if sections.isEmpty {
            sections = [CPListSection(items: [CPListItem(text: "No playlists yet",
                                                          detailText: "Daily Mixes and your Jellyfin playlists will appear here.",
                                                          image: nil)],
                                       header: nil,
                                       sectionIndexTitle: nil)]
        }
        playlistsTemplate.updateSections(sections)
    }

    private func pushAllAlbums() async {
        let template = CPListTemplate(title: "Albums",
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil,
                                                               sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        guard let client = client else {
            template.updateSections([signInPromptSection()])
            return
        }
        do {
            let items = try await client.albums(limit: 500)
            let rows = items.map { makeAlbumRow($0) }
            template.updateSections(makeAlphabeticalSections(items: items, listItems: rows))
            loadArtwork(for: items, into: rows)
        } catch {
            template.updateSections([emptySection("Couldn't reach Jellyfin — check your phone's connection to the server.")])
        }
    }

    private func pushAllArtists() async {
        let template = CPListTemplate(title: "Artists",
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil,
                                                               sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        guard let client = client else {
            template.updateSections([signInPromptSection()])
            return
        }
        let items: [BaseItem]
        do {
            items = try await client.artists(limit: 500)
        } catch {
            template.updateSections([emptySection("Couldn't reach Jellyfin — check your phone's connection to the server.")])
            return
        }
        let rows = items.map { item in
            makeArtistRow(item)
        }
        template.updateSections(makeAlphabeticalSections(items: items, listItems: rows))
        loadArtwork(for: items, into: rows)
    }

    // MARK: - Album detail

    private func makeAlbumRow(_ album: BaseItem) -> CPListItem {
        let row = CPListItem(text: album.Name,
                             detailText: album.primaryArtistName,
                             image: placeholderImage)
        row.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.pushAlbumDetail(album)
                completion()
            }
        }
        return row
    }

    private func pushAlbumDetail(_ album: BaseItem) async {
        let template = CPListTemplate(title: album.Name,
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil,
                                                               sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        guard let client = client else { return }
        let tracks = (try? await client.songs(parentId: album.Id)) ?? []
        guard !tracks.isEmpty else {
            template.updateSections([emptySection("No tracks in this album.")])
            return
        }

        let playRow = CPListItem(text: "Play",
                                 detailText: nil,
                                 image: UIImage(systemName: "play.fill"))
        playRow.handler = { [weak self] _, completion in
            Task { @MainActor in
                AudioPlayer.shared.shuffle = false
                AudioPlayer.shared.play(items: tracks)
                self?.pushNowPlaying()
                completion()
            }
        }
        let shuffleRow = CPListItem(text: "Shuffle",
                                    detailText: nil,
                                    image: UIImage(systemName: "shuffle"))
        shuffleRow.handler = { [weak self] _, completion in
            Task { @MainActor in
                AudioPlayer.shared.shuffle = true
                AudioPlayer.shared.play(items: tracks)
                self?.pushNowPlaying()
                completion()
            }
        }
        let actionSection = CPListSection(items: [playRow, shuffleRow],
                                          header: album.primaryArtistName,
                                          sectionIndexTitle: nil)

        let trackRows: [CPListItem] = tracks.enumerated().map { (idx, track) in
            let row = CPListItem(text: track.Name,
                                 detailText: trackDurationLabel(track),
                                 image: nil)
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    AudioPlayer.shared.shuffle = false
                    AudioPlayer.shared.play(items: tracks, startAt: idx)
                    self?.pushNowPlaying()
                    completion()
                }
            }
            return row
        }
        let trackSection = CPListSection(items: trackRows,
                                         header: "Tracks",
                                         sectionIndexTitle: nil)
        template.updateSections([actionSection, trackSection])
    }

    // MARK: - Artist detail

    private func makeArtistRow(_ artist: BaseItem) -> CPListItem {
        let row = CPListItem(text: artist.Name,
                             detailText: detailText(for: artist),
                             image: placeholderImage)
        row.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.pushArtistDetail(artist)
                completion()
            }
        }
        return row
    }

    private func pushArtistDetail(_ artist: BaseItem) async {
        let template = CPListTemplate(title: artist.Name,
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil,
                                                               sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        guard let client = client else { return }
        async let topTracksTask: [BaseItem] = (try? await client.topTracksForArtist(artist.Id, name: artist.Name, limit: 10)) ?? []
        async let albumsTask: [BaseItem] = (try? await client.albumsForArtist(artist.Id, name: artist.Name)) ?? []
        let (topTracks, albums) = await (topTracksTask, albumsTask)

        var sections: [CPListSection] = []

        let playRow = CPListItem(text: "Play",
                                 detailText: nil,
                                 image: UIImage(systemName: "play.fill"))
        playRow.handler = { [weak self] _, completion in
            Task { @MainActor in
                guard let allTracks = await self?.collectAllTracks(forAlbums: albums) else {
                    completion(); return
                }
                AudioPlayer.shared.shuffle = false
                AudioPlayer.shared.play(items: allTracks)
                self?.pushNowPlaying()
                completion()
            }
        }
        let radioRow = CPListItem(text: "Radio",
                                  detailText: "Similar tracks",
                                  image: UIImage(systemName: "antenna.radiowaves.left.and.right"))
        radioRow.handler = { [weak self] _, completion in
            Task { @MainActor in
                if let client = self?.client,
                   let mix = try? await client.instantMix(itemId: artist.Id),
                   !mix.isEmpty {
                    AudioPlayer.shared.play(items: mix)
                    self?.pushNowPlaying()
                }
                completion()
            }
        }
        sections.append(CPListSection(items: [playRow, radioRow], header: nil, sectionIndexTitle: nil))

        if !topTracks.isEmpty {
            let rows: [CPListItem] = topTracks.enumerated().map { (idx, t) in
                let row = CPListItem(text: t.Name,
                                     detailText: t.Album,
                                     image: nil)
                row.handler = { [weak self] _, completion in
                    Task { @MainActor in
                        AudioPlayer.shared.play(items: topTracks, startAt: idx)
                        self?.pushNowPlaying()
                        completion()
                    }
                }
                return row
            }
            sections.append(CPListSection(items: rows, header: "Top Tracks", sectionIndexTitle: nil))
        }

        if !albums.isEmpty {
            let albumRows = albums.map { makeAlbumRow($0) }
            sections.append(CPListSection(items: albumRows, header: "Albums", sectionIndexTitle: nil))
            loadArtwork(for: albums, into: albumRows)
        }

        template.updateSections(sections)
    }

    private func collectAllTracks(forAlbums albums: [BaseItem]) async -> [BaseItem] {
        guard let client = client else { return [] }
        var all: [BaseItem] = []
        for album in albums {
            if let songs = try? await client.songs(parentId: album.Id) {
                all.append(contentsOf: songs)
            }
        }
        return all
    }

    // MARK: - Daily Mix playback

    private func playDailyMix(_ mix: DailyPlaylist) async {
        AudioPlayer.shared.play(items: mix.tracks)
        pushNowPlaying()
    }

    private func dailyMixArtwork(for mix: DailyPlaylist) -> UIImage {
        // DailyPlaylistStore caches a composite cover image per mix on
        // disk (and in `artworkByPlaylist`); use that when available so
        // CarPlay rows match the in-app tile art instead of a generic
        // sparkles symbol.
        if let img = DailyPlaylistStore.shared.artworkByPlaylist[mix.id] {
            return img
        }
        return UIImage(systemName: "wand.and.stars")?
            .withTintColor(.systemPurple, renderingMode: .alwaysOriginal)
            ?? placeholderImage
    }

    // MARK: - Mood Mix (Make a Mix tab)

    /// Predefined mood prompts surfaced as tappable rows. Matches the
    /// chip suggestions in the iOS in-app sheet so behaviour is
    /// consistent across surfaces.
    private static let moodSuggestions = [
        "Late-night drive in the rain",
        "Sunday morning coffee",
        "Throwback house party",
        "Focus & deep work",
        "Working out, high energy"
    ]

    private func runMoodMix(prompt: String) async {
        guard ConnectivityStore.shared.isOnline else {
            let t = CPListTemplate(title: prompt,
                                   sections: [emptySection("Offline — Make a Mix needs a connection to your server.")])
            interfaceController.pushTemplate(t, animated: true, completion: nil)
            return
        }
        // Show a transient "Generating…" template so the head unit
        // doesn't look frozen while Apple Intelligence works.
        let progress = CPListTemplate(title: prompt,
                                      sections: [CPListSection(items: [
                                        CPListItem(text: "Generating…",
                                                   detailText: "Apple Intelligence is picking tracks.",
                                                   image: UIImage(systemName: "wand.and.stars"))
                                      ], header: nil, sectionIndexTitle: nil)])
        interfaceController.pushTemplate(progress, animated: true, completion: nil)

        await MoodMixGenerator.shared.generate(
            prompt: prompt,
            auth: AuthManager.shared,
            onResult: { [weak self] _, tracks in
                Task { @MainActor in
                    guard !tracks.isEmpty else {
                        progress.updateSections([CPListSection(items: [
                            CPListItem(text: "Couldn't build a mix",
                                       detailText: "Try a different vibe.",
                                       image: nil)
                        ], header: nil, sectionIndexTitle: nil)])
                        return
                    }
                    AudioPlayer.shared.play(items: tracks)
                    self?.pushNowPlaying()
                }
            },
            onError: { msg in
                Task { @MainActor in
                    progress.updateSections([CPListSection(items: [
                        CPListItem(text: "Couldn't build a mix",
                                   detailText: msg,
                                   image: nil)
                    ], header: nil, sectionIndexTitle: nil)])
                }
            }
        )
    }

    // MARK: - Downloaded Music

    /// Offline Recents: surface downloaded albums + individually-downloaded
    /// tracks so there's something playable in the car without a connection.
    private func downloadedRecentsSections() -> [CPListSection] {
        let dm = DownloadManager.shared
        let albums = dm.downloadedAlbumReps()
        let tracks = dm.individuallyDownloadedTracks()
        guard !albums.isEmpty || !tracks.isEmpty else {
            return [emptySection("Offline — no downloads on this device yet.")]
        }
        var sections: [CPListSection] = []
        if !albums.isEmpty {
            let rows = albums.map { makeDownloadedAlbumRow($0) }
            sections.append(CPListSection(items: rows, header: "Downloaded Albums", sectionIndexTitle: nil))
            loadArtwork(for: albums, into: rows)
        }
        if !tracks.isEmpty {
            sections.append(CPListSection(items: trackRows(for: tracks, image: placeholderImage),
                                          header: "Downloaded Tracks", sectionIndexTitle: nil))
        }
        return sections
    }

    private func pushDownloadedMusic() async {
        let template = CPListTemplate(title: "Downloaded Music",
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil, sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        guard AuthManager.shared.isAuthenticated else {
            template.updateSections([signInPromptSection()])
            return
        }
        let dm = DownloadManager.shared
        let artistCount = dm.downloadedArtistReps().count
        let albumCount = dm.downloadedAlbumReps().count
        let trackCount = dm.individuallyDownloadedTracks().count
        let playlistCount = dm.downloadedPlaylistList().count

        guard artistCount + albumCount + trackCount + playlistCount > 0 else {
            template.updateSections([emptySection("No downloads yet — download music on your phone first.")])
            return
        }

        let artistsRow = CPListItem(text: "Artists",
                                    detailText: "\(artistCount) artist\(artistCount == 1 ? "" : "s")",
                                    image: UIImage(systemName: "person.circle"))
        artistsRow.handler = { [weak self] _, completion in
            Task { @MainActor in await self?.pushDownloadedArtists(); completion() }
        }

        let albumsRow = CPListItem(text: "Albums",
                                   detailText: "\(albumCount) album\(albumCount == 1 ? "" : "s")",
                                   image: UIImage(systemName: "square.stack"))
        albumsRow.handler = { [weak self] _, completion in
            Task { @MainActor in await self?.pushDownloadedAlbums(); completion() }
        }

        let tracksRow = CPListItem(text: "Tracks",
                                   detailText: "\(trackCount) track\(trackCount == 1 ? "" : "s")",
                                   image: UIImage(systemName: "music.note"))
        tracksRow.handler = { [weak self] _, completion in
            Task { @MainActor in await self?.pushDownloadedTracks(); completion() }
        }

        let playlistsRow = CPListItem(text: "Playlists",
                                      detailText: "\(playlistCount) playlist\(playlistCount == 1 ? "" : "s")",
                                      image: UIImage(systemName: "music.note.list"))
        playlistsRow.handler = { [weak self] _, completion in
            Task { @MainActor in await self?.pushDownloadedPlaylists(); completion() }
        }

        template.updateSections([CPListSection(items: [artistsRow, albumsRow, tracksRow, playlistsRow],
                                               header: nil, sectionIndexTitle: nil)])
    }

    private func pushDownloadedArtists() async {
        let template = CPListTemplate(title: "Artists",
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil, sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        let reps = DownloadManager.shared.downloadedArtistReps()
        guard !reps.isEmpty else {
            template.updateSections([emptySection("No downloaded artists.")])
            return
        }
        let rows: [CPListItem] = reps.map { rep in
            let name = rep.primaryArtistName
            let row = CPListItem(text: name, detailText: nil, image: placeholderImage)
            row.handler = { [weak self] _, completion in
                Task { @MainActor in await self?.pushDownloadedArtistDetail(name: name); completion() }
            }
            return row
        }
        // makeAlphabeticalSections indexes by item.Name, but reps are tracks
        // whose Name is the song title — index by an artist-named stub instead.
        let nameItems = reps.map { BaseItem.stub(id: $0.Id, name: $0.primaryArtistName, type: "MusicArtist") }
        template.updateSections(makeAlphabeticalSections(items: nameItems, listItems: rows))
        loadArtwork(for: reps, into: rows)
    }

    private func pushDownloadedArtistDetail(name: String) async {
        let template = CPListTemplate(title: name,
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil, sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        let dm = DownloadManager.shared
        let albumReps = dm.downloadedAlbumReps(forArtist: name)
        let tracks = dm.downloadedTracks(forArtist: name)
        guard !tracks.isEmpty else {
            template.updateSections([emptySection("No downloads from this artist.")])
            return
        }

        var sections: [CPListSection] = []
        sections.append(CPListSection(items: playShuffleRows(for: tracks), header: nil, sectionIndexTitle: nil))

        if !albumReps.isEmpty {
            let albumRows = albumReps.map { makeDownloadedAlbumRow($0) }
            sections.append(CPListSection(items: albumRows, header: "Albums", sectionIndexTitle: nil))
            loadArtwork(for: albumReps, into: albumRows)
        }

        sections.append(CPListSection(items: trackRows(for: tracks, image: nil),
                                      header: "Tracks", sectionIndexTitle: nil))
        template.updateSections(sections)
    }

    private func pushDownloadedAlbums() async {
        let template = CPListTemplate(title: "Albums",
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil, sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        let reps = DownloadManager.shared.downloadedAlbumReps()
        guard !reps.isEmpty else {
            template.updateSections([emptySection("No downloaded albums.")])
            return
        }
        let rows = reps.map { makeDownloadedAlbumRow($0) }
        let nameItems = reps.map { BaseItem.stub(id: $0.AlbumId ?? $0.Id, name: $0.Album ?? $0.Name, type: "MusicAlbum") }
        template.updateSections(makeAlphabeticalSections(items: nameItems, listItems: rows))
        loadArtwork(for: reps, into: rows)
    }

    /// Album row backed by a representative downloaded track; drills into that
    /// album's downloaded tracks (by AlbumId).
    private func makeDownloadedAlbumRow(_ rep: BaseItem) -> CPListItem {
        let albumId = rep.AlbumId ?? rep.Id
        let title = rep.Album ?? rep.Name
        let artist = rep.primaryArtistName
        let row = CPListItem(text: title, detailText: artist, image: placeholderImage)
        row.handler = { [weak self] _, completion in
            Task { @MainActor in
                await self?.pushDownloadedAlbumDetail(albumId: albumId, title: title, artist: artist)
                completion()
            }
        }
        return row
    }

    private func pushDownloadedAlbumDetail(albumId: String, title: String, artist: String) async {
        let template = CPListTemplate(title: title,
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil, sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        let tracks = DownloadManager.shared.downloadedTracks(forAlbumId: albumId)
        guard !tracks.isEmpty else {
            template.updateSections([emptySection("No downloaded tracks in this album.")])
            return
        }
        template.updateSections([
            CPListSection(items: playShuffleRows(for: tracks), header: artist, sectionIndexTitle: nil),
            CPListSection(items: trackRows(for: tracks, image: nil), header: "Tracks", sectionIndexTitle: nil)
        ])
    }

    private func pushDownloadedTracks() async {
        let template = CPListTemplate(title: "Tracks",
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil, sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        let tracks = DownloadManager.shared.individuallyDownloadedTracks()
        guard !tracks.isEmpty else {
            template.updateSections([emptySection("No individually-downloaded tracks yet.")])
            return
        }
        let rows = trackRows(for: tracks, image: placeholderImage)
        template.updateSections([
            CPListSection(items: playShuffleRows(for: tracks), header: nil, sectionIndexTitle: nil),
            CPListSection(items: rows, header: "Tracks", sectionIndexTitle: nil)
        ])
        loadArtwork(for: tracks, into: rows)
    }

    private func pushDownloadedPlaylists() async {
        let template = CPListTemplate(title: "Playlists",
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil, sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        let dm = DownloadManager.shared
        let playlists = dm.downloadedPlaylistList()
        guard !playlists.isEmpty else {
            template.updateSections([emptySection("No downloaded playlists.")])
            return
        }
        var reps: [BaseItem] = []
        let rows: [CPListItem] = playlists.map { pl in
            let tracks = dm.downloadedTracks(forPlaylist: pl.id)
            let row = CPListItem(text: pl.name,
                                 detailText: "\(tracks.count) track\(tracks.count == 1 ? "" : "s")",
                                 image: placeholderImage)
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await self?.pushDownloadedPlaylistDetail(id: pl.id, title: pl.name)
                    completion()
                }
            }
            reps.append(tracks.first ?? BaseItem.stub(id: pl.id, name: pl.name, type: "Playlist"))
            return row
        }
        template.updateSections([CPListSection(items: rows, header: nil, sectionIndexTitle: nil)])
        loadArtwork(for: reps, into: rows)
    }

    private func pushDownloadedPlaylistDetail(id: String, title: String) async {
        let template = CPListTemplate(title: title,
                                      sections: [CPListSection(items: [loadingRow()],
                                                               header: nil, sectionIndexTitle: nil)])
        interfaceController.pushTemplate(template, animated: true, completion: nil)

        let tracks = DownloadManager.shared.downloadedTracks(forPlaylist: id)
        guard !tracks.isEmpty else {
            template.updateSections([emptySection("No downloaded tracks in this playlist.")])
            return
        }
        template.updateSections([
            CPListSection(items: playShuffleRows(for: tracks), header: nil, sectionIndexTitle: nil),
            CPListSection(items: trackRows(for: tracks, image: nil), header: "Tracks", sectionIndexTitle: nil)
        ])
    }

    /// Play / Shuffle action rows that queue the whole `tracks` array (so
    /// playback continues to the next track, like starting a playlist).
    private func playShuffleRows(for tracks: [BaseItem]) -> [CPListItem] {
        let playRow = CPListItem(text: "Play", detailText: nil, image: UIImage(systemName: "play.fill"))
        playRow.handler = { [weak self] _, completion in
            Task { @MainActor in
                AudioPlayer.shared.shuffle = false
                AudioPlayer.shared.play(items: tracks, startAt: 0)
                self?.pushNowPlaying()
                completion()
            }
        }
        let shuffleRow = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"))
        shuffleRow.handler = { [weak self] _, completion in
            Task { @MainActor in
                AudioPlayer.shared.shuffle = true
                AudioPlayer.shared.play(items: tracks, startAt: 0)
                self?.pushNowPlaying()
                completion()
            }
        }
        return [playRow, shuffleRow]
    }

    /// Track rows that start playback at the tapped index against the full
    /// `tracks` array, so the queue continues afterwards.
    private func trackRows(for tracks: [BaseItem], image: UIImage?) -> [CPListItem] {
        tracks.enumerated().map { (idx, track) in
            let row = CPListItem(text: track.Name,
                                 detailText: trackDurationLabel(track) ?? track.primaryArtistName,
                                 image: image)
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    AudioPlayer.shared.shuffle = false
                    AudioPlayer.shared.play(items: tracks, startAt: idx)
                    self?.pushNowPlaying()
                    completion()
                }
            }
            return row
        }
    }

    // MARK: - Generic rows

    private func makeListItems(for items: [BaseItem], playInContext context: [BaseItem]?) -> [CPListItem] {
        return items.map { item in
            let row = CPListItem(text: item.Name,
                                 detailText: detailText(for: item),
                                 image: placeholderImage)
            row.handler = { [weak self] _, completion in
                Task { @MainActor in
                    await self?.handleSelection(of: item, context: context)
                    completion()
                }
            }
            return row
        }
    }

    private func makeAlphabeticalSections(items: [BaseItem], listItems: [CPListItem]) -> [CPListSection] {
        var buckets: [String: [CPListItem]] = [:]
        for (item, row) in zip(items, listItems) {
            buckets[indexLetter(for: item.Name), default: []].append(row)
        }
        let letters = buckets.keys.sorted { lhs, rhs in
            if lhs == "#" { return true }
            if rhs == "#" { return false }
            return lhs < rhs
        }
        return letters.map { letter in
            CPListSection(items: buckets[letter]!, header: letter, sectionIndexTitle: letter)
        }
    }

    private func indexLetter(for name: String) -> String {
        var s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("the ") {
            s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        }
        guard let first = s.unicodeScalars.first else { return "#" }
        if CharacterSet.letters.contains(first) {
            return String(Character(first)).uppercased()
        }
        return "#"
    }

    private func detailText(for item: BaseItem) -> String? {
        switch item.type {
        case "MusicAlbum":  return item.primaryArtistName
        case "Audio":       return item.primaryArtistName
        case "MusicArtist":
            if let n = item.AlbumCount {
                return "\(n) album\(n == 1 ? "" : "s")"
            }
            return nil
        case "Playlist":
            if let n = item.SongCount ?? item.ChildCount {
                return "\(n) tracks"
            }
            return nil
        default: return nil
        }
    }

    private func trackDurationLabel(_ track: BaseItem) -> String? {
        guard let ticks = track.RunTimeTicks else { return nil }
        let seconds = Int(ticks / 10_000_000)
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    // MARK: - Generic selection

    private func handleSelection(of item: BaseItem, context: [BaseItem]?) async {
        guard let client = client else { return }
        switch item.type {
        case "Audio":
            if let context, let idx = context.firstIndex(where: { $0.Id == item.Id }) {
                AudioPlayer.shared.play(items: context, startAt: idx)
            } else {
                AudioPlayer.shared.play(items: [item])
            }
            pushNowPlaying()

        case "MusicAlbum":
            await pushAlbumDetail(item)

        case "MusicArtist":
            await pushArtistDetail(item)

        case "Playlist":
            let tracks = (try? await client.songs(parentId: item.Id)) ?? []
            guard !tracks.isEmpty else { return }
            AudioPlayer.shared.play(items: tracks)
            pushNowPlaying()

        default:
            let tracks = (try? await client.songs(parentId: item.Id)) ?? []
            guard !tracks.isEmpty else { return }
            AudioPlayer.shared.play(items: tracks)
            pushNowPlaying()
        }
    }

    private func pushNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        // If a transient template (Mood Mix "Generating…", album/artist
        // detail loading) sits on top, replace it with Now Playing
        // instead of pushing on top — otherwise CarPlay's back stack
        // accumulates stale templates the user would have to swipe
        // through to get back home.
        if let top = interfaceController.topTemplate, top !== nowPlaying {
            interfaceController.popTemplate(animated: false) { _, _ in
                self.interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
            }
        } else if interfaceController.topTemplate !== nowPlaying {
            interfaceController.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    // MARK: - Artwork

    private let placeholderImage: UIImage = {
        let size = CGSize(width: 60, height: 60)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor(white: 0.18, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let icon = UIImage(systemName: "music.note",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .regular))?
                .withTintColor(UIColor(white: 0.55, alpha: 1), renderingMode: .alwaysOriginal)
            icon?.draw(at: CGPoint(x: 17, y: 17))
        }
    }()

    private func loadArtwork(for items: [BaseItem], into rows: [CPListItem]) {
        guard let url = AuthManager.shared.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: AuthManager.shared)
        let header = ["Authorization": AuthManager.shared.authHeader()]
        // Bound concurrent artwork fetches so a Library → Albums tap on a
        // large library doesn't fan out hundreds of parallel HTTP requests
        // to Jellyfin (head units have limited memory and the server may
        // throttle). 6 in flight keeps perceived scroll-in speed snappy
        // without saturating the network.
        let pairs = Array(zip(items, rows))
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                var index = 0
                func enqueue() {
                    while index < pairs.count {
                        let (item, row) = pairs[index]
                        index += 1
                        guard let imgURL = client.imageURL(for: item.artworkItemId,
                                                           tag: item.artworkTag,
                                                           maxWidth: 240) else { continue }
                        group.addTask {
                            if let image = await ImageCache.shared.load(url: imgURL, headers: header) {
                                await MainActor.run { row.setImage(image) }
                            }
                        }
                        return
                    }
                }
                for _ in 0..<6 { enqueue() }
                for await _ in group { enqueue() }
            }
        }
    }

    // MARK: - Placeholders

    private func signInPromptSection() -> CPListSection {
        let row = CPListItem(text: "Sign in on iPhone first",
                             detailText: "Open Bolera on your phone and connect to your Jellyfin server.",
                             image: nil)
        return CPListSection(items: [row], header: nil, sectionIndexTitle: nil)
    }

    private func loadingRow() -> CPListItem {
        return CPListItem(text: "Loading…", detailText: nil, image: nil)
    }

    private func emptySection(_ text: String) -> CPListSection {
        return CPListSection(items: [CPListItem(text: text, detailText: nil, image: nil)],
                             header: nil,
                             sectionIndexTitle: nil)
    }
}
