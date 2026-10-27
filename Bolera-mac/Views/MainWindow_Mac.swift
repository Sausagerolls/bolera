import SwiftUI
import AppKit
import BoleraCore

/// A home-screen rail whose header drills into a full-list page.
/// (Favourites have their own dedicated sidebar page, so they're not here.)
enum MacHomeSection: String, Hashable {
    case recentTracks, recentAlbums, topTracks, recentlyAdded

    var title: String {
        switch self {
        case .recentTracks:  return "Recent Tracks"
        case .recentAlbums:  return "Recent Albums"
        case .topTracks:     return "Top Played Tracks"
        case .recentlyAdded: return "Recently Added"
        }
    }
    var isTrackList: Bool { self == .recentTracks || self == .topTracks }
}

/// A genre or server tag drilled into from the Genres / Tags pages.
/// `matches` = the RAW server genre names behind one displayed genre — file
/// tags often hold "Rock; Pop" in one field and Jellyfin keeps that as a
/// single genre entity; the UI splits them for display.
struct MacLibraryFilter: Hashable {
    enum Kind: String { case genre = "Genre", tag = "Tag" }
    let kind: Kind
    let name: String
    var matches: [String] = []
    var queryNames: [String] { matches.isEmpty ? [name] : matches }
}

enum SidebarSelection: Hashable {
    case home
    case artists
    case albums
    case genres
    case tags
    case playlists
    case downloads
    case favorites
    case search
    case homeSection(MacHomeSection)  // full-list page for a home rail
    case library(String)  // Jellyfin library Id
    case albumDetail(BaseItem)
    case artistDetail(BaseItem)
    case playlistDetail(BaseItem)
    case libraryFilter(MacLibraryFilter)  // genre/tag detail
}

struct MainWindow_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var pro: ProEntitlementStore
    @EnvironmentObject var nav: MacNavCoordinator
    @Environment(\.openWindow) private var openWindow

    @State private var search: String = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var swipeMonitor: Any?
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
            if nav.microPlayer {
                MicroPlayer_Mac()
                    .transition(.opacity)
                    .toolbar(.hidden, for: .windowToolbar)
                    .toolbarBackground(.hidden, for: .windowToolbar)
                    .ignoresSafeArea()
            } else if nav.showImmersive {
                ImmersivePlayer_Mac {
                    withAnimation(.easeInOut(duration: 0.25)) { nav.showImmersive = false }
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
                            withAnimation(.easeInOut(duration: 0.25)) { nav.showImmersive = true }
                        }
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .transition(.opacity)
                .toolbar {
                    ToolbarItemGroup(placement: .navigation) {
                        Button { nav.goBack() } label: {
                            Image(systemName: "chevron.left")
                        }
                        .help("Back (⌘[ or swipe right with two fingers)")
                        .keyboardShortcut("[", modifiers: .command)
                        .disabled(!nav.canGoBack)

                        Button { nav.goForward() } label: {
                            Image(systemName: "chevron.right")
                        }
                        .help("Forward (⌘] or swipe left with two fingers)")
                        .keyboardShortcut("]", modifiers: .command)
                        .disabled(!nav.canGoForward)
                    }
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
            if !connectivity.isOnline && !nav.showImmersive {
                OfflineBanner_Mac()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: connectivity.isOnline)
        .background(MicroWindowController(active: nav.microPlayer))
        .onAppear(perform: installSwipeMonitor)
        .onDisappear {
            if let m = swipeMonitor { NSEvent.removeMonitor(m); swipeMonitor = nil }
        }
    }

    /// Two/three-finger horizontal trackpad swipes drive Back/Forward, matching
    /// macOS "swipe between pages". A local monitor catches the swipe regardless
    /// of which subview is focused (no responder-chain juggling). deltaX > 0 is a
    /// swipe to the RIGHT → Back; deltaX < 0 a swipe LEFT → Forward.
    private func installSwipeMonitor() {
        guard swipeMonitor == nil else { return }
        swipeMonitor = NSEvent.addLocalMonitorForEvents(matching: .swipe) { event in
            if event.deltaX > 0 {
                nav.goBack()
            } else if event.deltaX < 0 {
                nav.goForward()
            }
            return event
        }
    }
}

