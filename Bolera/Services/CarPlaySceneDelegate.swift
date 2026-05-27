import Foundation
import BoleraCore
import CarPlay
import MediaPlayer
import UIKit

/// CarPlay scene delegate for an audio app. Builds a tab-based library
/// browser, pushes child lists for artists/albums/playlists/songs, and
/// shows `CPNowPlayingTemplate.shared` (which auto-populates from
/// `MPNowPlayingInfoCenter`) when playback starts.
///
/// Requires the `com.apple.developer.carplay-audio` entitlement, which
/// Apple grants on application. For local testing, Xcode's CarPlay
/// simulator (Simulator → I/O → External Displays → CarPlay) works with
/// just the entitlements file declared in the project.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?

    private var client: JellyfinClient? {
        guard AuthManager.shared.isAuthenticated,
              let url = AuthManager.shared.serverURL else { return nil }
        return JellyfinClient(baseURL: url, auth: AuthManager.shared)
    }

    // MARK: - Scene lifecycle

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        AudioPlayer.shared.configureAudioSession()
        AudioPlayer.shared.authManager = AuthManager.shared

        if AuthManager.shared.isAuthenticated {
            interfaceController.setRootTemplate(buildRoot(), animated: false, completion: nil)
        } else {
            interfaceController.setRootTemplate(buildSignedOutTemplate(), animated: false, completion: nil)
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        self.interfaceController = nil
    }

    // MARK: - Root templates

    private func buildRoot() -> CPTabBarTemplate {
        CPTabBarTemplate(templates: [
            buildHomeTab(),
            buildLibraryTab(),
            buildPlaylistsTab(),
            buildDownloadsTab(),
            buildSearchTab()
        ])
    }

    private func buildSignedOutTemplate() -> CPListTemplate {
        let item = CPListItem(text: "Open Bolera on your iPhone to sign in to your Jellyfin server.",
                              detailText: nil)
        let template = CPListTemplate(title: "Bolera", sections: [CPListSection(items: [item])])
        return template
    }

    // MARK: - Tabs

    private func buildHomeTab() -> CPListTemplate {
        let template = CPListTemplate(title: "Home", sections: [])
        template.tabTitle = "Home"
        template.tabImage = UIImage(systemName: "house.fill")
        Task { await loadHome(into: template) }
        return template
    }

    private func loadHome(into template: CPListTemplate) async {
        guard let client = client else { return }
        async let recentPlayedTask = client.recentlyPlayed(limit: 30)
        async let recentAddedTask = client.recentlyAdded(limit: 30)
        let recent = (try? await recentPlayedTask) ?? []
        let added = (try? await recentAddedTask) ?? []

        let recentRows = recent.map { item in
            row(for: item, subtitle: item.primaryArtistName) { [weak self] in
                self?.playSingle(item)
            }
        }
        let addedRows = added.map { album in
            row(for: album, subtitle: album.primaryArtistName) { [weak self] in
                self?.playAlbum(album)
            }
        }

        var sections: [CPListSection] = []
        if !recentRows.isEmpty {
            sections.append(CPListSection(items: recentRows, header: "Recently Played", sectionIndexTitle: nil))
        }
        if !addedRows.isEmpty {
            sections.append(CPListSection(items: addedRows, header: "Recently Added", sectionIndexTitle: nil))
        }
        await MainActor.run { template.updateSections(sections) }
    }

    private func buildLibraryTab() -> CPListTemplate {
        let artists = CPListItem(text: "Artists", detailText: nil)
        artists.accessoryType = .disclosureIndicator
        artists.handler = { [weak self] _, completion in
            self?.pushArtists(); completion()
        }
        let albums = CPListItem(text: "Albums", detailText: nil)
        albums.accessoryType = .disclosureIndicator
        albums.handler = { [weak self] _, completion in
            self?.pushAlbums(); completion()
        }
        let favorites = CPListItem(text: "Favorites", detailText: nil)
        favorites.accessoryType = .disclosureIndicator
        favorites.handler = { [weak self] _, completion in
            self?.pushFavorites(); completion()
        }
        let template = CPListTemplate(title: "Library", sections: [
            CPListSection(items: [artists, albums, favorites])
        ])
        template.tabTitle = "Library"
        template.tabImage = UIImage(systemName: "music.note.list")
        return template
    }

    private func buildPlaylistsTab() -> CPListTemplate {
        let template = CPListTemplate(title: "Playlists", sections: [])
        template.tabTitle = "Playlists"
        template.tabImage = UIImage(systemName: "list.bullet.rectangle")
        Task {
            guard let client = client else { return }
            let lists = (try? await client.playlists()) ?? []
            let rows = lists.map { pl in
                row(for: pl, subtitle: "\(pl.SongCount ?? pl.ChildCount ?? 0) tracks") { [weak self] in
                    self?.pushPlaylist(pl)
                }
            }
            await MainActor.run { template.updateSections([CPListSection(items: rows)]) }
        }
        return template
    }

    private func buildDownloadsTab() -> CPListTemplate {
        let template = CPListTemplate(title: "Downloads", sections: [])
        template.tabTitle = "Downloads"
        template.tabImage = UIImage(systemName: "arrow.down.circle")
        let downloads = DownloadManager.shared
        let items = downloads.completed.compactMap { downloads.metadata[$0] }
            .sorted { $0.Name < $1.Name }
        let rows = items.map { item in
            row(for: item, subtitle: item.primaryArtistName) { [weak self] in
                self?.playSingle(item)
            }
        }
        template.updateSections([CPListSection(items: rows)])
        return template
    }

    private func buildSearchTab() -> CPSearchTemplate {
        let template = CPSearchTemplate()
        template.tabTitle = "Search"
        template.tabImage = UIImage(systemName: "magnifyingglass")
        template.delegate = self
        return template
    }

    // MARK: - Pushed lists

    private func pushArtists() {
        guard let controller = interfaceController, let client = client else { return }
        let template = CPListTemplate(title: "Artists", sections: [])
        controller.pushTemplate(template, animated: true, completion: nil)
        Task {
            let artists = (try? await client.artists(limit: 500)) ?? []
            let rows = artists.map { artist in
                row(for: artist, subtitle: nil) { [weak self] in
                    self?.pushArtist(artist)
                }
            }
            await MainActor.run { template.updateSections([CPListSection(items: rows)]) }
        }
    }

    private func pushArtist(_ artist: BaseItem) {
        guard let controller = interfaceController, let client = client else { return }
        let template = CPListTemplate(title: artist.Name, sections: [])
        controller.pushTemplate(template, animated: true, completion: nil)
        Task {
            let albums = (try? await client.albumsForArtist(artist.Id)) ?? []
            let rows = albums.map { album in
                row(for: album, subtitle: album.ProductionYear.map(String.init)) { [weak self] in
                    self?.pushAlbum(album)
                }
            }
            await MainActor.run { template.updateSections([CPListSection(items: rows)]) }
        }
    }

    private func pushAlbums() {
        guard let controller = interfaceController, let client = client else { return }
        let template = CPListTemplate(title: "Albums", sections: [])
        controller.pushTemplate(template, animated: true, completion: nil)
        Task {
            let albums = (try? await client.albums(limit: 500)) ?? []
            let rows = albums.map { album in
                row(for: album, subtitle: album.primaryArtistName) { [weak self] in
                    self?.pushAlbum(album)
                }
            }
            await MainActor.run { template.updateSections([CPListSection(items: rows)]) }
        }
    }

    private func pushAlbum(_ album: BaseItem) {
        guard let controller = interfaceController, let client = client else { return }
        let template = CPListTemplate(title: album.Name, sections: [])
        controller.pushTemplate(template, animated: true, completion: nil)
        Task {
            let songs = (try? await client.songs(parentId: album.Id)) ?? []
            let rows = songs.enumerated().map { (idx, song) in
                row(for: song, subtitle: song.durationSeconds.mmSS) { [weak self] in
                    AudioPlayer.shared.play(items: songs, startAt: idx)
                    self?.showNowPlaying()
                }
            }
            await MainActor.run { template.updateSections([CPListSection(items: rows)]) }
        }
    }

    private func pushPlaylist(_ playlist: BaseItem) {
        guard let controller = interfaceController, let client = client else { return }
        let template = CPListTemplate(title: playlist.Name, sections: [])
        controller.pushTemplate(template, animated: true, completion: nil)
        Task {
            let songs = (try? await client.playlistItems(playlist.Id)) ?? []
            let rows = songs.enumerated().map { (idx, song) in
                row(for: song, subtitle: song.primaryArtistName) { [weak self] in
                    AudioPlayer.shared.play(items: songs, startAt: idx)
                    self?.showNowPlaying()
                }
            }
            await MainActor.run { template.updateSections([CPListSection(items: rows)]) }
        }
    }

    private func pushFavorites() {
        guard let controller = interfaceController, let client = client else { return }
        let template = CPListTemplate(title: "Favorites", sections: [])
        controller.pushTemplate(template, animated: true, completion: nil)
        Task {
            async let albumsTask = client.favorites(type: "MusicAlbum", limit: 200)
            async let songsTask = client.favorites(type: "Audio", limit: 200)
            let albums = (try? await albumsTask) ?? []
            let songs = (try? await songsTask) ?? []

            let albumRows = albums.map { album in
                row(for: album, subtitle: album.primaryArtistName) { [weak self] in
                    self?.playAlbum(album)
                }
            }
            let songRows = songs.enumerated().map { (idx, song) in
                row(for: song, subtitle: song.primaryArtistName) { [weak self] in
                    AudioPlayer.shared.play(items: songs, startAt: idx)
                    self?.showNowPlaying()
                }
            }
            var sections: [CPListSection] = []
            if !albumRows.isEmpty { sections.append(CPListSection(items: albumRows, header: "Albums", sectionIndexTitle: nil)) }
            if !songRows.isEmpty { sections.append(CPListSection(items: songRows, header: "Songs", sectionIndexTitle: nil)) }
            await MainActor.run { template.updateSections(sections) }
        }
    }

    // MARK: - Playback

    fileprivate func playSingle(_ item: BaseItem) {
        AudioPlayer.shared.play(items: [item])
        showNowPlaying()
    }

    fileprivate func playAlbum(_ album: BaseItem) {
        guard let client = client else { return }
        Task {
            let songs = (try? await client.songs(parentId: album.Id)) ?? []
            guard !songs.isEmpty else { return }
            await MainActor.run {
                AudioPlayer.shared.play(items: songs)
                self.showNowPlaying()
            }
        }
    }

    fileprivate func showNowPlaying() {
        guard let controller = interfaceController else { return }
        if controller.topTemplate !== CPNowPlayingTemplate.shared {
            controller.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    // MARK: - List item helper

    private func row(for item: BaseItem, subtitle: String?, action: @escaping () -> Void) -> CPListItem {
        let row = CPListItem(text: item.Name, detailText: subtitle)
        row.accessoryType = .none
        row.handler = { _, completion in
            action()
            completion()
        }
        attachImage(to: row, for: item)
        return row
    }

    private func attachImage(to row: CPListItem, for item: BaseItem) {
        guard let client = client else { return }
        let artId: String
        let tag: String?
        if item.type == "Audio" {
            artId = item.AlbumId ?? item.Id
            tag = item.AlbumPrimaryImageTag
        } else {
            artId = item.Id
            tag = item.ImageTags?["Primary"]
        }
        guard let url = client.imageURL(for: artId, tag: tag, maxWidth: 240) else { return }
        Task {
            let img = await ImageCache.shared.load(url: url, headers: ["Authorization": AuthManager.shared.authHeader()])
            await MainActor.run { row.setImage(img) }
        }
    }
}

// MARK: - Search

extension CarPlaySceneDelegate: CPSearchTemplateDelegate {
    func searchTemplate(_ searchTemplate: CPSearchTemplate,
                        updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        guard !searchText.isEmpty, let client = client else {
            completionHandler([]); return
        }
        Task {
            let hints = (try? await client.search(searchText, limit: 30)) ?? []
            let rows: [CPListItem] = await withTaskGroup(of: CPListItem.self) { group in
                for hint in hints {
                    group.addTask { await self.row(forHint: hint) }
                }
                var out: [CPListItem] = []
                for await item in group { out.append(item) }
                return out
            }
            await MainActor.run { completionHandler(rows) }
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        if let handler = item.handler {
            handler(item, completionHandler)
        } else {
            completionHandler()
        }
    }

    private func row(forHint hint: SearchHint) async -> CPListItem {
        let title = hint.Name
        let subtitle: String
        switch hint.type {
        case "MusicArtist": subtitle = "Artist"
        case "MusicAlbum": subtitle = "Album • \(hint.AlbumArtist ?? "")"
        case "Audio": subtitle = "Song • \(hint.AlbumArtist ?? "")"
        case "Playlist": subtitle = "Playlist"
        default: subtitle = hint.type ?? ""
        }
        let row = CPListItem(text: title, detailText: subtitle)
        row.handler = { [weak self] _, completion in
            self?.handleSearch(hint: hint)
            completion()
        }
        if let client = self.client,
           let id = hint.ItemId ?? hint.Id,
           let url = client.imageURL(for: hint.type == "Audio" ? (hint.AlbumId ?? id) : id,
                                     tag: hint.PrimaryImageTag, maxWidth: 240) {
            let img = await ImageCache.shared.load(url: url, headers: ["Authorization": AuthManager.shared.authHeader()])
            await MainActor.run { row.setImage(img) }
        }
        return row
    }

    private func handleSearch(hint: SearchHint) {
        guard let client = client, let id = hint.ItemId ?? hint.Id else { return }
        Task {
            switch hint.type {
            case "Audio":
                if let item = try? await client.item(id) {
                    await MainActor.run { self.playSingle(item) }
                }
            case "MusicAlbum":
                if let item = try? await client.item(id) {
                    await MainActor.run { self.playAlbum(item) }
                }
            case "Playlist":
                if let songs = try? await client.playlistItems(id) {
                    await MainActor.run {
                        AudioPlayer.shared.play(items: songs)
                        self.showNowPlaying()
                    }
                }
            case "MusicArtist":
                if let mix = try? await client.instantMix(itemId: id) {
                    await MainActor.run {
                        AudioPlayer.shared.play(items: mix)
                        self.showNowPlaying()
                    }
                }
            default: break
            }
        }
    }
}
