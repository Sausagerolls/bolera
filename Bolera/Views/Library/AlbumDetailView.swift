import SwiftUI
import BoleraCore

struct AlbumDetailView: View {
    let album: BaseItem
    @EnvironmentObject var auth: AuthManager
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var songs: [BaseItem] = []
    @State private var isFavorite: Bool = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                JellyfinImage(itemId: album.Id, tag: album.ImageTags?["Primary"], maxWidth: 600, cornerRadius: 14)
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
                    VStack(spacing: 6) {
                        Label(allDownloadedLabel, systemImage: "arrow.down.circle")
                        if let p = albumProgress {
                            ProgressView(value: p).tint(.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(downloadedCount == songs.count && !songs.isEmpty)
                .padding(.horizontal)

                Color.clear.frame(height: 120)
            }
        }
        .background(BoleraBackground().ignoresSafeArea())
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
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    IgnoreAlbumToggleButton(item: album)
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
        songs = (try? await client.songs(parentId: album.Id)) ?? []
        isFavorite = album.UserData?.IsFavorite ?? false
    }

    private func toggleFavorite() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        isFavorite.toggle()
        Task { try? await client.setFavorite(album.Id, favorite: isFavorite) }
    }

    private var downloadedCount: Int {
        songs.filter { downloads.completed.contains($0.Id) }.count
    }

    private var downloadingSongs: [BaseItem] {
        songs.filter { downloads.inProgress.keys.contains($0.Id) }
    }

    /// Count-based (completed / total) so the bar only advances. A byte-sum
    /// over the active downloads jitters because the active set churns as
    /// tracks finish and others start at total=0 (non-monotonic fraction).
    private var albumProgress: Double? {
        guard !downloadingSongs.isEmpty, !songs.isEmpty else { return nil }
        return Double(downloadedCount) / Double(songs.count)
    }

    private var allDownloadedLabel: String {
        if !downloadingSongs.isEmpty { return "Downloading \(downloadedCount)/\(songs.count)" }
        if downloadedCount == songs.count, !songs.isEmpty { return "Downloaded" }
        if downloadedCount > 0 { return "Download Rest (\(songs.count - downloadedCount))" }
        return "Download Album"
    }

    private func downloadAll() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        DownloadManager.shared.downloadAlbum(album, tracks: songs, using: client)
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
                DownloadManager.shared.download(song, using: JellyfinClient(baseURL: url, auth: auth), individual: true)
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
                NowPlayingIndexMarker(trackId: song.Id, index: index)
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
