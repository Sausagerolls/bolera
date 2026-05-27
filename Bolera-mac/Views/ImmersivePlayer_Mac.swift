import SwiftUI
import BoleraCore

/// Mac immersive Now Playing. Mirrors the iOS NowPlayingContent layout.
/// Top: handle (close + title + queue). Middle: artwork (tap → visualizer).
/// Then track info, action row, scrubber, controls, bottom bar.
struct ImmersivePlayer_Mac: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var sleepTimer: SleepTimer
    let onDismiss: () -> Void

    @State private var artwork: PlatformImage?
    @State private var scrub: Double = 0
    @State private var isScrubbing = false
    @State private var ignoreSlideSetUntil: Date = .distantPast
    @State private var visualizerOn = false
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var showSleepSheet = false
    @State private var showAlbumSheet = false
    @State private var showArtistSheet = false
    @State private var showAddToPlaylist = false
    @State private var albumForSheet: BaseItem?
    @State private var artistForSheet: BaseItem?
    /// Local override so the heart icon updates instantly. Maps trackId →
    /// current favorite state, overriding the (possibly nil) UserData on the
    /// queue item. Server is updated in background; reverts on failure.
    @State private var favoriteOverride: [String: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            handle
                .padding(.horizontal, 24)
                .padding(.top, 14)

            Spacer(minLength: 8)
            artworkView
                .padding(.horizontal, 24)
            Spacer(minLength: 12)

            trackInfo
                .padding(.horizontal, 24)

            Spacer(minLength: 16)

            scrubber
                .padding(.horizontal, 24)

            controls
                .padding(.top, 8)
                .padding(.horizontal, 24)

            Spacer(minLength: 16)

            bottomBar
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backdrop.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task(id: player.current?.Id) { await loadArtwork() }
        .onChange(of: player.current?.Id) { _, _ in
            isScrubbing = false
            scrub = 0
        }
        .sheet(isPresented: $showQueue) {
            QueueSheet_Mac().frame(minWidth: 420, minHeight: 480)
                .environmentObject(player)
                .environmentObject(auth)
        }
        .sheet(isPresented: $showLyrics) {
            LyricsSheet_Mac(isPresented: $showLyrics)
                .environmentObject(player)
                .environmentObject(auth)
                .frame(minWidth: 480, minHeight: 560)
        }
        .sheet(isPresented: $showSleepSheet) {
            SleepTimerSheet_Mac()
                .environmentObject(sleepTimer)
                .frame(minWidth: 360, minHeight: 360)
        }
        .sheet(isPresented: $showAddToPlaylist) {
            if let item = player.current {
                AddToPlaylistSheet_Mac(item: item)
                    .environmentObject(auth)
                    .frame(minWidth: 420, minHeight: 480)
            }
        }
        .sheet(item: $albumForSheet) { album in
            AlbumTracksSheet_Mac(album: album)
                .environmentObject(auth)
                .environmentObject(player)
                .frame(minWidth: 480, minHeight: 540)
        }
        .sheet(item: $artistForSheet) { artist in
            ArtistAlbumsSheet_Mac(artist: artist)
                .environmentObject(auth)
                .environmentObject(player)
                .frame(minWidth: 480, minHeight: 540)
        }
    }

    // MARK: - Backdrop

    private var backdrop: some View {
        ZStack {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 80, opaque: true)
                    .opacity(0.85)
            } else {
                LinearGradient(
                    colors: [.black, Color(red: 0.1, green: 0, blue: 0.15)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            Color.black.opacity(0.45)
        }
    }

    // MARK: - Top handle

    private var handle: some View {
        HStack(spacing: 10) {
            Button { onDismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3).padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .help("Close (esc)")
            Spacer()
            Text("Now Playing").font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            Spacer()
            moreMenu
        }
        .foregroundStyle(.white)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                openAlbum()
            } label: {
                Label("Go to Album", systemImage: "opticaldisc")
            }
            .disabled(player.current?.AlbumId == nil)
            Button {
                openArtist()
            } label: {
                Label("Go to Artist", systemImage: "person.crop.circle")
            }
            .disabled(artistId == nil)
            Divider()
            Button {
                showAddToPlaylist = true
            } label: {
                Label("Add to Playlist…", systemImage: "text.badge.plus")
            }
            .disabled(player.current == nil)
            Button {
                favoriteToggle()
            } label: {
                Label(isFavorite ? "Remove from Favorites" : "Add to Favorites",
                      systemImage: isFavorite ? "heart.fill" : "heart")
            }
            .disabled(player.current == nil)
            Button {
                toggleDownload()
            } label: {
                Label(isDownloaded ? "Remove Download" : "Download",
                      systemImage: isDownloaded ? "checkmark.circle.fill" : "arrow.down.circle")
            }
            .disabled(player.current == nil)
            Divider()
            Button {
                showQueue = true
            } label: {
                Label("Show Queue", systemImage: "list.bullet")
            }
            Divider()
            Button(role: .destructive) {
                player.stop()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.title3)
                .frame(width: 42, height: 42)
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(.white)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var artistId: String? {
        player.current?.AlbumArtists?.first?.Id
            ?? player.current?.ArtistItems?.first?.Id
    }

    private func openAlbum() {
        guard let cur = player.current, let id = cur.AlbumId else { return }
        let name = cur.Album ?? ""
        albumForSheet = BaseItem.stub(id: id, name: name, type: "MusicAlbum")
        showAlbumSheet = true
    }

    private func openArtist() {
        guard let id = artistId else { return }
        let name = player.current?.primaryArtistName ?? ""
        artistForSheet = BaseItem.stub(id: id, name: name, type: "MusicArtist")
        showArtistSheet = true
    }

    // MARK: - Artwork (tap → visualizer toggle)

    private var artworkView: some View {
        GeometryReader { geo in
            let maxSide = min(geo.size.width, geo.size.height)
            let side = min(maxSide, 460)
            ZStack {
                if visualizerOn {
                    InlineVisualizer_Mac()
                        .environmentObject(player)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
                } else if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.6), radius: 20, y: 10)
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 60))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: max(side, 120), height: max(side, 120))
            .scaleEffect(player.isPlaying ? 1.0 : 0.92)
            .animation(.spring(response: 0.45, dampingFraction: 0.7), value: player.isPlaying)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.25)) { visualizerOn.toggle() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Track info

    private var trackInfo: some View {
        VStack(spacing: 4) {
            Text(player.current?.Name ?? "")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .foregroundStyle(.white)
            if let album = player.current?.Album, !album.isEmpty {
                Text(album)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Text(player.current?.primaryArtistName ?? "")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .frame(maxWidth: 560)
    }

    private var isFavorite: Bool {
        guard let id = player.current?.Id else { return false }
        if let override = favoriteOverride[id] { return override }
        return player.current?.UserData?.IsFavorite ?? false
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
    private var sleepIcon: String {
        sleepTimer.mode == .off ? "moon.zzz" : "moon.zzz.fill"
    }
    private var sleepLabel: String {
        switch sleepTimer.mode {
        case .off: return "Sleep"
        case .duration: return formatSleepRemaining(sleepTimer.remaining)
        case .endOfTrack: return "End"
        }
    }
    private func formatSleepRemaining(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
    private func toggleDownload() {
        guard let item = player.current, let url = auth.serverURL else { return }
        if downloads.isDownloaded(item.Id) {
            downloads.delete(item.Id)
        } else {
            downloads.download(item, using: JellyfinClient(baseURL: url, auth: auth))
        }
    }
    private func favoriteToggle() {
        guard let cur = player.current, let url = auth.serverURL else { return }
        let target = !isFavorite
        // Optimistic UI update.
        favoriteOverride[cur.Id] = target
        let client = JellyfinClient(baseURL: url, auth: auth)
        Task {
            do {
                try await client.setFavorite(cur.Id, favorite: target)
            } catch {
                await MainActor.run {
                    // Revert on failure.
                    favoriteOverride[cur.Id] = !target
                }
            }
        }
    }

    // MARK: - Scrubber

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
            .tint(.white)
            HStack {
                Text((isScrubbing ? scrub : player.currentTime).mmSS)
                Spacer()
                Text(player.duration.mmSS)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    // MARK: - Transport controls (with inline lyrics/sleep/download)

    private var controls: some View {
        HStack(spacing: 22) {
            iconButton("text.quote", help: "Lyrics") { showLyrics = true }
            iconButton(sleepIcon, help: sleepLabel,
                       active: sleepTimer.mode != .off) { showSleepSheet = true }
            iconButton("shuffle", help: "Shuffle",
                       active: player.shuffle) { player.toggleShuffle() }
            iconButton("backward.fill", help: "Previous", large: true) { player.previous() }
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            iconButton("forward.fill", help: "Next", large: true) { player.next() }
            iconButton(player.repeatMode == .one ? "repeat.1" : "repeat",
                       help: "Repeat",
                       active: player.repeatMode != .off) { player.cycleRepeatMode() }
            iconButton(downloadIcon, help: downloadLabel,
                       active: isDownloaded) { toggleDownload() }
            iconButton(isFavorite ? "heart.fill" : "heart",
                       help: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                       active: isFavorite) { favoriteToggle() }
        }
    }

    @ViewBuilder
    private func iconButton(_ icon: String,
                            help: String,
                            active: Bool = false,
                            large: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(large ? .title2 : .title3)
                .foregroundStyle(active ? Color.accentColor : .white)
                .frame(width: large ? 36 : 30, height: large ? 36 : 30)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Bottom bar (airplay placeholder, album, queue)

    private var bottomBar: some View {
        HStack {
            Image(systemName: "airplayaudio")
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Button { showQueue = true } label: {
                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .font(.title3)
    }

    // MARK: - Helpers

    private func loadArtwork() async {
        artwork = nil
        guard let current = player.current,
              let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        let imgURL = client.imageURL(for: current.artworkItemId, tag: current.artworkTag, maxWidth: 1200)
        guard let imgURL else { return }
        let img = await ImageCache.shared.load(url: imgURL, headers: ["Authorization": auth.authHeader()])
        await MainActor.run { self.artwork = img }
    }
}

// MARK: - Visualizer styles

enum VisualizerStyle_Mac: String, CaseIterable, Identifiable {
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
/// Right-click to switch between styles. Style choice is persisted across
/// launches and shared with iOS via the same UserDefaults key.
struct InlineVisualizer_Mac: View {
    @EnvironmentObject var player: AudioPlayer
    @AppStorage("bolera.visualizer.style") private var styleRaw: String = VisualizerStyle_Mac.bars.rawValue

    private var style: VisualizerStyle_Mac { VisualizerStyle_Mac(rawValue: styleRaw) ?? .bars }

    /// Smoothed levels, mutated on each frame inside Canvas closure via a
    /// reference-type box so we don't trigger SwiftUI updates per frame.
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
                    Visualizers_Mac.drawBars(gfx: gfx, size: size, levels: state.smoothed)
                    Visualizers_Mac.drawWave(gfx: gfx, size: size, levels: state.smoothed, t: now)
                case .wave:
                    Visualizers_Mac.drawBigWave(gfx: gfx, size: size, levels: state.smoothed, t: now)
                case .radial:
                    Visualizers_Mac.drawRadial(gfx: gfx, size: size, levels: state.smoothed, t: now)
                case .pulse:
                    Visualizers_Mac.drawPulse(gfx: gfx, size: size, levels: state.smoothed, t: now)
                case .mirror:
                    Visualizers_Mac.drawMirror(gfx: gfx, size: size, levels: state.smoothed)
                }
            }
            .background(Color.black.opacity(0.6))
        }
        .contentShape(Rectangle())
        .contextMenu {
            ForEach(VisualizerStyle_Mac.allCases) { s in
                Button {
                    styleRaw = s.rawValue
                } label: {
                    Label(s.label, systemImage: s.icon)
                    if s == style { Image(systemName: "checkmark") }
                }
            }
        }
    }

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

// MARK: - Shared visualizer draw routines (Mac)

enum Visualizers_Mac {
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

    static func drawRadial(gfx: GraphicsContext, size: CGSize, levels: [Float], t: TimeInterval) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let baseR = min(size.width, size.height) * 0.18
        let maxLen = min(size.width, size.height) * 0.32
        let count = levels.count * 2
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
        let ring = Path(ellipseIn: CGRect(x: center.x - baseR, y: center.y - baseR,
                                          width: baseR * 2, height: baseR * 2))
        gfx.stroke(ring, with: .color(Color.white.opacity(0.18)), lineWidth: 1.2)
    }

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
        var line = Path()
        line.move(to: CGPoint(x: originX, y: centerY))
        line.addLine(to: CGPoint(x: originX + availableW, y: centerY))
        gfx.stroke(line, with: .color(Color.white.opacity(0.15)), lineWidth: 0.5)
    }
}

// MARK: - Queue sheet (Mac sheet for queue access from immersive)

struct QueueSheet_Mac: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var showSaveSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Queue").font(.headline)
                Spacer()
                Menu {
                    Button {
                        showSaveSheet = true
                    } label: {
                        Label("Save as Playlist…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(player.queue.isEmpty)
                    Divider()
                    Button(role: .destructive) {
                        player.clearQueue()
                        dismiss()
                    } label: {
                        Label("Clear Queue", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
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
                }
            }
        }
        .sheet(isPresented: $showSaveSheet) {
            SavePlayQueueSheet_Mac()
                .environmentObject(player)
                .environmentObject(auth)
        }
    }
}

private struct SavePlayQueueSheet_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) var dismiss
    @State private var name: String = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Save Queue as Playlist").font(.headline)
            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)
            Text("\(player.queue.count) tracks").font(.caption).foregroundStyle(.secondary)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button {
                    save()
                } label: {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .frame(width: 320)
        }
        .padding(24)
        .frame(width: 380)
    }

    private func save() {
        guard let url = auth.serverURL else { return }
        saving = true
        let ids = player.queue.map { $0.Id }
        let title = name.trimmingCharacters(in: .whitespaces)
        Task {
            let client = JellyfinClient(baseURL: url, auth: auth)
            do {
                _ = try await client.createPlaylist(name: title, itemIds: ids)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    saving = false
                }
            }
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

// MARK: - Lyrics sheet (Mac)

private struct LyricsSheet_Mac: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @State private var lyrics: Lyrics = .empty
    @State private var loading = false
    @State private var lastItemId: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Lyrics").font(.headline)
                Spacer()
                if let t = player.current?.Name {
                    Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { isPresented = false }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            if loading && lyrics.isEmpty {
                Spacer(); ProgressView(); Spacer()
            } else if lyrics.isEmpty {
                Spacer()
                Text("No lyrics available for this track.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            Color.clear.frame(height: 16).id("top")
                            ForEach(lyrics.lines) { line in
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(isCurrent(line) ? Color.primary : Color.secondary)
                                    .id(line.id)
                                    .padding(.horizontal, 16)
                                    .onTapGesture {
                                        if let ts = line.timestamp { player.seek(to: ts) }
                                    }
                            }
                            Color.clear.frame(height: 60)
                        }
                    }
                    .onChange(of: currentLineId) { _, new in
                        guard lyrics.isSynced, let id = new else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .task(id: player.current?.Id) { await loadIfNeeded() }
    }

    private var currentLineId: UUID? {
        guard lyrics.isSynced else { return nil }
        let t = player.currentTime
        var best: LyricsLine?
        for line in lyrics.lines where (line.timestamp ?? -1) <= t {
            best = line
        }
        return best?.id
    }
    private func isCurrent(_ line: LyricsLine) -> Bool { line.id == currentLineId }

    private func loadIfNeeded() async {
        guard let item = player.current, let url = auth.serverURL else { return }
        guard item.Id != lastItemId else { return }
        lastItemId = item.Id
        loading = true
        let client = JellyfinClient(baseURL: url, auth: auth)
        let result = (try? await client.lyrics(for: item.Id)) ?? .empty
        await MainActor.run {
            self.lyrics = result
            self.loading = false
        }
    }
}

// MARK: - Add to Playlist sheet (Mac)

private struct AddToPlaylistSheet_Mac: View {
    let item: BaseItem
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) var dismiss
    @State private var playlists: [BaseItem] = []
    @State private var newName: String = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add to Playlist").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            List {
                Section("New Playlist") {
                    HStack {
                        TextField("Playlist name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                        Button("Create") { createNew() }
                            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || saving)
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
            if let error { Text(error).font(.caption).foregroundStyle(.red).padding() }
        }
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        playlists = (try? await client.playlists()) ?? []
    }
    private func createNew() {
        guard let url = auth.serverURL else { return }
        saving = true
        Task {
            let client = JellyfinClient(baseURL: url, auth: auth)
            _ = try? await client.createPlaylist(name: newName, itemIds: [item.Id])
            await MainActor.run { saving = false; dismiss() }
        }
    }
    private func add(to playlistId: String) {
        guard let url = auth.serverURL else { return }
        saving = true
        Task {
            let client = JellyfinClient(baseURL: url, auth: auth)
            try? await client.addToPlaylist(playlistId: playlistId, itemIds: [item.Id])
            await MainActor.run { saving = false; dismiss() }
        }
    }
}

// MARK: - Album tracks sheet (Mac, simple list)

struct AlbumTracksSheet_Mac: View {
    let album: BaseItem
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) var dismiss
    @State private var songs: [BaseItem] = []
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(album.Name).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            HStack(spacing: 10) {
                Button {
                    player.play(items: songs)
                } label: {
                    Label("Play All", systemImage: "play.fill")
                }
                Button {
                    var s = songs; s.shuffle()
                    player.play(items: s)
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                Spacer()
            }
            .padding(.horizontal).padding(.top, 8)
            List {
                ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
                    HStack {
                        Text("\(song.IndexNumber ?? idx + 1).")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, alignment: .trailing)
                        VStack(alignment: .leading) {
                            Text(song.Name).lineLimit(1)
                            Text(song.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(song.durationSeconds.mmSS).font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { player.play(items: songs, startAt: idx) }
                }
            }
            if loading { ProgressView().padding() }
        }
        .task { await load() }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        loading = true
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let s = try? await client.songs(parentId: album.Id) {
            songs = s
        }
        loading = false
    }
}

