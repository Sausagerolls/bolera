import SwiftUI
import BoleraCore

enum SidebarSelection: Hashable {
    case home
    case artists
    case albums
    case playlists
    case downloads
    case favorites
    case search
    case library(String)  // Jellyfin library Id
    case albumDetail(BaseItem)
    case artistDetail(BaseItem)
}

struct MainWindow_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var pro: ProEntitlementStore
    @EnvironmentObject var nav: MacNavCoordinator
    @Environment(\.openWindow) private var openWindow

    @State private var search: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var immersive: Bool = false
    @ObservedObject private var connectivity = ConnectivityStore.shared

    private var sidebarSelectionBinding: Binding<SidebarSelection?> {
        Binding(
            get: { nav.selection },
            set: { newValue in
                // Sidebar List-driven selection clears history; detail-page
                // openers (openAlbum/openArtist) populate it.
                nav.clearHistory()
                nav.selection = newValue
            }
        )
    }

    var body: some View {
        Group {
            if immersive {
                ImmersivePlayer_Mac {
                    withAnimation(.easeInOut(duration: 0.25)) { immersive = false }
                }
                .transition(.opacity)
                // Hide the toolbar + paint behind the title bar so the
                // immersive player fills the whole window edge-to-edge
                // instead of leaving the system "Bolera" title strip.
                .toolbar(.hidden, for: .windowToolbar)
                .toolbarBackground(.hidden, for: .windowToolbar)
                .ignoresSafeArea()
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView_Mac(selection: sidebarSelectionBinding)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } detail: {
                    VStack(spacing: 0) {
                        ContentPane_Mac(selection: nav.selection ?? .home, searchQuery: $search)
                        BottomPlayerBar_Mac {
                            withAnimation(.easeInOut(duration: 0.25)) { immersive = true }
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .transition(.opacity)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            nav.selection = .search
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .help("Search (⌘F)")
                        .keyboardShortcut("f", modifiers: .command)
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !connectivity.isOnline && !immersive {
                OfflineBanner_Mac()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: connectivity.isOnline)
    }
}

struct OfflineBanner_Mac: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
            Text("Offline — reconnect to your server").lineLimit(1)
            Spacer()
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.85))
    }
}

// MARK: - Bottom player strip

