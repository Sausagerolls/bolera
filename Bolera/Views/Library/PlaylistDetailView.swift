import SwiftUI
import BoleraCore

struct PlaylistDetailView: View {
    let playlist: BaseItem
    @EnvironmentObject var auth: AuthManager
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var songs: [BaseItem] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                JellyfinImage(itemId: playlist.Id, tag: playlist.ImageTags?["Primary"], maxWidth: 800, cornerRadius: 14)
                    .frame(width: 260, height: 260)
                    .shadow(radius: 20)
                Text(playlist.Name).font(.title2.bold()).multilineTextAlignment(.center)

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
                        HStack(spacing: 12) {
                            JellyfinImage(itemId: song.AlbumId ?? song.Id, tag: song.AlbumPrimaryImageTag, maxWidth: 120, cornerRadius: 6)
                                .frame(width: 44, height: 44)
                            VStack(alignment: .leading) {
                                Text(song.Name).lineLimit(1)
                                Text(song.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(song.durationSeconds.mmSS).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { AudioPlayer.shared.play(items: songs, startAt: idx) }
                        .contextMenu {
                            Button { AudioPlayer.shared.playNext(song) } label: { Label("Play Next", systemImage: "text.insert") }
                            Button { AudioPlayer.shared.addToQueue(song) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                            IgnoreToggleButton(item: song)
                        }
                        Divider().padding(.leading, 56)
                    }
                }
                .padding(.horizontal)

                Button {
                    if isFullyDownloaded { removeDownload() } else { downloadPlaylist() }
                } label: {
                    VStack(spacing: 6) {
                        Label(downloadLabel, systemImage: isFullyDownloaded ? "trash" : "arrow.down.circle")
                            .foregroundStyle(isFullyDownloaded ? Color.red : Color.primary)
                        if let p = downloadProgress {
                            ProgressView(value: p).tint(.accentColor)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(songs.isEmpty || dlActive)
                .padding(.horizontal)

                Color.clear.frame(height: 120)
            }
        }
        .navigationTitle(playlist.Name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        songs = (try? await client.playlistItems(playlist.Id)) ?? []
    }

    private var dlDoneCount: Int { songs.filter { downloads.completed.contains($0.Id) }.count }
    private var dlActiveSongs: [BaseItem] { songs.filter { downloads.inProgress.keys.contains($0.Id) } }
    private var dlActive: Bool { !dlActiveSongs.isEmpty }

    /// Count-based (completed / total) so the bar only ever advances. A
    /// byte-sum over the *active* downloads jitters: the active set churns as
    /// tracks finish and others start at total=0, making the fraction
    /// non-monotonic.
    private var downloadProgress: Double? {
        guard dlActive, !songs.isEmpty else { return nil }
        return Double(dlDoneCount) / Double(songs.count)
    }

    private var isFullyDownloaded: Bool { !songs.isEmpty && dlDoneCount == songs.count }

    private var downloadLabel: String {
        if dlActive { return "Downloading \(dlDoneCount)/\(songs.count)" }
        if isFullyDownloaded { return "Remove Download" }
        if dlDoneCount > 0 { return "Download Rest (\(songs.count - dlDoneCount))" }
        return "Download Playlist"
    }

    private func downloadPlaylist() {
        guard let url = auth.serverURL, !songs.isEmpty else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        DownloadManager.shared.downloadPlaylist(playlist, tracks: songs, using: client)
    }

    private func removeDownload() {
        DownloadManager.shared.removeDownloadedPlaylist(playlist.Id)
    }
}
