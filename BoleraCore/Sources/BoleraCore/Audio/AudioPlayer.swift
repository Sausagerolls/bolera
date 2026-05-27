import Foundation
import AVFoundation
import MediaPlayer
import Combine
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum RepeatMode: Int {
    case off, all, one
}

/// Singleton audio engine. Maintains two `AVPlayer` instances so we can crossfade
/// between consecutive tracks, installs an `MTAudioProcessingTap` on each item
/// for real-time EQ + visualizer levels, prefers locally downloaded files when
/// available, and keeps `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` in
/// sync so lock screen / Control Center / AirPlay / CarPlay all work.
public final class AudioPlayer: NSObject, ObservableObject {
    public static let shared = AudioPlayer()

    @Published public private(set) var queue: [BaseItem] = []
    @Published public private(set) var currentIndex: Int = 0
    @Published public private(set) var isPlaying: Bool = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var artwork: PlatformImage?
    @Published public var shuffle: Bool = false {
        didSet { UserDefaults.standard.set(shuffle, forKey: "bolera.shuffle") }
    }
    @Published public var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "bolera.repeat") }
    }
    /// Crossfade overlap duration. 0 means hard cut.
    @Published public var crossfadeDuration: Double = UserDefaults.standard.double(forKey: "bolera.crossfade") {
        didSet { UserDefaults.standard.set(crossfadeDuration, forKey: "bolera.crossfade") }
    }

    public var current: BaseItem? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// Pre-shuffle order, used to restore when shuffle is turned off.
    private var originalQueue: [BaseItem] = []

    // Two player instances, swapped on crossfade.
    private let playerA = AVPlayer()
    private let playerB = AVPlayer()
    private var activeIsA: Bool = true
    private var activePlayer: AVPlayer { activeIsA ? playerA : playerB }
    private var inactivePlayer: AVPlayer { activeIsA ? playerB : playerA }
    private var processorA: AudioProcessor?
    private var processorB: AudioProcessor?

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var endObserverItem: AVPlayerItem?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?

    private var crossfadeTimer: Timer?
    private var crossfadeStartedFor: BaseItem?
    private var nextPrepared: Bool = false
    /// Set while loadCurrent is preparing a new item but the old item is still
    /// attached to activePlayer. The periodic time observer would otherwise
    /// read the old item's scrubbed position and flicker the progress bar.
    private var pendingTrackSwap: Bool = false
    /// Short blackout window after a programmatic seek (e.g. repeat-one loop)
    /// so the periodic tick doesn't echo the previous position before the
    /// AVPlayer seek has actually landed.
    private var ignoreTicksUntil: Date = .distantPast

    private var client: JellyfinClient? {
        guard let url = authManager?.serverURL, let auth = authManager else { return nil }
        return JellyfinClient(baseURL: url, auth: auth)
    }
    public weak var authManager: AuthManager?

    private var playSessionId: String = UUID().uuidString
    private var lastProgressReport: Date = .distantPast

    // Last.fm scrobbling state
    private var trackStartedAt: Date?
    private var hasScrobbledCurrent: Bool = false
    private var hasUpdatedNowPlayingCurrent: Bool = false

    public override init() {
        super.init()
        shuffle = UserDefaults.standard.bool(forKey: "bolera.shuffle")
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "bolera.repeat")) ?? .off
        addTimeObserver()
        observePlayer()
        setupRemoteCommands()
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleInterruption),
                                               name: AVAudioSession.interruptionNotification,
                                               object: nil)
        #endif
    }

    // MARK: - Session

    public func configureAudioSession() {
        #if canImport(UIKit)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
        #endif
    }

    // MARK: - Queue control

    public func play(items: [BaseItem], startAt index: Int = 0) {
        guard !items.isEmpty else { return }
        playSessionId = UUID().uuidString
        originalQueue = items
        if shuffle {
            var rest = items
            let start = rest.remove(at: index)
            rest.shuffle()
            queue = [start] + rest
            currentIndex = 0
        } else {
            queue = items
            currentIndex = index
        }
        loadCurrent(autoplay: true)
    }

    public func playNext(_ item: BaseItem) {
        let insertAt = min(currentIndex + 1, queue.count)
        queue.insert(item, at: insertAt)
        if !originalQueue.contains(where: { $0.Id == item.Id }) {
            originalQueue.append(item)
        }
    }

    public func addToQueue(_ item: BaseItem) {
        queue.append(item)
        if !originalQueue.contains(where: { $0.Id == item.Id }) {
            originalQueue.append(item)
        }
    }

    public func move(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        if let idx = source.first {
            if idx == currentIndex {
                currentIndex = destination > idx ? destination - 1 : destination
            } else if idx < currentIndex, destination > currentIndex {
                currentIndex -= 1
            } else if idx > currentIndex, destination <= currentIndex {
                currentIndex += 1
            }
        }
    }

    public func remove(at offsets: IndexSet) {
        for idx in offsets.sorted(by: >) {
            if idx == currentIndex {
                queue.remove(at: idx)
                if queue.isEmpty { stop(); return }
                currentIndex = min(currentIndex, queue.count - 1)
                loadCurrent(autoplay: true)
            } else if idx < currentIndex {
                queue.remove(at: idx)
                currentIndex -= 1
            } else {
                queue.remove(at: idx)
            }
        }
    }

    public func clearQueue() {
        stop()
        queue = []
        originalQueue = []
        currentIndex = 0
    }

    // MARK: - Transport

    public func togglePlayPause() { isPlaying ? pause() : play() }

    public func play() {
        guard !queue.isEmpty else { return }
        if activePlayer.currentItem == nil { loadCurrent(autoplay: true); return }
        activePlayer.play()
        isPlaying = true
        updateNowPlaying()
        reportProgress(event: "unpause", paused: false)
    }

    public func pause() {
        activePlayer.pause()
        isPlaying = false
        updateNowPlaying()
        reportProgress(event: "pause", paused: true)
    }

    public func stop() {
        if let current = current {
            Task { try? await reportStop(item: current) }
        }
        cancelCrossfade()
        playerA.pause(); playerB.pause()
        playerA.replaceCurrentItem(with: nil)
        playerB.replaceCurrentItem(with: nil)
        unregisterProcessors()
        isPlaying = false
        currentTime = 0
        duration = 0
        artwork = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    public func next() {
        if repeatMode == .one {
            currentTime = 0
            ignoreTicksUntil = Date().addingTimeInterval(0.25)
            seek(to: 0)
            play()
            return
        }
        if MainActor.assumeIsolated({ SleepTimer.shared.consumeEndOfTrackStop() }) {
            stop(); return
        }
        let isIgnored: (BaseItem) -> Bool = { item in
            MainActor.assumeIsolated { IgnoredTracksStore.shared.isIgnored(item.Id) }
        }
        // Scan forward for the next non-ignored track.
        var probe = currentIndex + 1
        while probe < queue.count {
            if !isIgnored(queue[probe]) {
                currentIndex = probe
                loadCurrent(autoplay: true)
                return
            }
            probe += 1
        }
        if repeatMode == .all {
            // Wrap to first non-ignored track.
            for idx in 0..<queue.count {
                if !isIgnored(queue[idx]) {
                    currentIndex = idx
                    loadCurrent(autoplay: true)
                    return
                }
            }
        }
        stop()
    }

    public func previous() {
        if currentTime > 3 {
            seek(to: 0); return
        }
        if currentIndex > 0 {
            currentIndex -= 1
            loadCurrent(autoplay: true)
        } else {
            seek(to: 0)
        }
    }

    public func seek(to seconds: Double) {
        // Optimistic update so the UI snaps to the target immediately
        // (avoids the slider flicking back to the pre-scrub position while
        // the AVPlayer seek is in flight). Also blank-out periodic ticks
        // briefly so they don't echo the old position before the seek lands.
        currentTime = seconds
        ignoreTicksUntil = Date().addingTimeInterval(0.3)
        let time = CMTime(seconds: seconds, preferredTimescale: 1000)
        activePlayer.seek(to: time) { [weak self] _ in
            guard let self = self, !self.pendingTrackSwap else { return }
            self.currentTime = seconds
            self.updateNowPlaying()
            self.reportProgress(event: "timeupdate", paused: !self.isPlaying)
        }
    }

    public func jumpTo(index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        loadCurrent(autoplay: true)
    }

    public func toggleShuffle() {
        shuffle.toggle()
        applyShuffleState()
    }

    private func applyShuffleState() {
        guard !queue.isEmpty else { return }
        let currentItem = current
        if shuffle {
            var rest = queue
            if let cur = currentItem, let idx = rest.firstIndex(of: cur) {
                rest.remove(at: idx)
            }
            rest.shuffle()
            queue = (currentItem.map { [$0] } ?? []) + rest
            currentIndex = 0
        } else {
            queue = originalQueue
            currentIndex = currentItem.flatMap { c in queue.firstIndex(where: { $0.Id == c.Id }) } ?? 0
        }
    }

    public func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    // MARK: - Loading

    private func loadCurrent(autoplay: Bool) {
        guard let item = current else { return }
        cancelCrossfade()

        let url: URL
        if let local = DownloadManager.shared.localFileURL(for: item.Id) {
            url = local
        } else if let client = client {
            url = client.audioStreamURL(for: item.Id)
        } else { return }

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)

        // Install a fresh AudioProcessor + tap for this item.
        let processor = AudioProcessor()
        Task { @MainActor in EQManager.shared.register(processor) }

        // Tear down the old active processor (the inactive one we leave alone — it
        // belongs to the previous track and will get replaced on crossfade swap).
        if activeIsA {
            if let old = processorA { Task { @MainActor in EQManager.shared.unregister(old) } }
            processorA = processor
        } else {
            if let old = processorB { Task { @MainActor in EQManager.shared.unregister(old) } }
            processorB = processor
        }

        inactivePlayer.pause()
        inactivePlayer.volume = 0.0
        activePlayer.volume = 1.0
        nextPrepared = false
        crossfadeStartedFor = nil

        pendingTrackSwap = true
        currentTime = 0
        duration = item.durationSeconds
        artwork = nil
        trackStartedAt = Date()
        hasScrobbledCurrent = false
        hasUpdatedNowPlayingCurrent = false

        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            if item.status == .readyToPlay {
                let d = CMTimeGetSeconds(item.duration)
                self?.duration = d.isFinite ? d : (self?.duration ?? 0)
                self?.updateNowPlaying()
            }
        }
        replaceEndObserver(for: playerItem)

        // Wait for audio tap install, THEN swap in the player item + autoplay.
        installTapAsync(processor: processor, asset: asset, on: playerItem) { [weak self] in
            guard let self = self else { return }
            self.activePlayer.replaceCurrentItem(with: playerItem)
            self.pendingTrackSwap = false
            self.currentTime = 0
            if autoplay {
                self.activePlayer.play()
                self.isPlaying = true
            }
        }
        loadArtwork(for: item)
        updateNowPlaying()
        Task { try? await reportStart(item: item) }
        Task { @MainActor in await LastFmService.shared.updateNowPlaying(item); hasUpdatedNowPlayingCurrent = true }
    }

    /// Asynchronously load tracks off-main, then attach the audio mix on main.
    /// The mix has to be assigned BEFORE the AVPlayer has fully started processing
    /// audio for the tap callbacks to fire — assignment after `play()` is silently
    /// ignored by AVPlayer on iOS 18+. So we rely on `replaceCurrentItem` being
    /// called only after the mix is attached (handled by `loadCurrent`'s wait path).
    private func installTapAsync(processor: AudioProcessor, asset: AVURLAsset, on playerItem: AVPlayerItem, then continuation: @escaping () -> Void) {
        // Fire the continuation up front so playback isn't delayed waiting for the
        // audio tap. The tap install retries in the background — if the asset takes
        // a moment to enumerate tracks, we attach `audioMix` on the live playerItem
        // when ready.
        Task { @MainActor in continuation() }

        Task.detached(priority: .userInitiated) {
            // Some streams (e.g. transcoded HTTP) return 0 tracks on first load. Poll briefly.
            for attempt in 0..<6 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 500_000_000) }
                do {
                    _ = try await asset.load(.tracks, .duration)
                    let tracks = try await asset.loadTracks(withMediaType: .audio)
                    if let track = tracks.first, let mix = processor.makeAudioMix(for: track) {
                        await MainActor.run { playerItem.audioMix = mix }
                        return
                    }
                } catch { /* retry */ }
            }
        }
    }

    private func replaceEndObserver(for item: AVPlayerItem) {
        if let prev = endObserver { NotificationCenter.default.removeObserver(prev) }
        endObserverItem = item
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            // If a crossfade already swapped to the next track, ignore the dying item's end.
            if self.crossfadeStartedFor != nil { return }
            self.next()
        }
    }

    private func loadArtwork(for item: BaseItem) {
        guard let client = client else { return }
        guard let url = client.imageURL(for: item.artworkItemId, tag: item.artworkTag, maxWidth: 600) else { return }
        Task {
            if let image = await ImageCache.shared.load(url: url, headers: ["Authorization": authManager?.authHeader() ?? ""]) {
                await MainActor.run {
                    self.artwork = image
                    self.updateNowPlaying()
                }
            }
        }
    }

    private func unregisterProcessors() {
        if let p = processorA { Task { @MainActor in EQManager.shared.unregister(p) } }
        if let p = processorB { Task { @MainActor in EQManager.shared.unregister(p) } }
        processorA = nil
        processorB = nil
    }

    // MARK: - Crossfade

    private func maybeStartCrossfade() {
        guard crossfadeDuration > 0.5 else { return }
        guard duration > crossfadeDuration + 1 else { return }
        guard let cur = current, crossfadeStartedFor?.Id != cur.Id else { return }
        guard currentTime >= duration - crossfadeDuration else { return }

        // Determine the next track in the queue.
        let nextIndex: Int
        if repeatMode == .one {
            nextIndex = currentIndex
        } else if currentIndex + 1 < queue.count {
            nextIndex = currentIndex + 1
        } else if repeatMode == .all {
            nextIndex = 0
        } else {
            return // no next track to fade into
        }
        if MainActor.assumeIsolated({ SleepTimer.shared.willStopAtEndOfTrack }) { return }
        crossfadeStartedFor = cur

        let nextItem = queue[nextIndex]
        let url: URL
        if let local = DownloadManager.shared.localFileURL(for: nextItem.Id) {
            url = local
        } else if let client = client {
            url = client.audioStreamURL(for: nextItem.Id)
        } else { return }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)

        let processor = AudioProcessor()
        Task { @MainActor in EQManager.shared.register(processor) }

        if activeIsA {
            if let old = processorB { Task { @MainActor in EQManager.shared.unregister(old) } }
            processorB = processor
        } else {
            if let old = processorA { Task { @MainActor in EQManager.shared.unregister(old) } }
            processorA = processor
        }

        installTapAsync(processor: processor, asset: asset, on: item) { [weak self] in
            guard let self = self else { return }
            self.inactivePlayer.replaceCurrentItem(with: item)
            self.inactivePlayer.volume = 0
            self.inactivePlayer.play()
        }

        // Animate volumes over `crossfadeDuration`.
        let total = crossfadeDuration
        let start = Date()
        let fadingOut = activePlayer
        let fadingIn = inactivePlayer
        let upcoming = nextItem
        crossfadeTimer?.invalidate()
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let elapsed = Date().timeIntervalSince(start)
            let t = min(1.0, elapsed / total)
            fadingOut.volume = Float(1.0 - t)
            fadingIn.volume = Float(t)
            if t >= 1.0 {
                timer.invalidate()
                self.completeCrossfade(to: upcoming, nextIndex: nextIndex)
            }
        }
    }

    private func completeCrossfade(to upcoming: BaseItem, nextIndex: Int) {
        crossfadeTimer = nil
        // Swap active/inactive roles.
        activePlayer.pause()
        activePlayer.replaceCurrentItem(with: nil)
        activeIsA.toggle()
        activePlayer.volume = 1.0
        currentIndex = nextIndex
        currentTime = 0
        duration = upcoming.durationSeconds
        artwork = nil
        trackStartedAt = Date()
        hasScrobbledCurrent = false
        hasUpdatedNowPlayingCurrent = false
        crossfadeStartedFor = nil

        if let item = activePlayer.currentItem {
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .readyToPlay { self?.duration = CMTimeGetSeconds(item.duration) }
            }
            replaceEndObserver(for: item)
        }
        loadArtwork(for: upcoming)
        updateNowPlaying()
        Task { try? await reportStart(item: upcoming) }
        Task { @MainActor in await LastFmService.shared.updateNowPlaying(upcoming) }
    }

    private func cancelCrossfade() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeStartedFor = nil
        nextPrepared = false
    }

    // MARK: - Observation

    private func addTimeObserver() {
        timeObserver = playerA.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 10), queue: .main) { [weak self] _ in
            self?.tick()
        }
        // Second observer on player B so we still get updates after a crossfade swap.
        _ = playerB.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 10), queue: .main) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        // Suppress reads while a new item is being prepared; otherwise the
        // observer would echo the previous track's scrub position before the
        // replaceCurrentItem callback fires.
        guard !pendingTrackSwap else { return }
        // Also skip during the post-programmatic-seek blackout window.
        guard Date() >= ignoreTicksUntil else { return }
        guard let item = activePlayer.currentItem else { return }
        let t = CMTimeGetSeconds(item.currentTime())
        currentTime = t.isFinite ? t : 0
        if let cur = current, !hasScrobbledCurrent {
            // Last.fm scrobble rule: track must be > 30s long and listened past
            // 50% OR 4 minutes, whichever comes first.
            let half = duration * 0.5
            let cutoff = min(half, 240)
            if duration > 30, currentTime >= cutoff, let startedAt = trackStartedAt {
                hasScrobbledCurrent = true
                Task { @MainActor in await LastFmService.shared.scrobble(cur, startedAt: startedAt) }
            }
        }
        maybeStartCrossfade()
        if Date().timeIntervalSince(lastProgressReport) > 10 {
            lastProgressReport = Date()
            reportProgress(event: "timeupdate", paused: !isPlaying)
        }
    }

    private func observePlayer() {
        rateObserver = playerA.observe(\.rate, options: [.new]) { [weak self] p, _ in
            guard let self = self, self.activeIsA else { return }
            self.isPlaying = p.rate != 0
            self.updateNowPlaying()
        }
        _ = playerB.observe(\.rate, options: [.new]) { [weak self] p, _ in
            guard let self = self, !self.activeIsA else { return }
            self.isPlaying = p.rate != 0
            self.updateNowPlaying()
        }
    }

    #if canImport(UIKit)
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            pause()
        case .ended:
            if let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                if opts.contains(.shouldResume) { play() }
            }
        @unknown default: break
        }
    }
    #endif

    // MARK: - Now Playing / Remote Commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.seek(to: min(self.currentTime + 15, self.duration))
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            self.seek(to: max(self.currentTime - 15, 0))
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let item = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.Name,
            MPMediaItemPropertyArtist: item.primaryArtistName,
            MPMediaItemPropertyAlbumTitle: item.Album ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]
        if let artwork = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Playback reporting

    private func reportStart(item: BaseItem) async throws {
        guard let client = client else { return }
        let info = PlaybackStartInfo(ItemId: item.Id,
                                     PlaySessionId: playSessionId,
                                     PositionTicks: Int64(currentTime * 10_000_000))
        try await client.reportPlaybackStart(info)
    }

    private func reportProgress(event: String, paused: Bool) {
        guard let item = current, let client = client else { return }
        let info = PlaybackProgressInfo(ItemId: item.Id,
                                        PlaySessionId: playSessionId,
                                        PositionTicks: Int64(currentTime * 10_000_000),
                                        IsPaused: paused,
                                        IsMuted: false,
                                        EventName: event)
        Task { try? await client.reportPlaybackProgress(info) }
    }

    private func reportStop(item: BaseItem) async throws {
        guard let client = client else { return }
        let info = PlaybackStopInfo(ItemId: item.Id,
                                    PlaySessionId: playSessionId,
                                    PositionTicks: Int64(currentTime * 10_000_000))
        try await client.reportPlaybackStopped(info)
    }

    /// Exposed for the visualizer view.
    public var activeAudioProcessor: AudioProcessor? {
        activeIsA ? processorA : processorB
    }
}
