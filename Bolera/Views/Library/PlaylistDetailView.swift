import SwiftUI
import BoleraCore

struct PlaylistDetailView: View {
    let playlist: BaseItem
    @EnvironmentObject var auth: AuthManager
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
}
