import SwiftUI
import BoleraCore

struct AlbumDetailView: View {
    let album: BaseItem
    @EnvironmentObject var auth: AuthManager
    @State private var songs: [BaseItem] = []
    @State private var isFavorite: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                JellyfinImage(itemId: album.Id, tag: album.ImageTags?["Primary"], maxWidth: 800, cornerRadius: 14)
                    .frame(width: 260, height: 260)
                    .shadow(radius: 20)
                VStack(spacing: 4) {
                    Text(album.Name).font(.title2.bold()).multilineTextAlignment(.center)
                    Text(album.primaryArtistName).foregroundStyle(.secondary)
                    if let year = album.ProductionYear {
                        Text(String(year)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    Button {
                        AudioPlayer.shared.play(items: songs)
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.accentColor).foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Button {
                        AudioPlayer.shared.shuffle = true
                        AudioPlayer.shared.play(items: songs)
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal)

                LazyVStack(spacing: 0) {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                        SongRow(index: song.IndexNumber ?? (idx + 1), song: song) {
                            AudioPlayer.shared.play(items: songs, startAt: idx)
                        }
                        .contextMenu {
                            Button { AudioPlayer.shared.playNext(song) } label: { Label("Play Next", systemImage: "text.insert") }
                            Button { AudioPlayer.shared.addToQueue(song) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                            downloadMenuButton(for: song)
                            IgnoreToggleButton(item: song)
                        }
                        Divider().padding(.leading, 56)
                    }
                }
                .padding(.horizontal)

                Button {
                    downloadAll()
                } label: {
                    Label(allDownloadedLabel, systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal)

                Color.clear.frame(height: 120)
            }
        }
        .navigationTitle(album.Name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleFavorite()
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        songs = (try? await client.songs(parentId: album.Id)) ?? []
        isFavorite = album.UserData?.IsFavorite ?? false
    }

    private func toggleFavorite() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        isFavorite.toggle()
        Task { try? await client.setFavorite(album.Id, favorite: isFavorite) }
    }

    private var allDownloadedLabel: String {
        let dm = DownloadManager.shared
        let done = songs.filter { dm.isDownloaded($0.Id) }.count
        if done == songs.count, !songs.isEmpty { return "Downloaded" }
        if done > 0 { return "Download Rest (\(songs.count - done))" }
        return "Download Album"
    }

    private func downloadAll() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let dm = DownloadManager.shared
        for song in songs where !dm.isDownloaded(song.Id) {
            dm.download(song, using: client)
        }
    }

    @ViewBuilder
    private func downloadMenuButton(for song: BaseItem) -> some View {
        if DownloadManager.shared.isDownloaded(song.Id) {
            Button(role: .destructive) {
                DownloadManager.shared.delete(song.Id)
            } label: { Label("Remove Download", systemImage: "trash") }
        } else {
            Button {
                guard let url = auth.serverURL else { return }
                DownloadManager.shared.download(song, using: JellyfinClient(baseURL: url, auth: auth))
            } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
    }
}

struct SongRow: View {
    let index: Int
    let song: BaseItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text("\(index)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading) {
                    Text(song.Name).font(.body).lineLimit(1)
                    if !song.primaryArtistName.isEmpty {
                        Text(song.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Text(song.durationSeconds.mmSS)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}
