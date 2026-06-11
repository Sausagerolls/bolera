import SwiftUI
import BoleraCore

struct AlbumDetail_Mac: View {
    let album: BaseItem
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var pinned: PinnedItemsStore
    @EnvironmentObject var nav: MacNavCoordinator

    @State private var fullAlbum: BaseItem?
    @State private var songs: [BaseItem] = []
    @State private var artwork: PlatformImage?
    @State private var loading = false
    @ObservedObject private var favSync = FavoritesSync.shared

    private var current: BaseItem { fullAlbum ?? album }
    private var isFavorite: Bool {
        favSync.isFavorite(current)
    }
    private var isPinned: Bool { pinned.isPinned(itemId: current.Id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                actionBar
                trackList
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: album.Id) { await load() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ZStack {
                Color.gray.opacity(0.15)
                if let artwork {
                    Image(nsImage: artwork).resizable().scaledToFill()
                } else {
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 72))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 240, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.5), radius: 18, x: 0, y: 10)

            VStack(alignment: .leading, spacing: 6) {
                Text("Album").font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                Text(current.Name).font(.system(size: 38, weight: .bold)).lineLimit(2)
                HStack(spacing: 6) {
                    Button { goToArtist() } label: {
                        Text(current.primaryArtistName).bold()
                    }
                    .buttonStyle(.plain)
                    .disabled(artistId == nil)
                    if let year = current.ProductionYear {
                        Text("•  \(String(year))").foregroundStyle(.secondary)
                    }
                    if !songs.isEmpty {
                        Text("•  \(songs.count) tracks").foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            Spacer()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button {
                player.play(items: songs)
            } label: {
                Label("Play All", systemImage: "play.fill")
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(songs.isEmpty)

            Button {
                var s = songs; s.shuffle()
                player.play(items: s)
            } label: {
                Label("Shuffle", systemImage: "shuffle")
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            .controlSize(.large)
            .disabled(songs.isEmpty)

            iconActionButton(isFavorite ? "heart.fill" : "heart",
                             active: isFavorite,
                             help: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                toggleFavorite()
            }
            downloadActionView
            iconActionButton(isPinned ? "pin.slash" : "pin",
                             active: isPinned,
                             help: isPinned ? "Unpin from Sidebar" : "Pin to Sidebar") {
                pinned.togglePin(current)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func iconActionButton(_ icon: String, active: Bool = false, help: String,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(active ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var trackList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("#").frame(width: 32, alignment: .trailing)
                Text("Title").frame(maxWidth: .infinity, alignment: .leading)
                Text("Duration").frame(width: 80, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                HStack {
                    Group {
                        if player.current?.Id == song.Id {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint)
                        } else {
                            Text("\(song.IndexNumber ?? idx + 1)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 32, alignment: .trailing)
                    VStack(alignment: .leading) {
                        Text(song.Name).lineLimit(1)
                        if !song.primaryArtistName.isEmpty {
                            Text(song.primaryArtistName)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(song.durationSeconds.mmSS)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .onTapGesture { player.play(items: songs, startAt: idx) }
                .background(.thinMaterial.opacity(idx.isMultiple(of: 2) ? 0 : 0.3))
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Actions

    private var artistId: String? {
        current.AlbumArtists?.first?.Id ?? current.ArtistItems?.first?.Id
    }

    private func goToArtist() {
        guard let id = artistId else { return }
        let name = current.primaryArtistName
        nav.openArtist(BaseItem.stub(id: id, name: name, type: "MusicArtist"))
    }

    private func toggleFavorite() {
        guard let url = auth.serverURL else { return }
        favSync.setFavorite(current.Id, favorite: !isFavorite,
                            client: JellyfinClient(baseURL: url, auth: auth))
    }

    /// Replacement for the plain icon button: shows a spinner + remaining
    /// count while any track is actively downloading, otherwise falls back
    /// to the tri-state icon (none / partial / all).
    @ViewBuilder
    private var downloadActionView: some View {
        let downloading = songs.filter { downloads.inProgress[$0.Id] != nil }.count
        if downloading > 0 {
            VStack(spacing: 2) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                Text("\(downloading) left")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("Downloading \(downloading) tracks…")
        } else {
            iconActionButton(downloadIcon,
                             active: downloadState != .none,
                             help: downloadHelp) {
                downloadButtonTapped()
            }
            .disabled(songs.isEmpty)
        }
    }

    /// Tri-state for the album-level download button.
    private enum DownloadState { case none, partial, all }
    private var downloadState: DownloadState {
        guard !songs.isEmpty else { return .none }
        let done = songs.filter { downloads.isDownloaded($0.Id) }.count
        if done == 0 { return .none }
        if done == songs.count { return .all }
        return .partial
    }
    private var downloadIcon: String {
        switch downloadState {
        case .none:    return "arrow.down.circle"
        case .partial: return "arrow.down.circle.fill"
        case .all:     return "checkmark.circle.fill"
        }
    }
    private var downloadHelp: String {
        let total = songs.count
        let done = songs.filter { downloads.isDownloaded($0.Id) }.count
        switch downloadState {
        case .none:    return "Download Album"
        case .partial: return "Download \(total - done) remaining"
        case .all:     return "Downloaded — click to remove"
        }
    }

    private func downloadButtonTapped() {
        switch downloadState {
        case .none, .partial:
            downloadAlbum()
        case .all:
            removeDownloadedAlbum()
        }
    }

    private func downloadAlbum() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        for song in songs where !downloads.isDownloaded(song.Id) {
            downloads.download(song, using: client)
        }
    }

    private func removeDownloadedAlbum() {
        for song in songs where downloads.isDownloaded(song.Id) {
            downloads.delete(song.Id)
        }
    }

    @MainActor
    private func load() async {
        fullAlbum = nil
        artwork = nil
        let songsKey = "album.\(album.Id).songs"
        songs = LibraryCache.shared.read(songsKey, as: [BaseItem].self) ?? []

        guard let url = auth.serverURL, !album.Id.isEmpty else { return }
        loading = true
        defer { loading = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let header = ["Authorization": auth.authHeader()]

        // Sequential awaits (artwork first so the hero image lands ASAP).
        // Avoids async-let / Task.detached actor-boundary crashes during
        // navigation teardown. Prefer a downloaded local cover so it shows offline.
        if let img = await ImageCache.shared.loadArtwork(itemId: album.Id,
                                                         tag: album.ImageTags?["Primary"],
                                                         client: client,
                                                         maxWidth: 600,
                                                         headers: header) {
            self.artwork = img
        }
        if let full = try? await client.item(album.Id) {
            fullAlbum = full
        }
        if let s = try? await client.songs(parentId: album.Id) {
            var seen: Set<String> = []
            let cleaned = s.filter { $0.type == "Audio" && seen.insert($0.Id).inserted }
            songs = cleaned
            LibraryCache.shared.write(songsKey, value: cleaned)
        }
    }
}

private extension Double {
    var mmSS: String {
        guard !isNaN, isFinite else { return "0:00" }
        let total = max(0, Int(self))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
