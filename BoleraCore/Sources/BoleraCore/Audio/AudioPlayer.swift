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

    /// Whether playback was active when an audio-session interruption began, so
    /// we know to resume (and reactivate the session) when it ends.
    private var interruptedWhilePlaying = false

    /// Pre-loaded AVURLAssets for upcoming queue items, keyed by track Id.
    /// Kept in memory so a Next press / natural end-of-track can swap to
    /// the next track instantly without an HTTP open + initial buffer
    /// stall. We warm the next `preloadDepth` items in the queue.
    private var preloadedAssets: [String: AVURLAsset] = [:]
    private let preloadDepth = 3
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
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleRouteChange),
                                               name: AVAudioSession.routeChangeNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleMediaReset),
                                               name: AVAudioSession.mediaServicesWereResetNotification,
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

    /// Re-activate the shared audio session. The system DEACTIVATES it during
    /// an interruption (Siri, a nav prompt, a notification while driving); if we
    /// resume playback without reactivating, the player advances — progress bar
    /// keeps moving — but no audio reaches the output. Reactivating here fixes
    /// that "playing but silent" state.
    private func reactivateSession() {
        #if canImport(UIKit)
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { print("[AudioPlayer] session reactivate failed: \(error)") }
        #endif
    }

    // MARK: - Queue control

    public func play(items: [BaseItem], startAt index: Int = 0) {
        guard !items.isEmpty else { return }
        queueExtender = nil          // a plain play isn't an endless mix
        extenderExhausted = false
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

    /// Supplies more tracks when an endless mix nears its end. Given the ids
    /// already queued this session, returns fresh tracks to append.
    public typealias QueueExtender = (_ existingIds: Set<String>) async -> [BaseItem]
    public var queueExtender: QueueExtender?
    private var isExtendingQueue = false
    private var extenderExhausted = false

    /// Play `items` as an endless mix: as the queue nears its end, `extender`
    /// is asked for more tracks and they're appended (deduped, no repeats), so
    /// a daily mix keeps going instead of stopping.
    public func playMix(items: [BaseItem], extender: @escaping QueueExtender) {
        play(items: items)           // resets queueExtender to nil…
        queueExtender = extender      // …then arm it for this mix
    }

    /// When fewer than a couple of tracks remain ahead of the current one, ask
    /// the extender for more and append what's genuinely new. Called on every
    /// track change (loadCurrent).
    private func maybeExtendQueue() {
        guard let extender = queueExtender, !isExtendingQueue, !extenderExhausted,
              !queue.isEmpty, queue.count - 1 - currentIndex <= 2 else { return }
        isExtendingQueue = true
        let existing = Set(queue.map { $0.Id }).union(originalQueue.map { $0.Id })
        Task { @MainActor in
            let more = await extender(existing)
            self.isExtendingQueue = false
            // Bail if the play context changed while fetching.
            guard self.queueExtender != nil else { return }
            let have = Set(self.queue.map { $0.Id })
            let fresh = more.filter { !have.contains($0.Id) }
            if fresh.isEmpty {
                // Nothing new to add — the artist's neighbourhood is tapped out;
                // stop hammering the extender for the rest of this mix.
                self.extenderExhausted = true
                return
            }
            self.queue.append(contentsOf: fresh)
            self.originalQueue.append(contentsOf: fresh)
        }
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
        // Keep `artwork`: stop() leaves `current` set (the Now Playing screen
        // still shows the last track), so blanking the cover here left a track
        // with a placeholder image until the user pressed play. The next
        // loadCurrent() resets artwork for the incoming track anyway.
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

        // Reuse the warmed asset when possible — saves the HTTP open +
        // track enumeration round-trip that would otherwise stall the
        // start of playback by 1–2 seconds.
        let asset: AVURLAsset
        if let warmed = consumePreloadedAsset(for: item) {
            asset = warmed
        } else {
            let url: URL
            if let local = DownloadManager.shared.localFileURL(for: item.Id) {
                url = local
            } else if let client = client {
                url = client.audioStreamURL(for: item.Id)
            } else { return }
            asset = AVURLAsset(url: url)
        }
        let playerItem = AVPlayerItem(asset: asset)

        // Install a fresh AudioProcessor + tap for this item.
        let processor = AudioProcessor()
        Task { @MainActor in EQManager.shared.register(processor) }

        // Tear down the old active processor (the inactive one we leave alone — it
        // belongs to the previous track and will get replaced on crossfade swap).
        if activeIsA {
            if let old = processorA {
                detachMix(from: playerA)   // finalize the old tap before dropping our ref
                Task { @MainActor in EQManager.shared.unregister(old) }
            }
            processorA = processor
        } else {
            if let old = processorB {
                detachMix(from: playerB)
                Task { @MainActor in EQManager.shared.unregister(old) }
            }
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
            } else if item.status == .failed {
                // Surface the failure instead of leaving the UI stuck on
                // "Playing" with no audio (the most common cause is a
                // Jellyfin server that's unreachable from the device —
                // e.g. LAN-only server while phone is on cellular).
                let reason = item.error?.localizedDescription ?? "unknown"
                print("[AudioPlayer] AVPlayerItem failed: \(reason). URL: \(item.asset.description)")
                Task { @MainActor in
                    self?.isPlaying = false
                    self?.pendingTrackSwap = false
                }
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
        maybeExtendQueue()   // endless-mix: top up the queue as it nears the end
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
        // CarPlay's Now Playing template reads MPNowPlayingInfoCenter
        // *once* when it appears on the head unit screen — later
        // updates do refresh in iOS but the first frame the driver sees
        // is whatever we set right now. If the user just browsed this
        // album in the Library tab the artwork is already in the
        // in-memory cache, so use it synchronously to avoid a blank
        // artwork pane while the async fetch round-trips.
        //
        // Try the 600pt URL first (what we'll end up showing), then
        // fall back to the 240pt URL that CarPlay list cells populated
        // when the user was browsing — different maxWidth means
        // different cache key, so the small art is the most likely
        // synchronous hit on a fresh CarPlay session.
        if let cached = ImageCache.shared.peekMemory(url: url) {
            artwork = cached
            updateNowPlaying()
        } else if let smallURL = client.imageURL(for: item.artworkItemId, tag: item.artworkTag, maxWidth: 240),
                  let cached = ImageCache.shared.peekMemory(url: smallURL) {
            artwork = cached
            updateNowPlaying()
        }
        Task {
            // Prefer the downloaded local copy so artwork shows offline; falls
            // back to the server URL when the track isn't downloaded.
            if let image = await ImageCache.shared.loadArtwork(itemId: item.artworkItemId,
                                                               tag: item.artworkTag,
                                                               client: client,
                                                               maxWidth: 600,
                                                               headers: ["Authorization": authManager?.authHeader() ?? ""]) {
                await MainActor.run {
                    self.artwork = image
                    self.updateNowPlaying()
                }
            }
        }
    }

    private func unregisterProcessors() {
        detachMix(from: playerA)
        detachMix(from: playerB)
        if let p = processorA { Task { @MainActor in EQManager.shared.unregister(p) } }
        if let p = processorB { Task { @MainActor in EQManager.shared.unregister(p) } }
        processorA = nil
        processorB = nil
    }

    /// Detach the tap-bearing audioMix from the item on `player` BEFORE we drop
    /// our Swift reference to the AudioProcessor that owns the tap. Clearing the
    /// mix makes AVFoundation finalize the tap (firing tapFinalizeCallback ->
    /// release) rather than leaving the audio render thread calling process() on
    /// a soon-to-be-freed processor — the rapid-track-change / crossfade crash.
    private func detachMix(from player: AVPlayer) {
        if let item = player.currentItem, item.audioMix != nil {
            item.audioMix = nil
        }
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

        // Re-validate: the queue can shrink (CarPlay/queue edit) between the
        // bounds check above and here. Reset crossfadeStartedFor so the normal
        // end-of-track next() still fires instead of the track hanging.
        guard queue.indices.contains(nextIndex) else {
            crossfadeStartedFor = nil
            return
        }
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
        detachMix(from: activePlayer)   // finalize the outgoing item's tap before releasing it
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

    // MARK: - Next-track preload
    //
    // AVPlayer's first read of a remote AVURLAsset includes the HTTP open,
    // track enumeration, and initial buffer fill — easily 1–2 seconds of
    // silence on cellular. We avoid that gap by preparing the next item's
    // asset in memory once the current track is past a small threshold,
    // then handing the warmed asset to loadCurrent when the user advances.

    /// Up to `count` upcoming playable (non-ignored) queue indices,
    /// respecting repeat mode. Used for warming N tracks ahead.
    private func upcomingPlayableIndices(count: Int) -> [Int] {
        guard !queue.isEmpty, count > 0 else { return [] }
        let isIgnored: (BaseItem) -> Bool = { item in
            MainActor.assumeIsolated { IgnoredTracksStore.shared.isIgnored(item.Id) }
        }
        var out: [Int] = []
        var probe = currentIndex + 1
        while probe < queue.count, out.count < count {
            if !isIgnored(queue[probe]) { out.append(probe) }
            probe += 1
        }
        if out.count < count && repeatMode == .all {
            // Wrap to the front, skipping anything ignored or the current index.
            for idx in 0..<queue.count {
                if out.count >= count { break }
                if idx == currentIndex { continue }
                if isIgnored(queue[idx]) { continue }
                out.append(idx)
            }
        }
        return out
    }

    /// Build (or reuse) warmed URL assets for the next `preloadDepth`
    /// queue items so Next / end-of-track can swap to a primed asset
    /// instead of opening the URL from scratch. Trims any cached asset
    /// for tracks that have fallen outside the upcoming window
    /// (e.g. user skipped multiple times, queue was rebuilt).
    private func preloadNextIfNeeded() {
        guard currentTime >= 3 else { return }
        let upcoming = upcomingPlayableIndices(count: preloadDepth)
        let upcomingIds = Set(upcoming.map { queue[$0].Id })

        // Evict warmed assets no longer in the upcoming window.
        for id in preloadedAssets.keys where !upcomingIds.contains(id) {
            preloadedAssets.removeValue(forKey: id)
        }
        // Warm any upcoming track not already cached.
        for idx in upcoming {
            let item = queue[idx]
            if preloadedAssets[item.Id] != nil { continue }
            let url: URL
            if let local = DownloadManager.shared.localFileURL(for: item.Id) {
                url = local
            } else if let client = client {
                url = client.audioStreamURL(for: item.Id)
            } else { continue }
            let opts: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            let asset = AVURLAsset(url: url, options: opts)
            preloadedAssets[item.Id] = asset
            // Kick off async key load so playable/tracks/duration land
            // before the user actually advances.
            asset.loadValuesAsynchronously(forKeys: ["playable", "tracks", "duration"]) { }
        }
    }

    /// Hand back the warmed asset for `item` and remove it from the
    /// cache. loadCurrent uses this so it doesn't have to open the URL
    /// from scratch.
    fileprivate func consumePreloadedAsset(for item: BaseItem) -> AVURLAsset? {
        return preloadedAssets.removeValue(forKey: item.Id)
    }

    // MARK: - Observation

    private func addTimeObserver() {
        // 0.5s is plenty for progress bar updates + scrobble/crossfade
        // bookkeeping; the original 0.1s cadence fired tick() on the
        // main runloop 20×/sec (10 per player) which competed with
        // UIKit's scroll handler and caused visible list jitter during
        // playback.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 10)
        timeObserver = playerA.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            self?.tick()
        }
        // Second observer on player B so we still get updates after a crossfade swap.
        _ = playerB.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
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
        preloadNextIfNeeded()
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
            interruptedWhilePlaying = isPlaying
            print("[AudioPlayer] interruption began (wasPlaying=\(isPlaying))")
            pause()
        case .ended:
            // The system deactivated our session during the interruption.
            // Reactivate BEFORE resuming — otherwise the player advances
            // (progress bar moves) but stays silent. Reactivate even when we
            // don't auto-resume so the next manual play has audio.
            reactivateSession()
            let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            print("[AudioPlayer] interruption ended (shouldResume=\(opts.contains(.shouldResume)), wasPlaying=\(interruptedWhilePlaying))")
            if interruptedWhilePlaying && opts.contains(.shouldResume) { play() }
            interruptedWhilePlaying = false
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        guard let info = note.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            // Output device (CarPlay / Bluetooth / headphones) went away —
            // pause rather than blast audio out the phone speaker. Quiescing
            // the render thread here also narrows the tap-teardown window.
            print("[AudioPlayer] route change: oldDeviceUnavailable → pause")
            pause()
        default:
            // .newDeviceAvailable / .categoryChange / .override /
            // .routeConfigurationChange — keep playing; the engine reconfigures
            // for the new route itself.
            print("[AudioPlayer] route change: reason \(reason.rawValue) (keep playing)")
            break
        }
    }

    /// The audio server restarted (mediaservicesd reset): the session, both
    /// AVPlayers' items, and the tap are all invalid now. Reconfigure the
    /// session and rebuild the current item so we don't sit "playing" against a
    /// dead engine — silent, with the progress bar still ticking.
    @objc private func handleMediaReset(_ note: Notification) {
        print("[AudioPlayer] media services were reset — reconfiguring + reloading")
        configureAudioSession()
        preloadedAssets.removeAll()
        let resume = isPlaying
        loadCurrent(autoplay: resume)
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
        // Show previous/next TRACK buttons in CarPlay Now Playing, not the
        // ±15s seconds-skip buttons. When the skip-interval commands are
        // enabled CarPlay renders those instead of track skip, so disable them.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
    }

    private func updateNowPlaying() {
        guard let item = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.Name,
            MPMediaItemPropertyArtist: item.primaryArtistName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            // Without an explicit media type, CarPlay falls back to a
            // generic layout where the title can wrap onto a second line
            // and overlap the artist row. Declaring audio gives us the
            // music-tuned three-line layout (title / artist / album)
            // with proper truncation.
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        // Only include the album title when it actually has content —
        // setting an empty string makes CarPlay's Now Playing template
        // reserve space for it, which causes the artist line to overlap
        // the title when the layout collapses around a blank album row.
        if let album = item.Album, !album.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let artwork = artwork {
            // Advertise a large canonical bounds (CarPlay + lock screen
            // both render up to ~600pt); we still hand back the same
            // image and let UIKit downsample. Without this the system
            // sometimes asked for a size we didn't advertise and skipped
            // showing artwork at all in CarPlay's Now Playing template.
            let bounds = CGSize(width: 600, height: 600)
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: bounds) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // CarPlay's Now Playing template watches `playbackState` directly
        // for the play/pause glyph — the `PlaybackRate` in the info dict
        // is not enough on iOS 13+, the button stays stuck on "play"
        // mid-playback unless we publish the explicit state too.
        #if canImport(UIKit) && !os(watchOS)
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
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
