import SwiftUI
import BoleraCore

struct NowPlayingContent: View {
    var collapse: () -> Void = {}
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var sleepTimer: SleepTimer
    @State private var scrub: Double = 0
    @State private var isScrubbing = false
    @State private var ignoreSlideSetUntil: Date = .distantPast
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var showVisualizer = false
    @State private var showSleepSheet = false
    @State private var showActions = false
    @State private var showShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var addToPlaylistTarget: BaseItem?
    @State private var saveQueueAsPlaylistShown = false
    @State private var visualizerOn = false
    @State private var navPath: [BaseItem] = []
    @State private var similarTracks: [BaseItem] = []
    @State private var showSimilarSheet = false

    /// Live drag offset for finger-following dismissal. Resets after gesture ends.
    @GestureState private var dragOffset: CGFloat = 0

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                handle
                Spacer(minLength: 8)
                artwork
                Spacer(minLength: 12)
                trackInfo
                Spacer(minLength: 12)
                actionRow
                Spacer(minLength: 4)
                scrubber
                controls
                Spacer(minLength: 14)
                bottomBar
                Spacer().frame(height: 24)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backdrop)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: BaseItem.self) { item in
                if item.type == "MusicArtist" {
                    ArtistDetailView(artist: item)
                } else {
                    AlbumDetailView(album: item)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .modifier(IgnoreOriginalGesture())
        .offset(y: max(0, dragOffset))
        .gesture(
            DragGesture(minimumDistance: 18, coordinateSpace: .local)
                .updating($dragOffset) { value, state, _ in
                    // Respond to drags starting in the upper portion of the
                    // screen — handle + full album artwork. Below that the
                    // Slider and transport controls own the gesture.
                    guard value.startLocation.y < 420 else { return }
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    state = max(0, value.translation.height)
                }
                .onEnded { value in
                    guard value.startLocation.y < 420 else { return }
                    if value.translation.height > 100 || value.predictedEndTranslation.height > 200 {
                        collapse()
                    }
                }
        )
        .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: dragOffset)
        .onChange(of: player.current?.Id) { _, _ in
            // Reset scrubber state when track changes so a stale `scrub`
            // value doesn't leak the previous track's scrub position into
            // the new track's progress display.
            isScrubbing = false
            scrub = 0
        }
        .sheet(isPresented: $showQueue) {
            QueueView().presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showLyrics) {
            LyricsView(isPresented: $showLyrics)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet().presentationDetents([.medium])
        }
        .sheet(isPresented: $showActions) {
            NowPlayingActionsSheet(
                openLyrics:   { showActions = false; showLyrics = true },
                openVisualizer: { showActions = false; withAnimation { visualizerOn = true } },
                openSleep:    { showActions = false; showSleepSheet = true },
                openQueue:    { showActions = false; showQueue = true },
                addToPlaylist:{ showActions = false; if let c = player.current { addToPlaylistTarget = c } },
                saveQueue:    { showActions = false; saveQueueAsPlaylistShown = true },
                clearQueue:   { showActions = false; player.stop() },
                share:        { showActions = false; presentShare() },
                downloadAction: { showActions = false; downloadCurrent() },
                goToAlbum:    { showActions = false; Task { await goToCurrentAlbum() } },
                goToArtist:   { showActions = false; Task { await goToCurrentArtist() } },
                showSimilar:  { showActions = false; Task { await fetchSimilar() } }
            )
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showSimilarSheet) {
            SimilarTracksSheet(items: similarTracks).presentationDetents([.medium, .large])
        }
        .sheet(item: $addToPlaylistTarget) { item in
            AddToPlaylistSheet(item: item).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $saveQueueAsPlaylistShown) {
            SavePlayQueueSheet().presentationDetents([.medium])
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: shareItems)
        }
    }

    /// Async fetch of the current track's album item, then push onto the
    /// Now Playing NavigationStack. Lives here (not in the actions sheet)
    /// because the sheet's own NavigationStack is torn down when it
    /// dismisses, so any nav state inside it never gets a chance to
    /// resolve.
    private func goToCurrentAlbum() async {
        guard let cur = player.current, let url = auth.serverURL else { return }
        let albumId = cur.AlbumId ?? cur.Id
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let album = try? await client.item(albumId) {
            await MainActor.run { navPath.append(album) }
        }
    }

    private func goToCurrentArtist() async {
        guard let cur = player.current, let url = auth.serverURL else { return }
        let artistId = cur.AlbumArtists?.first?.Id ?? cur.ArtistItems?.first?.Id
        guard let id = artistId else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let artist = try? await client.item(id) {
            await MainActor.run { navPath.append(artist) }
        }
    }

    private func fetchSimilar() async {
        guard let cur = player.current, let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let mix = try? await client.instantMix(itemId: cur.Id) {
            await MainActor.run {
                similarTracks = mix
                showSimilarSheet = true
            }
        }
    }

    private func presentShare() {
        guard let item = player.current else { return }
        let title = "\(item.Name) — \(item.primaryArtistName)"
        shareItems = [title]
        showShareSheet = true
    }

    private var backdrop: some View {
        ZStack {
            if let art = player.artwork {
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80)
                    .opacity(0.7)
                    .ignoresSafeArea()
            } else {
                LinearGradient(colors: [.black, Color(red: 0.1, green: 0, blue: 0.15)],
                               startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            }
            Color.black.opacity(0.45).ignoresSafeArea()
        }
    }

    private var handle: some View {
        HStack(spacing: 8) {
            Button { collapse() } label: {
                Image(systemName: "chevron.down").font(.title3).padding(10).background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            Text("Now Playing").font(.subheadline.weight(.semibold))
            Spacer()
            Button { showActions = true } label: {
                Image(systemName: "ellipsis").font(.title3).padding(10).background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.top, 12)
    }

    private var artwork: some View {
        Group {
            if visualizerOn {
                InlineVisualizerView()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
            } else if let art = player.artwork {
                Image(uiImage: art).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
            } else {
                RoundedRectangle(cornerRadius: 14).fill(.ultraThinMaterial)
                    .overlay(Image(systemName: "music.note").font(.system(size: 60)).foregroundStyle(.secondary))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 300, maxHeight: 300)
        .scaleEffect(player.isPlaying ? 1.0 : 0.92)
        .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) { visualizerOn.toggle() }
        }
    }

    private var trackInfo: some View {
        VStack(spacing: 4) {
            Text(player.current?.Name ?? "")
                .font(.title3.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if let album = player.current?.Album, !album.isEmpty {
                Button { goToAlbum() } label: {
                    Text(album)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(player.current?.AlbumId == nil)
            }
            Button { goToArtist() } label: {
                Text(player.current?.primaryArtistName ?? "")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .disabled(artistId == nil)
        }
    }

    private var artistId: String? {
        player.current?.AlbumArtists?.first?.Id
            ?? player.current?.ArtistItems?.first?.Id
    }

    private func goToArtist() {
        guard let id = artistId else { return }
        let name = player.current?.primaryArtistName ?? ""
        navPath.append(BaseItem.stub(id: id, name: name, type: "MusicArtist"))
    }

    private func goToAlbum() {
        guard let cur = player.current, let id = cur.AlbumId else { return }
        let name = cur.Album ?? ""
        navPath.append(BaseItem.stub(id: id, name: name, type: "MusicAlbum"))
    }

    private var actionRow: some View {
        HStack(spacing: 18) {
            actionButton("text.quote", "Lyrics") { showLyrics = true }
            actionButton(sleepIcon, sleepLabel, highlighted: sleepTimer.mode != .off) { showSleepSheet = true }
            actionButton(downloadIcon, downloadLabel, highlighted: isDownloaded) { downloadCurrent() }
        }
        .padding(.vertical, 4)
    }

    private var isDownloaded: Bool {
        guard let id = player.current?.Id else { return false }
        return downloads.isDownloaded(id)
    }

    private var downloadIcon: String {
        guard let id = player.current?.Id else { return "arrow.down.circle" }
        if downloads.isDownloaded(id) { return "checkmark.circle.fill" }
        if downloads.inProgress[id] != nil { return "arrow.down.circle.dotted" }
        return "arrow.down.circle"
    }

    private var downloadLabel: String {
        guard let id = player.current?.Id else { return "Download" }
        if downloads.isDownloaded(id) { return "Offline" }
        if downloads.inProgress[id] != nil { return "Downloading" }
        return "Download"
    }

    private var sleepIcon: String { sleepTimer.mode == .off ? "moon.zzz" : "moon.zzz.fill" }
    private var sleepLabel: String {
        switch sleepTimer.mode {
        case .off: return "Sleep"
        case .duration: return formatRemaining(sleepTimer.remaining)
        case .endOfTrack: return "End"
        }
    }

    private func formatRemaining(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func downloadCurrent() {
        guard let item = player.current, let url = auth.serverURL else { return }
        if downloads.isDownloaded(item.Id) {
            downloads.delete(item.Id)
        } else {
            downloads.download(item, using: JellyfinClient(baseURL: url, auth: auth), individual: true)
        }
    }

    private func actionButton(_ icon: String, _ title: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: Circle())
                Text(title).font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private var scrubber: some View {
        let safeDur = (player.duration.isFinite && player.duration > 0) ? player.duration : 1
        let safeCur = player.currentTime.isFinite ? player.currentTime : 0
        return VStack(spacing: 4) {
            Slider(value: Binding(
                get: {
                    let raw = isScrubbing ? scrub : safeCur
                    return min(max(0, raw), safeDur)
                },
                set: { newValue in
                    // SwiftUI Slider occasionally fires `set` AFTER
                    // onEditingChanged(false), flipping isScrubbing back on.
                    // Ignore sets briefly after release.
                    if Date() < ignoreSlideSetUntil { return }
                    scrub = min(max(0, newValue), safeDur)
                    isScrubbing = true
                }
            ), in: 0...safeDur, onEditingChanged: { editing in
                if !editing {
                    player.seek(to: scrub)
                    ignoreSlideSetUntil = Date().addingTimeInterval(0.4)
                    // Delay flipping isScrubbing so the slider keeps showing
                    // `scrub` until SwiftUI has redrawn with the new
                    // (optimistically updated) currentTime. Prevents a
                    // one-frame flick to the old position.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        isScrubbing = false
                    }
                }
            })
            HStack {
                Text((isScrubbing ? scrub : player.currentTime).mmSS)
                Spacer()
                Text(player.duration.mmSS)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 30) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.accentColor : .primary)
            }
            Button { player.previous() } label: { Image(systemName: "backward.fill").font(.title) }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 68))
            }
            Button { player.next() } label: { Image(systemName: "forward.fill").font(.title) }
            Button { player.cycleRepeatMode() } label: {
                Image(systemName: repeatIcon).foregroundStyle(player.repeatMode == .off ? .primary : Color.accentColor)
            }
        }
        .buttonStyle(.plain)
        .font(.title3)
    }

    private var repeatIcon: String {
        switch player.repeatMode {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    private var bottomBar: some View {
        HStack {
            AirPlayButton()
                .frame(width: 28, height: 28)
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
            }
        }
        .font(.title3)
        .padding(.horizontal, 4)
    }
}