// MARK: - Artist albums sheet (Mac)

struct ArtistAlbumsSheet_Mac: View {
    let artist: BaseItem
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) var dismiss
    @State private var albums: [BaseItem] = []
    @State private var loading = false
    @State private var selectedAlbum: BaseItem?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(artist.Name).font(.headline).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            List {
                ForEach(albums) { album in
                    HStack {
                        Image(systemName: "opticaldisc").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(album.Name).lineLimit(1)
                            if let year = album.ProductionYear {
                                Text(String(year)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selectedAlbum = album }
                }
            }
            if loading { ProgressView().padding() }
        }
        .task { await load() }
        .sheet(item: $selectedAlbum) { album in
            AlbumTracksSheet_Mac(album: album)
                .environmentObject(auth)
                .environmentObject(player)
                .frame(minWidth: 480, minHeight: 540)
        }
    }

    private func load() async {
        guard let url = auth.serverURL else { return }
        loading = true
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let a = try? await client.albumsForArtist(artist.Id) {
            albums = a
        }
        loading = false
    }
}

// MARK: - Sleep timer sheet (Mac)

private struct SleepTimerSheet_Mac: View {
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
        VStack(spacing: 0) {
            HStack {
                Text("Sleep Timer").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
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
                        Button(role: .destructive) {
                            sleepTimer.cancel()
                            dismiss()
                        } label: { Text("Cancel timer") }
                    }
                }
            }
        }
    }
}
