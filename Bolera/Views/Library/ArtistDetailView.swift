import SwiftUI
import BoleraCore

struct ArtistDetailView: View {
    let artist: BaseItem
    @EnvironmentObject var auth: AuthManager
    @State private var albums: [BaseItem] = []
    @State private var similar: [BaseItem] = []

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
                        Label("Radio", systemImage: "antenna.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal)

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
                            }
                        }
                    }
                }
                .padding(.horizontal)

                if !similar.isEmpty {
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
        .navigationDestination(for: BaseItem.self) { item in
            if item.type == "MusicArtist" { ArtistDetailView(artist: item) }
            else { AlbumDetailView(album: item) }
        }
        .navigationTitle(artist.Name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        albums = (try? await client.albumsForArtist(artist.Id)) ?? []
        similar = (try? await client.similarArtists(artist.Id)) ?? []
    }

    private func playAllTopTracks() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        Task {
            var all: [BaseItem] = []
            for album in albums {
                if let songs = try? await client.songs(parentId: album.Id) {
                    all.append(contentsOf: songs)
                }
            }
            await MainActor.run { AudioPlayer.shared.play(items: all) }
        }
    }

    private func radio() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        Task {
            if let mix = try? await client.instantMix(itemId: artist.Id) {
                await MainActor.run { AudioPlayer.shared.play(items: mix) }
            }
        }
    }
}