private struct IgnoreOriginalGesture: ViewModifier {
    func body(content: Content) -> some View { content }
}

// MARK: - AirPlay route picker bridge

import AVKit

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .label
        v.activeTintColor = UIColor(Color.accentColor)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct SleepTimerSheet: View {
    @EnvironmentObject var sleepTimer: SleepTimer
    @Environment(\.dismiss) var dismiss

    private let options: [(String, TimeInterval)] = [
        ("5 minutes", 5 * 60),
        ("10 minutes", 10 * 60),
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("45 minutes", 45 * 60),
        ("1 hour", 60 * 60),
        ("90 minutes", 90 * 60)
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(options, id: \.0) { (label, duration) in
                        Button {
                            sleepTimer.start(duration: duration)
                            dismiss()
                        } label: { Text(label) }
                    }
                    Button("At end of track") {
                        sleepTimer.endOfTrack()
                        dismiss()
                    }
                }
                if sleepTimer.mode != .off {
                    Section {
                        Button("Cancel timer", role: .destructive) {
                            sleepTimer.cancel()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Now Playing actions sheet

struct NowPlayingActionsSheet: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore
    @Environment(\.dismiss) var dismiss

    var openLyrics: () -> Void
    var openVisualizer: () -> Void
    var openSleep: () -> Void
    var openQueue: () -> Void
    var addToPlaylist: () -> Void
    var saveQueue: () -> Void
    var clearQueue: () -> Void
    var share: () -> Void
    var downloadAction: () -> Void
    var goToAlbum: () -> Void
    var goToArtist: () -> Void
    var showSimilar: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let cur = player.current {
                    Section { headerRow(cur) }
                }
                Section {
                    row("text.badge.plus", "Add to Playlist…", action: addToPlaylist)
                    row("text.quote", "Show Lyrics", action: openLyrics)
                    row("opticaldisc", "Go to Album", subtitle: player.current?.Album, action: goToAlbum)
                    row("person.crop.circle", "Go to Artist", subtitle: player.current?.primaryArtistName, action: goToArtist)
                    row("music.note.list", "Show Similar Tracks", action: showSimilar)
                    row("moon.zzz", "Sleep Timer", action: openSleep)
                    row("square.and.arrow.up", "Share…", action: share)
                    row("waveform.path.ecg", "Visualizer", action: openVisualizer)
                    row(isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle",
                        isDownloaded ? "Downloaded" : "Download", action: downloadAction)
                    favoriteRow
                }
                if pro.isPro {
                    Section("Pro") {
                        Button(role: .destructive) {
                            skipAndIgnore()
                        } label: {
                            Label("Skip & Ignore Track", systemImage: "hand.raised.slash.fill")
                        }
                    }
                }
                Section {
                    row("list.bullet", "Show Queue", action: openQueue)
                    row("square.and.arrow.down", "Save Play Queue as Playlist…", action: saveQueue)
                    Button(role: .destructive) { clearQueue() } label: {
                        Label("Clear Play Queue", systemImage: "xmark.circle")
                    }
                }
            }
            .navigationTitle("Actions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }

    private func skipAndIgnore() {
        guard let cur = player.current else { return }
        ignored.ignore(cur)
        player.next()
        dismiss()
    }

    @ViewBuilder
    private func headerRow(_ item: BaseItem) -> some View {
        HStack(spacing: 10) {
            JellyfinImage(itemId: item.artworkItemId, tag: item.artworkTag, maxWidth: 120, cornerRadius: 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.Name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(item.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func row(_ icon: String, _ title: String, subtitle: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon).frame(width: 24)
                VStack(alignment: .leading) {
                    Text(title).foregroundStyle(.primary)
                    if let s = subtitle, !s.isEmpty {
                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
            }
        }
    }

    private var favoriteRow: some View {
        let isFav = player.current?.UserData?.IsFavorite ?? false
        return Button {
            guard let cur = player.current, let url = auth.serverURL else { return }
            let client = JellyfinClient(baseURL: url, auth: auth)
            Task {
                try? await client.setFavorite(cur.Id, favorite: !isFav)
            }
            dismiss()
        } label: {
            Label(isFav ? "Remove from Favorites" : "Add to Favorites",
                  systemImage: isFav ? "heart.fill" : "heart")
        }
    }

    private var isDownloaded: Bool {
        guard let id = player.current?.Id else { return false }
        return downloads.isDownloaded(id)
    }

}

// MARK: - Add to playlist sheet

struct AddToPlaylistSheet: View {
    let item: BaseItem
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var playlists: [BaseItem] = []
    @State private var newName: String = ""
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                Section("New Playlist") {
                    HStack {
                        TextField("Playlist name", text: $newName)
                        Button("Create") { createNew() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Add to Existing") {
                    ForEach(playlists) { pl in
                        Button { add(to: pl.Id) } label: {
                            HStack {
                                Image(systemName: "music.note.list")
                                Text(pl.Name)
                            }
                        }
                    }
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .task { await load() }
        }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        playlists = (try? await client.playlists()) ?? []
    }

    private func createNew() {
        guard let url = auth.serverURL else { return }
        loading = true
        Task {
            let client = JellyfinClient(baseURL: url, auth: auth)
            _ = try? await client.createPlaylist(name: newName, itemIds: [item.Id])
            await MainActor.run { loading = false; dismiss() }
        }
    }

    private func add(to playlistId: String) {
        guard let url = auth.serverURL else { return }
        loading = true
        Task {
            let client = JellyfinClient(baseURL: url, auth: auth)
            try? await client.addToPlaylist(playlistId: playlistId, itemIds: [item.Id])
            await MainActor.run { loading = false; dismiss() }
        }
    }
}

// MARK: - Save play queue as playlist sheet

struct SavePlayQueueSheet: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) var dismiss
    @State private var name: String = ""
    @State private var loading = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Playlist name") {
                    TextField("Name", text: $name)
                }
                Section {
                    LabeledContent("Tracks", value: "\(player.queue.count)")
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Save Queue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func save() {
        guard let url = auth.serverURL else { return }
        loading = true
        let ids = player.queue.map { $0.Id }
        Task {
            let client = JellyfinClient(baseURL: url, auth: auth)
            _ = try? await client.createPlaylist(name: name, itemIds: ids)
            await MainActor.run { loading = false; dismiss() }
        }
    }
}

// MARK: - Similar tracks results sheet

struct SimilarTracksSheet: View {
    let items: [BaseItem]
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    AudioPlayer.shared.play(items: items)
                    dismiss()
                } label: { Label("Play All", systemImage: "play.fill") }
                ForEach(items) { item in
                    Button {
                        AudioPlayer.shared.play(items: items, startAt: items.firstIndex(where: { $0.Id == item.Id }) ?? 0)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            JellyfinImage(itemId: item.artworkItemId, tag: item.artworkTag, maxWidth: 120, cornerRadius: 4)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading) {
                                Text(item.Name).foregroundStyle(.primary).lineLimit(1)
                                Text(item.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Similar Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
        }
    }
}

// MARK: - UIActivityViewController bridge

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

// MARK: - Visualizer styles

enum VisualizerStyle: String, CaseIterable, Identifiable {
    case bars, wave, radial, pulse, mirror
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bars:   return "Bars"
        case .wave:   return "Waveform"
        case .radial: return "Radial"
        case .pulse:  return "Pulse"
        case .mirror: return "Mirror"
        }
    }
    var icon: String {
        switch self {
        case .bars:   return "chart.bar.fill"
        case .wave:   return "waveform"
        case .radial: return "rays"
        case .pulse:  return "circle.circle"
        case .mirror: return "rectangle.split.1x2"
        }
    }
}

// MARK: - Inline visualizer (renders where album art would be)

/// Display-synced visualizer. TimelineView drives Canvas redraws every frame.
/// Smoothes incoming audio levels with a low-pass filter so the published
/// 25–60 Hz updates render as continuous motion at the display refresh rate.
/// Long-press to pick a different visualizer style.
struct InlineVisualizerView: View {
    @EnvironmentObject var player: AudioPlayer
    @AppStorage("bolera.visualizer.style") private var styleRaw: String = VisualizerStyle.bars.rawValue

    private var style: VisualizerStyle { VisualizerStyle(rawValue: styleRaw) ?? .bars }

    private final class State {
        var smoothed: [Float] = Array(repeating: 0, count: 16)
        var lastT: TimeInterval = 0
    }
    private let state = State()

    var body: some View {
        TimelineView(.animation) { ctx in
            Canvas { gfx, size in
                let now = ctx.date.timeIntervalSinceReferenceDate
                let dt = max(0.001, min(0.1, now - state.lastT))
                state.lastT = now

                let target: [Float] = {
                    if let real = player.activeAudioProcessor?.levels,
                       real.contains(where: { $0 > 0.01 }) {
                        return Self.expand(real, to: state.smoothed.count)
                    }
                    if player.isPlaying {
                        return (0..<state.smoothed.count).map { i in
                            let phase = Double(i) * 0.55 + now * 2.0
                            return Float(max(0.05, 0.35 + 0.25 * sin(phase) + 0.2 * sin(phase * 1.7)))
                        }
                    }
                    return Array(repeating: 0, count: state.smoothed.count)
                }()

                let n = min(state.smoothed.count, target.count)
                for i in 0..<n {
                    let s = state.smoothed[i]
                    let t = target[i]
                    let alpha: Float = (t > s) ? Float(min(1.0, dt * 18.0))
                                                : Float(min(1.0, dt * 6.0))
                    state.smoothed[i] = s + (t - s) * alpha
                }

                switch style {
                case .bars:
                    Visualizers.drawBars(gfx: gfx, size: size, levels: state.smoothed)
                    Visualizers.drawWave(gfx: gfx, size: size, levels: state.smoothed, t: now)
                case .wave:
                    Visualizers.drawBigWave(gfx: gfx, size: size, levels: state.smoothed, t: now)
                case .radial:
                    Visualizers.drawRadial(gfx: gfx, size: size, levels: state.smoothed, t: now)
                case .pulse:
                    Visualizers.drawPulse(gfx: gfx, size: size, levels: state.smoothed, t: now)
                case .mirror:
                    Visualizers.drawMirror(gfx: gfx, size: size, levels: state.smoothed)
                }
            }
            .background(Color.black.opacity(0.6))
        }
        .contentShape(Rectangle())
        .contextMenu {
            ForEach(VisualizerStyle.allCases) { s in
                Button {
                    styleRaw = s.rawValue
                } label: {
                    Label(s.label, systemImage: s.icon)
                    if s == style { Image(systemName: "checkmark") }
                }
            }
        }
        .onAppear {
            player.activeAudioProcessor?.startObservingLevels()
        }
        .onDisappear {
            player.activeAudioProcessor?.stopObservingLevels()
        }
    }

    /// Expand a sparse level array to a denser count using linear interp.
    static func expand(_ src: [Float], to count: Int) -> [Float] {
        guard src.count > 1, count > 0 else { return Array(repeating: 0, count: count) }
        if src.count == count { return src }
        var out: [Float] = []
        out.reserveCapacity(count)
        let scale = Double(src.count - 1) / Double(max(1, count - 1))
        for i in 0..<count {
            let pos = Double(i) * scale
            let lo = min(src.count - 1, Int(pos))
            let hi = min(src.count - 1, lo + 1)
            let f = Float(pos - Double(lo))
            out.append(src[lo] + (src[hi] - src[lo]) * f)
        }
        return out
    }
}

// MARK: - Shared visualizer draw routines

/// Stateless drawing helpers reused by the iOS visualizer styles. Each one
/// reads from a smoothed levels array and renders into a Canvas
/// GraphicsContext at the given size.
enum Visualizers {
    static func drawBars(gfx: GraphicsContext, size: CGSize, levels: [Float]) {
        let count = levels.count
        let gap: CGFloat = 6
        let totalGap = gap * CGFloat(count - 1)
        let barWidth = (size.width * 0.82 - totalGap) / CGFloat(count)
        let originX = (size.width - (barWidth * CGFloat(count) + totalGap)) / 2
        let maxHeight = size.height * 0.65
        let centerY = size.height / 2
        for i in 0..<count {
            let h = max(6, maxHeight * CGFloat(levels[i]))
            let x = originX + CGFloat(i) * (barWidth + gap)
            let rect = CGRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            let g = Gradient(colors: [Color.accentColor, Color.accentColor.opacity(0.4)])
            gfx.fill(path, with: .linearGradient(g,
                                                 startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                 endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
    }

    static func drawWave(gfx: GraphicsContext, size: CGSize, levels: [Float], t: TimeInterval) {
        var path = Path()
        let midY = size.height / 2
        let steps = 96
        let amp = size.height * 0.16
        for s in 0...steps {
            let x = size.width * CGFloat(s) / CGFloat(steps)
            let i = min(levels.count - 1, s * levels.count / steps)
            let level = CGFloat(levels[i])
            let phase = Double(s) * 0.25 + t * 4
            let y = midY + amp * (level * 0.6 + 0.4) * sin(phase)
            if s == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        gfx.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 2)
    }

    /// Big single waveform — fills the canvas with two interleaved sine
    /// waves whose amplitude tracks the audio envelope.
    static func drawBigWave(gfx: GraphicsContext, size: CGSize, levels: [Float], t: TimeInterval) {
        let midY = size.height / 2
        let steps = 200
        let avg = CGFloat(levels.reduce(0, +) / Float(max(1, levels.count)))
        let baseAmp = size.height * 0.32 * (0.35 + avg * 1.2)
        for layer in 0..<3 {
            var path = Path()
            let layerAmp = baseAmp * (1.0 - CGFloat(layer) * 0.28)
            let speed = 3.0 - Double(layer) * 0.8
            let freq = 0.15 + Double(layer) * 0.08
            for s in 0...steps {
                let x = size.width * CGFloat(s) / CGFloat(steps)
                let phase = Double(s) * freq + t * speed
                let y = midY + layerAmp * sin(phase) * sin(phase * 0.37 + t)
                if s == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            let alpha = 0.85 - Double(layer) * 0.25
            gfx.stroke(path,
                       with: .color(Color.accentColor.opacity(alpha)),
                       style: StrokeStyle(lineWidth: 3 - CGFloat(layer) * 0.6, lineCap: .round))
        }
    }

    /// Radial bars — band levels distributed around a circle, growing
    /// outward from a base ring. Slowly rotates for ambient motion.
    static func drawRadial(gfx: GraphicsContext, size: CGSize, levels: [Float], t: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let baseR = min(size.width, size.height) * 0.18
        let maxLen = min(size.width, size.height) * 0.32
        let count = levels.count * 2  // mirror around circle
        let rot = t * 0.25
        for i in 0..<count {
            let level = CGFloat(levels[i % levels.count])
            let angle = (Double(i) / Double(count)) * .pi * 2 + rot
            let len = max(6, maxLen * level)
            let p0 = CGPoint(x: center.x + baseR * cos(angle),
                             y: center.y + baseR * sin(angle))
            let p1 = CGPoint(x: center.x + (baseR + len) * cos(angle),
                             y: center.y + (baseR + len) * sin(angle))
            var path = Path()
            path.move(to: p0)
            path.addLine(to: p1)
            let alpha = 0.55 + Double(level) * 0.45
            gfx.stroke(path,
                       with: .color(Color.accentColor.opacity(alpha)),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        // Inner halo ring
        let ring = Path(ellipseIn: CGRect(x: center.x - baseR, y: center.y - baseR,
                                          width: baseR * 2, height: baseR * 2))
        gfx.stroke(ring, with: .color(Color.white.opacity(0.18)), lineWidth: 1.2)
    }

    /// Concentric pulses driven by overall amplitude. A soft halo glows in
    /// the middle on every beat.
    static func drawPulse(gfx: GraphicsContext, size: CGSize, levels: [Float], t: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) * 0.46
        let amp = CGFloat(levels.reduce(0, +) / Float(max(1, levels.count)))
        let rings = 5
        for i in 0..<rings {
            let phase = (CGFloat(i) / CGFloat(rings)) + CGFloat(t.truncatingRemainder(dividingBy: 1.0))
            let r = maxR * phase.truncatingRemainder(dividingBy: 1.0) * (0.6 + amp * 0.6)
            let alpha = 0.45 * (1.0 - Double(phase.truncatingRemainder(dividingBy: 1.0)))
            let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            gfx.stroke(Path(ellipseIn: rect),
                       with: .color(Color.accentColor.opacity(alpha)),
                       lineWidth: 2)
        }
        // Center disc — scales with amplitude
        let coreR = max(12, 18 + amp * 60)
        let coreRect = CGRect(x: center.x - coreR, y: center.y - coreR,
                              width: coreR * 2, height: coreR * 2)
        let g = Gradient(colors: [Color.accentColor, Color.accentColor.opacity(0)])
        gfx.fill(Path(ellipseIn: coreRect),
                 with: .radialGradient(g,
                                       center: center,
                                       startRadius: 0,
                                       endRadius: coreR))
    }

    /// Mirror bars — vertical bars on each side of the centre, growing
    /// from the centre outward and reflected.
    static func drawMirror(gfx: GraphicsContext, size: CGSize, levels: [Float]) {
        let count = levels.count
        let gap: CGFloat = 4
        let availableW = size.width * 0.86
        let barWidth = (availableW - gap * CGFloat(count - 1)) / CGFloat(count)
        let originX = (size.width - availableW) / 2
        let centerY = size.height / 2
        let maxHeight = size.height * 0.4
        for i in 0..<count {
            let h = max(4, maxHeight * CGFloat(levels[i]))
            let x = originX + CGFloat(i) * (barWidth + gap)
            // Top bar
            let top = CGRect(x: x, y: centerY - h, width: barWidth, height: h)
            let bot = CGRect(x: x, y: centerY,     width: barWidth, height: h)
            let g = Gradient(colors: [Color.accentColor, Color.accentColor.opacity(0.2)])
            gfx.fill(Path(roundedRect: top, cornerRadius: barWidth / 2),
                     with: .linearGradient(g,
                                           startPoint: CGPoint(x: top.midX, y: top.minY),
                                           endPoint: CGPoint(x: top.midX, y: top.maxY)))
            gfx.fill(Path(roundedRect: bot, cornerRadius: barWidth / 2),
                     with: .linearGradient(g,
                                           startPoint: CGPoint(x: bot.midX, y: bot.maxY),
                                           endPoint: CGPoint(x: bot.midX, y: bot.minY)))
        }
        // Subtle centre line
        var line = Path()
        line.move(to: CGPoint(x: originX, y: centerY))
        line.addLine(to: CGPoint(x: originX + availableW, y: centerY))
        gfx.stroke(line, with: .color(Color.white.opacity(0.15)), lineWidth: 0.5)
    }
}
