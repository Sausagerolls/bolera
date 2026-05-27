import SwiftUI
import BoleraCore

struct NowPlayingPane_Mac: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var auth: AuthManager
    @State private var artwork: PlatformImage?

    var body: some View {
        VStack(spacing: 16) {
            if let current = player.current {
                artworkView
                    .frame(width: 260, height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(radius: 12)
                    .padding(.top, 28)

                VStack(spacing: 4) {
                    Text(current.Name).font(.title3).bold().multilineTextAlignment(.center)
                    Text(current.primaryArtistName)
                        .font(.subheadline).foregroundStyle(.secondary)
                    if let album = current.Album {
                        Text(album).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal)

                ProgressView(value: player.duration > 0 ? player.currentTime / player.duration : 0)
                    .progressViewStyle(.linear)
                    .padding(.horizontal)

                HStack {
                    Text(player.currentTime.mmSS)
                    Spacer()
                    Text(player.duration.mmSS)
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal)

                HStack(spacing: 24) {
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle")
                            .foregroundStyle(player.shuffle ? Color.accentColor : Color.secondary)
                    }
                    Button { player.previous() } label: {
                        Image(systemName: "backward.fill").font(.title2)
                    }
                    Button { player.togglePlayPause() } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                    }
                    Button { player.next() } label: {
                        Image(systemName: "forward.fill").font(.title2)
                    }
                    Button { player.cycleRepeatMode() } label: {
                        Image(systemName: repeatIcon)
                            .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)

                Spacer()

                QueueList_Mac()
            } else {
                ContentUnavailableView("Nothing Playing",
                                       systemImage: "music.note",
                                       description: Text("Pick a track from the library."))
            }
        }
        .task(id: player.current?.Id) { await loadArtwork() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    private var artworkView: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork).resizable().scaledToFill()
            } else {
                Image(systemName: "music.note").font(.system(size: 80)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.15))
            }
        }
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off: return "repeat"
        case .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private func loadArtwork() async {
        artwork = nil
        guard let current = player.current,
              let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let imgURL = client.imageURL(for: current.artworkItemId, tag: current.artworkTag, maxWidth: 600)
        guard let imgURL else { return }
        let img = await ImageCache.shared.load(url: imgURL, headers: ["Authorization": auth.authHeader()])
        await MainActor.run { self.artwork = img }
    }
}

private struct QueueList_Mac: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        DisclosureGroup("Up Next (\(max(0, player.queue.count - player.currentIndex - 1)))") {
            List {
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { idx, item in
                    HStack {
                        if idx == player.currentIndex {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                        }
                        VStack(alignment: .leading) {
                            Text(item.Name).lineLimit(1)
                            Text(item.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(item.durationSeconds.mmSS).font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { player.jumpTo(index: idx) }
                    .swipeActions(edge: .leading) {
                        IgnoreSwipeButton_Mac(item: item)
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .padding(.horizontal)
    }
}

private extension Double {
    var mmSS: String {
        let total = Int(self)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