struct OfflineBanner_Mac: View {
    var body: some View {
        Button { ConnectivityStore.shared.forceReconnect() } label: {
            HStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                Text("Offline — click to reconnect").lineLimit(1)
                Spacer()
                Image(systemName: "arrow.clockwise")
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(Color.orange.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    // Observe the @Published position mirror — `player.currentTime` isn't
    // @Published, so the scrubber froze until another @Published changed.
    @ObservedObject private var clock = AudioPlayer.shared.clock
    let onExpand: () -> Void
    @ObservedObject private var favSync = FavoritesSync.shared
    @State private var showQueue = false
    @State private var isScrubbing = false
    @State private var scrub: Double = 0
    @State private var ignoreSlideSetUntil: Date = .distantPast
    @Environment(\.openWindow) private var openWindow
    @AppStorage(MacA11y.scaleKey) private var scale = 1.0
    @AppStorage(MacA11y.labelsKey) private var showLabels = false

    private var isFavorite: Bool {
        guard let cur = player.current else { return false }
        return favSync.isFavorite(cur)
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
                // Top row: meta on the left, transport in the middle,
                // secondary controls on the right. The two sides take equal
                // flexible widths so the transport stays centred however big
                // the accessibility settings make the controls.
                HStack(spacing: 12) {
                    Button(action: onExpand) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.current?.Name ?? "Nothing Playing")
                                .font(.system(size: 11 * scale)).lineLimit(1)
                            Text(player.current?.primaryArtistName ?? "—")
                                .font(.system(size: 10 * scale)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(player.current == nil)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 16 * scale) {
                        transportButton("shuffle", label: "Shuffle", active: player.shuffle) { player.toggleShuffle() }
                        PlayerControlButton_Mac(icon: "backward.fill", label: "Previous") { player.previous() }
                        PlayerControlButton_Mac(icon: player.isPlaying ? "pause.circle.fill" : "play.circle.fill",
                                                label: player.isPlaying ? "Pause" : "Play",
                                                size: 28, tint: .primary) { player.togglePlayPause() }
                        PlayerControlButton_Mac(icon: "forward.fill", label: "Next") { player.next() }
                        transportButton(repeatIcon, label: "Repeat", active: player.repeatMode != .off) {
                            player.cycleRepeatMode()
                        }
                    }
                    .fixedSize()

                    HStack(spacing: 14 * scale) {
                        VolumeControl_Mac(sliderWidth: 80)
                        iconButton(isFavorite ? "heart.fill" : "heart",
                                   label: "Favourite",
                                   active: isFavorite,
                                   help: isFavorite ? "Remove from Favorites" : "Add to Favorites") {
                            toggleFavorite()
                        }
                        downloadButton
                        if pro.isPro {
                            iconButton("hand.raised.slash.fill",
                                       label: "Ignore",
                                       help: "Skip & Ignore — never auto-play again") {
                                skipAndIgnore()
                            }
                        }
                        iconButton("list.bullet",
                                   label: "Queue",
                                   help: "Show Queue") {
                            showQueue = true
                        }
                        Menu {
                            playerContextMenu
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 13 * scale))
                                if showLabels {
                                    Text("More").font(.system(size: 9 * scale))
                                }
                            }
                            .foregroundStyle(Color.primary)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("More")
                        iconButton("rectangle.expand.vertical",
                                   label: "Expand",
                                   help: "Open Now Playing (⌘⇧N)") {
                            onExpand()
                        }
                        .keyboardShortcut("n", modifiers: [.command, .shift])
                        iconButton("pip.enter", label: "Mini", help: "Micro Player") {
                            nav.microPlayer = true
                        }
                    }
                    .fixedSize()
                    .disabled(player.current == nil)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                // Bottom row: full-width scrubber spans the entire bar.
                scrubber
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .task(id: player.current?.Id) {
            // Reconcile the bottom-bar heart with the server on track change.
            guard let cur = player.current, let url = auth.serverURL else { return }
            if let fresh = try? await JellyfinClient(baseURL: url, auth: auth).item(cur.Id) {
                favSync.reconcile(id: cur.Id, serverFavorite: fresh.UserData?.IsFavorite ?? false)
            }
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
                       label: "Downloaded",
                       active: true,
                       help: "Downloaded — click to remove") {
                guard let id = player.current?.Id else { return }
                downloads.delete(id)
            }
        } else {
            iconButton("arrow.down.circle",
                       label: "Download",
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
                            label: String,
                            active: Bool = false,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        PlayerControlButton_Mac(icon: icon, label: label, help: help, active: active, action: action)
    }

    private func toggleFavorite() {
        guard let cur = player.current, let url = auth.serverURL else { return }
        favSync.setFavorite(cur.Id, favorite: !isFavorite,
                            client: JellyfinClient(baseURL: url, auth: auth))
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
        let safeCur = clock.currentTime.isFinite ? clock.currentTime : 0
        HStack(spacing: 6) {
            Text(min(isScrubbing ? scrub : safeCur, safeDur).mmSS)
                .font(.system(size: 10 * scale).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34 * scale, alignment: .trailing)
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
            .controlSize(scale > 1.1 ? .regular : .small)
            .disabled(player.current == nil)
            Text(safeDur.mmSS)
                .font(.system(size: 10 * scale).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34 * scale, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(_ icon: String, label: String, active: Bool, action: @escaping () -> Void) -> some View {
        PlayerControlButton_Mac(icon: icon, label: label, active: active, action: action)
    }

}

// MARK: - Accessibility (macOS)

/// Mac accessibility settings (Settings > General > Accessibility, plus the
/// View menu's size commands).
enum MacA11y {
    /// Interface scale for the player bar and full-screen player controls.
    static let scaleKey = "bolera.mac.uiScale"
    /// Show a text label under each player control.
    static let labelsKey = "bolera.mac.controlLabels"

    static let scales: [Double] = [1.0, 1.25, 1.5]
    static func name(for scale: Double) -> String {
        switch scale {
        case ..<1.1: return "Default"
        case ..<1.4: return "Large"
        default: return "Extra Large"
        }
    }
    /// Colour vision settings live in BoleraCore (shared with iOS) and are
    /// observable, so views reading these redraw when they change.
    static var colourMode: ColourVisionMode { ColourVisionSettings.shared.mode }
    /// The app's accent under the current colour vision settings. Use instead
    /// of `Color.accentColor`, which always resolves to the asset purple.
    static var accent: Color { ColourVisionSettings.shared.accent }
    /// Readable text colour for content drawn on `accent`.
    static var onAccent: Color { ColourVisionSettings.shared.onAccent }

    /// Next scale step up (+1) or down (-1), clamped to the available sizes.
    static func step(_ current: Double, by delta: Int) -> Double {
        let i = scales.firstIndex { abs($0 - current) < 0.01 } ?? 0
        return scales[max(0, min(scales.count - 1, i + delta))]
    }
}

/// A player control: SF Symbol plus an optional label underneath, following
/// the accessibility settings (scale, colour mode, labels). Idle controls draw
/// in full colour with a generous click area. `tint` overrides the idle colour
/// (the full-screen player draws white on artwork).
struct PlayerControlButton_Mac: View {
    let icon: String
    let label: String
    var help: String? = nil
    var active: Bool = false
    var size: CGFloat = 13
    var tint: Color? = nil
    let action: () -> Void

    @AppStorage(MacA11y.scaleKey) private var scale = 1.0
    @AppStorage(MacA11y.labelsKey) private var labels = false
    private var colourVision: ColourVisionSettings { .shared }
    private var color: Color {
        if active { return colourVision.accent }
        return tint ?? .primary
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: size * scale))
                    .foregroundStyle(color)
                if labels {
                    Text(label)
                        .font(.system(size: 9 * scale))
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize()
                }
                if colourVision.showsActiveIndicator {
                    // Non-colour "on" cue; kept in layout when off so toggling
                    // doesn't shift the bar.
                    Circle()
                        .fill(color)
                        .frame(width: 4 * scale, height: 4 * scale)
                        .opacity(active ? 1 : 0)
                }
            }
            .frame(minWidth: 26 * scale, minHeight: 26 * scale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

/// Settings key: show the volume slider permanently instead of behind a
/// popover button. Off by default; an accessibility option for anyone who
/// finds the popover fiddly.
let inlineVolumeSliderKey = "bolera.mac.inlineVolumeSlider"

/// App volume control, separate from the system volume. By default a speaker
/// button that opens a small popover above it holding the slider; with
/// `inlineVolumeSliderKey` on, the button mutes and the slider sits beside it.
/// Used in the bottom player bar and the full-screen player.
struct VolumeControl_Mac: View {
    @EnvironmentObject var player: AudioPlayer
    @AppStorage(inlineVolumeSliderKey) private var inline = false
    @AppStorage(MacA11y.scaleKey) private var scale = 1.0
    @State private var showPopover = false
    var sliderWidth: CGFloat = 80
    /// Icon size before scaling.
    var size: CGFloat = 13
    /// Idle icon colour override; the full-screen player passes white.
    var tint: Color? = nil

    private var icon: String {
        if player.isMuted || player.volume == 0 { return "speaker.slash.fill" }
        if player.volume < 0.34 { return "speaker.wave.1.fill" }
        if player.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    var body: some View {
        if inline {
            HStack(spacing: 6) {
                speakerButton(action: toggleMute)
                    .help(player.isMuted ? "Unmute" : "Mute")
                slider.frame(width: sliderWidth * scale)
            }
        } else {
            speakerButton { showPopover.toggle() }
                .help("Volume")
                .popover(isPresented: $showPopover, arrowEdge: .top) {
                    HStack(spacing: 10) {
                        Button(action: toggleMute) {
                            Image(systemName: icon)
                                .frame(width: 22, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(player.isMuted ? "Unmute" : "Mute")
                        slider.frame(width: 140)
                        Text("\(Int(((player.isMuted ? 0 : player.volume) * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .padding(12)
                }
        }
    }

    private func speakerButton(action: @escaping () -> Void) -> some View {
        // Fixed-width icon so neighbours don't shift as the wave count changes.
        PlayerControlButton_Mac(icon: icon, label: "Volume", size: size, tint: tint, action: action)
            .frame(minWidth: 24 * scale)
    }

    private var slider: some View {
        Slider(value: Binding(
            get: { player.isMuted ? 0 : player.volume },
            set: { v in
                player.volume = v
                if player.isMuted && v > 0 { player.isMuted = false }
            }
        ), in: 0...1)
        .controlSize(scale > 1.1 ? .regular : .small)
        .help("Volume")
    }

    private func toggleMute() {
        // Unmuting at zero would be silent — bring it back to a usable level.
        if player.isMuted || player.volume == 0 {
            if player.volume == 0 { player.volume = 0.5 }
            player.isMuted = false
        } else {
            player.isMuted = true
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

// MARK: - Micro Player

/// Compact player: the whole window becomes the album cover with transport
/// controls that fade in on hover, blended under a transparent title bar.
/// Entered from the mini-player's Micro Player button; the title-bar shrink +
/// restore is handled by `MicroWindowController`.
struct MicroPlayer_Mac: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var nav: MacNavCoordinator
    @State private var art: PlatformImage?
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black
            if let art {
                Image(artwork: art).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [MacA11y.accent.opacity(0.5), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay(Image(systemName: "music.note")
                        .font(.system(size: 44)).foregroundStyle(.white.opacity(0.6)))
            }

            // Controls + exit, revealed on hover over a darkening scrim.
            if hovering {
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.6)],
                               startPoint: .center, endPoint: .bottom)
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { nav.microPlayer = false }
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Exit Micro Player")
                    }
                    Spacer()
                    VStack(spacing: 4) {
                        Text(player.current?.Name ?? "")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        HStack(spacing: 26) {
                            ctrl("backward.fill", 16) { player.previous() }
                            ctrl(player.isPlaying ? "pause.fill" : "play.fill", 24) { player.togglePlayPause() }
                            ctrl("forward.fill", 16) { player.next() }
                        }
                    }
                    .padding(.bottom, 14)
                }
                .padding(10)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
        .onHover { h in withAnimation(.easeInOut(duration: 0.15)) { hovering = h } }
        .task(id: player.current?.Id) { await loadArt() }
    }

    private func ctrl(_ icon: String, _ size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func loadArt() async {
        art = nil
        guard let cur = player.current, let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let img = await ImageCache.shared.loadArtwork(
            itemId: cur.artworkItemId, tag: cur.artworkTag,
            client: client, maxWidth: 640,
            headers: ["Authorization": auth.authHeader()])
        await MainActor.run { self.art = img }
    }
}

/// Shrinks the hosting window into a small, square, floating, blended panel
/// while the Micro Player is active, and restores the previous geometry/chrome
/// when it exits.
///
/// Freeze fix: the earlier version animated `setFrame` while SwiftUI's content
/// `minWidth` was still 960 — AppKit clamped each animation frame back up to the
/// content minimum, fighting the shrink and beach-balling until layout happened
/// to settle. Now we (1) lower the window's own `minSize`/`maxSize` FIRST so the
/// new frame is legal immediately, (2) set the frame WITHOUT animation, and
/// (3) collapse/restore exactly once via a saved-state guard.
private struct MicroWindowController: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let active = self.active
        DispatchQueue.main.async {
            guard let win = nsView.window else { return }
            let c = context.coordinator
            if active {
                guard c.saved == nil else { return }   // already collapsed
                c.saved = Saved(frame: win.frame,
                                minSize: win.minSize,
                                maxSize: win.maxSize,
                                titleVisibility: win.titleVisibility,
                                titlebarTransparent: win.titlebarAppearsTransparent,
                                movableByBackground: win.isMovableByWindowBackground,
                                level: win.level)
                let side: CGFloat = 260
                // Relax size limits BEFORE resizing so the small frame is legal.
                win.minSize = NSSize(width: side, height: side)
                win.maxSize = NSSize(width: side, height: side)
                win.titleVisibility = .hidden
                win.titlebarAppearsTransparent = true
                win.isMovableByWindowBackground = true
                win.level = .floating
                var f = win.frame
                f.origin.y += f.height - side   // keep the top edge anchored
                f.size = NSSize(width: side, height: side)
                win.setFrame(f, display: true, animate: false)
            } else if let saved = c.saved {
                // Restore limits first, then geometry/chrome (no animation).
                win.maxSize = saved.maxSize
                win.minSize = saved.minSize
                win.titleVisibility = saved.titleVisibility
                win.titlebarAppearsTransparent = saved.titlebarTransparent
                win.isMovableByWindowBackground = saved.movableByBackground
                win.level = saved.level
                win.setFrame(saved.frame, display: true, animate: false)
                c.saved = nil
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    struct Saved {
        let frame: NSRect
        let minSize: NSSize
        let maxSize: NSSize
        let titleVisibility: NSWindow.TitleVisibility
        let titlebarTransparent: Bool
        let movableByBackground: Bool
        let level: NSWindow.Level
    }
    final class Coordinator { var saved: Saved? }
}
