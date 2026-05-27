import SwiftUI
import BoleraCore

struct HomeView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var daily: DailyPlaylistStore
    @EnvironmentObject var lastFm: LastFmService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let err = library.lastError {
                    Text("API error: \(err)")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal)
                }

                if !daily.playlists.isEmpty {
                    dailySection
                }

                if !library.recentlyPlayed.isEmpty {
                    section(title: "Recently Played", items: library.recentlyPlayed)
                }
                if !library.recentlyAdded.isEmpty {
                    section(title: "Recently Added", items: library.recentlyAdded)
                }
                if !library.frequentAlbums.isEmpty {
                    section(title: "On Repeat", items: library.frequentAlbums)
                }
                if !library.favoriteAlbums.isEmpty {
                    section(title: "Favorites", items: library.favoriteAlbums)
                }
                Color.clear.frame(height: 100)
            }
            .padding(.vertical)
        }
        .navigationTitle("Home")
        .navigationDestination(for: BaseItem.self) { item in
            if item.type == "MusicArtist" {
                ArtistDetailView(artist: item)
            } else {
                AlbumDetailView(album: item)
            }
        }
        .refreshable { await reload(force: true) }
        .task { await reload(force: false) }
    }

    private func reload(force: Bool) async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        await library.refresh(client: client)
        if force {
            await daily.regenerate(client: client, auth: auth, lastFm: lastFm)
        } else {
            await daily.refreshIfNeeded(client: client, auth: auth, lastFm: lastFm)
        }
    }

    // MARK: - Daily section

    private var dailySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Daily Mixes").font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(daily.playlists) { playlist in
                        DailyPlaylistTile(playlist: playlist)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func section(title: String, items: [BaseItem]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title2.bold()).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { item in
                        homeTile(item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func homeTile(_ item: BaseItem) -> some View {
        if item.type == "Audio" {
            Button {
                AudioPlayer.shared.play(items: [item])
            } label: {
                tileContent(item)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: item) {
                tileContent(item)
            }
            .buttonStyle(.plain)
        }
    }

    private func tileContent(_ item: BaseItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            JellyfinImage(itemId: item.artworkItemId, tag: item.artworkTag, maxWidth: 400, cornerRadius: 10)
                .frame(width: 150, height: 150)
            Text(item.Name).font(.subheadline).lineLimit(1)
            Text(item.primaryArtistName.isEmpty ? (item.Album ?? "") : item.primaryArtistName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
    }
}

// MARK: - Daily playlist tile

struct DailyPlaylistTile: View {
    let playlist: DailyPlaylist
    @EnvironmentObject var daily: DailyPlaylistStore

    private let tileWidth: CGFloat = 225  // 1.5x album tile width
    private let tileHeight: CGFloat = 150

    var body: some View {
        Button {
            AudioPlayer.shared.play(items: playlist.tracks)
        } label: {
            ZStack(alignment: .bottomLeading) {
                if let img = daily.artworkByPlaylist[playlist.id] {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    LinearGradient(colors: [Color.accentColor.opacity(0.4), .black.opacity(0.7)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(playlist.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(12)
                }
            }
            .frame(width: tileWidth, height: tileHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