struct BottomPlayerBar_Mac: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var nav: MacNavCoordinator
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore
    let onExpand: () -> Void
    @State private var artwork: PlatformImage?
    @State private var favOverride: Bool?
    @State private var showQueue = false
    @State private var isScrubbing = false
    @State private var scrub: Double = 0
    @State private var ignoreSlideSetUntil: Date = .distantPast

    private var isFavorite: Bool {
        favOverride ?? (player.current?.UserData?.IsFavorite ?? false)
    }
    private var isDownloaded: Bool {
        guard let id = player.current?.Id else { return false }
        return downloads.isDownloaded(id)
    }
    private var isDownloading: Bool {
        guard let id = player.current?.Id else { return false }
        return downloads.inProgress[id] != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(spacing: 6) {
                // Top row: artwork + meta on the left, transport in the
                // middle, secondary controls on the right.
                HStack(spacing: 12) {
                    Button(action: onExpand) {
                        artworkThumb
                            .frame(width: 40, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Open Now Playing")
                    .disabled(player.current == nil)
                    Button(action: onExpand) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.current?.Name ?? "Nothing Playing")
                                .font(.subheadline).lineLimit(1)
                            Text(player.current?.primaryArtistName ?? "—")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(player.current == nil)
                    .frame(width: 200, alignment: .leading)

                    Spacer()

                    HStack(spacing: 16) {
                        transportButton("shuffle", active: player.shuffle) { player.toggleShuffle() }
                        Button { player.previous() } label: { Image(systemName: "backward.fill") }
                            .buttonStyle(.plain)
                        Button { player.togglePlayPause() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 28))
                        }
                        .buttonStyle(.plain)
                        Button { player.next() } label: { Image(systemName: "forward.fill") }
                            .buttonStyle(.plain)
                        transportButton(repeatIcon, active: player.repeatMode != .off) {
                            player.cycleRepeatMode()
                        }
                    }

                    Spacer()

                    HStack(spacing: 14) {
                        iconButton(isFavorite ? "heart.fill" : "heart",
                                   active: isFavorite,
                                   help: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                            toggleFavorite()
                        }
                        downloadButton
                        if pro.isPro {
                            iconButton("hand.raised.slash.fill",
                                       help: "Skip & Ignore — never auto-play again") {
                                skipAndIgnore()
                            }
                        }
                        iconButton("list.bullet",
                                   help: "Show Queue") {
                            showQueue = true
                        }
                        Menu {
                            playerContextMenu
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 24)
                        .help("More")
                        iconButton("rectangle.expand.vertical",
                                   help: "Open Now Playing (⌘⇧N)") {
                            onExpand()
                        }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                    }
                    .disabled(player.current == nil)
                    .frame(width: 200, alignment: .trailing)
                }

                // Bottom row: full-width scrubber spans the entire bar.
                scrubber
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .task(id: player.current?.Id) { await loadArtwork() }
        .onChange(of: player.current?.Id) { _, _ in
            favOverride = nil
        }
        .sheet(isPresented: $showQueue) {
            QueueSheet_Mac().frame(minWidth: 420, minHeight: 480)
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if isDownloading {
            ProgressView().controlSize(.small)
                .help("Downloading…")
        } else if isDownloaded {
            iconButton("checkmark.circle.fill",
                       active: true,
                       help: "Downloaded — click to remove") {
                guard let id = player.current?.Id else { return }
                downloads.delete(id)
            }
        } else {
            iconButton("arrow.down.circle",
                       help: "Download") {
                guard let cur = player.current,
                      let url = auth.serverURL else { return }
                let client = JellyfinClient(baseURL: url, auth: auth)
                downloads.download(cur, using: client)
            }
        }
    }

    @ViewBuilder
    private var playerContextMenu: some View {
        if let cur = player.current {
            if let albumId = cur.AlbumId {
                Button {
                    nav.openAlbum(BaseItem.stub(id: albumId,
                                                name: cur.Album ?? "",
                                                type: "MusicAlbum"))
                } label: { Label("Go to Album", systemImage: "opticaldisc") }
            }
            if let artistId = cur.AlbumArtists?.first?.Id ?? cur.ArtistItems?.first?.Id {
                Button {
                    nav.openArtist(BaseItem.stub(id: artistId,
                                                 name: cur.primaryArtistName,
                                                 type: "MusicArtist"))
                } label: { Label("Go to Artist", systemImage: "music.mic") }
            }
            Divider()
            Button {
                toggleFavorite()
            } label: {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: isFavorite ? "heart.slash" : "heart")
            }
            if !isDownloaded && !isDownloading,
               let url = auth.serverURL {
                let client = JellyfinClient(baseURL: url, auth: auth)
                Button {
                    downloads.download(cur, using: client)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
            if pro.isPro {
                Divider()
                Button(role: .destructive) {
                    skipAndIgnore()
                } label: {
                    Label("Skip & Ignore Track", systemImage: "hand.raised.slash.fill")
                }
            }
            Divider()
            Button {
                showQueue = true
            } label: { Label("Show Queue", systemImage: "list.bullet") }
        }
    }

    private func skipAndIgnore() {
        guard let cur = player.current else { return }
        ignored.ignore(cur)
        player.next()
    }

    private func iconButton(_ icon: String,
                            active: Bool = false,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func toggleFavorite() {
        guard let cur = player.current, let url = auth.serverURL else { return }
        let target = !isFavorite
        favOverride = target
        let client = JellyfinClient(baseURL: url, auth: auth)
        Task {
            do { try await client.setFavorite(cur.Id, favorite: target) }
            catch { await MainActor.run { favOverride = !target } }
        }
    }

    private var repeatIcon: String {
        player.repeatMode == .one ? "repeat.1" : "repeat"
    }

    /// Scrubber mirrors the iOS / immersive-player pattern:
    ///   - isScrubbing freezes the displayed value at `scrub`
    ///   - ignoreSlideSetUntil drops stray set() calls that arrive after
    ///     we already committed the seek (avoids the slider snapping back)
    ///   - 150ms delay before clearing isScrubbing lets the player's first
    ///     post-seek time update arrive so the bar doesn't jump
    @ViewBuilder
    private var scrubber: some View {
        let safeDur = (player.duration.isFinite && player.duration > 0) ? player.duration : 1
        let safeCur = player.currentTime.isFinite ? player.currentTime : 0
        HStack(spacing: 6) {
            Text((isScrubbing ? scrub : safeCur).mmSS)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
            Slider(value: Binding(
                get: {
                    let raw = isScrubbing ? scrub : safeCur
                    return min(max(0, raw), safeDur)
                },
                set: { newValue in
                    if Date() < ignoreSlideSetUntil { return }
                    scrub = min(max(0, newValue), safeDur)
                    isScrubbing = true
                }
            ), in: 0...safeDur, onEditingChanged: { editing in
                if !editing {
                    player.seek(to: scrub)
                    ignoreSlideSetUntil = Date().addingTimeInterval(0.4)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isScrubbing = false
                    }
                }
            })
            .controlSize(.small)
            .disabled(player.current == nil)
            Text(safeDur.mmSS)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var artworkThumb: some View {
        if let artwork {
            Image(nsImage: artwork).resizable().scaledToFill()
        } else {
            Rectangle().fill(Color.gray.opacity(0.2))
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }

    private func loadArtwork() async {
        artwork = nil
        guard let current = player.current,
              let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        // Prefer the downloaded local cover so Now Playing art shows offline.
        let img = await ImageCache.shared.loadArtwork(itemId: current.artworkItemId,
                                                      tag: current.artworkTag,
                                                      client: client,
                                                      maxWidth: 120,
                                                      headers: ["Authorization": auth.authHeader()])
        await MainActor.run { self.artwork = img }
    }
}

private extension Double {
    var mmSS: String {
        guard !isNaN, isFinite else { return "0:00" }
        let total = max(0, Int(self))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
