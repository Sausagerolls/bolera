import Foundation
import AVFoundation
import MediaPlayer
import Combine
import Network
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

public enum RepeatMode: Int {
    case off, all, one
}

/// The high-frequency playback position (updated ~2×/sec) lives on its own
/// tiny observable. Views that show a scrubber observe THIS; everything else
/// observes `AudioPlayer`, so a track's elapsed time no longer forces the
/// whole now-playing screen (and anything it presents) to re-render twice a
/// second — that 2Hz churn was pulsing the Queue sheet's menu.
public final class PlaybackClock: ObservableObject {
    @Published public internal(set) var currentTime: Double = 0
}

/// Owns the play QUEUE and everything around playback: Now Playing, artwork,
/// scrobbling, queue persistence and the remote-command surface. The audio
/// itself — the AVPlayer, the current item and the playhead — belongs to
/// `PlaybackEngine`; this type never touches them directly.
/// Installs an `MTAudioProcessingTap` per item for real-time EQ + visualizer
/// levels, prefers locally downloaded files, and keeps
/// `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` in sync so lock screen /
/// Control Center / AirPlay / CarPlay all work.
public final class AudioPlayer: NSObject, ObservableObject {
    public static let shared = AudioPlayer()

    /// True while audio is currently routing to CarPlay. Read synchronously when
    /// building a stream URL so an optional CarPlay-specific bitrate can apply
    /// (a lower, reliable rate for driving through patchy signal). Updated on
    /// every route change + at session setup + on foreground. macOS: always false.
    public nonisolated(unsafe) static var isCarPlayActive = false

    @Published public private(set) var queue: [BaseItem] = []
    @Published public private(set) var currentIndex: Int = 0
    @Published public private(set) var isPlaying: Bool = false
    /// True while the current item is stalled buffering (timeControlStatus ==
    /// .waitingToPlayAtSpecifiedRate) — playback is intended but audio is
    /// waiting on data. Lets the UI show a spinner instead of a frozen bar.
    @Published public private(set) var isBuffering: Bool = false
    /// Not @Published — observing AudioPlayer no longer re-renders a view
    /// every tick. The published mirror lives on `clock` for the scrubber.
    public private(set) var currentTime: Double = 0 {
        didSet { clock.currentTime = currentTime }
    }
    /// Observe this (not AudioPlayer) for the playback position.
    public let clock = PlaybackClock()
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var artwork: PlatformImage?
    @Published public var shuffle: Bool = false {
        didSet { UserDefaults.standard.set(shuffle, forKey: "bolera.shuffle") }
    }
    @Published public var repeatMode: RepeatMode = .off {
        didSet { UserDefaults.standard.set(repeatMode.rawValue, forKey: "bolera.repeat") }
    }

    public var current: BaseItem? {
        guard queue.indices.contains(currentIndex) else { return nil }
        return queue[currentIndex]
    }

    /// Pre-shuffle order, used to restore when shuffle is turned off.
    private var originalQueue: [BaseItem] = []

    /// The playback engine owns the AVPlayer, the current item and the playhead.
    /// AudioPlayer no longer touches any of them directly — it owns the QUEUE and
    /// the metadata around playback (Now Playing, artwork, scrobbling, persistence)
    /// and drives the engine. See PlaybackEngine for why this split exists.
    private let engine = PlaybackEngine()
    /// Read-only alias for the incidental places that need the AVPlayer itself
    /// (HTTP forensics, route/interruption checks). Never used to attach audio.
    private var activePlayer: AVPlayer { engine.avPlayer }
    private var processor: AudioProcessor?

    /// Whether playback was active when an audio-session interruption began, so
    /// we know to resume (and reactivate the session) when it ends.
    private var interruptedWhilePlaying = false
    /// True only while playback is paused BY an interruption (call / nav prompt)
    /// and the user hasn't since touched transport. Lets interruption-ended
    /// auto-resume without resuming over a pause the user made during the call.
    private var pausedByInterruption = false

    /// Pre-loaded AVURLAssets for upcoming queue items, keyed by track Id.
    /// Kept in memory so a Next press / natural end-of-track can swap to
    /// the next track instantly without an HTTP open + initial buffer
    /// stall. We warm the next `preloadDepth` items in the queue.
    private var preloadedAssets: [String: AVURLAsset] = [:]
    /// How many upcoming tracks to warm ahead of the current one. Bumped to 5
    /// so a run of dead spots while driving doesn't catch the queue cold.
    private let preloadDepth = 5

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

    // Now Playing widget change-detection. `updateNowPlaying()` runs on every
    // 0.5s tick, but the widget only needs a fresh snapshot (+ a timeline
    // reload) when something it shows as discrete state changes: the track,
    // play/pause, presence of a track, or the cover finishing its async load.
    // Comparing against these last-published values turns the per-tick calls
    // into no-ops and prevents a reloadAllTimelines() storm.
    private var lastWidgetTrackId: String?
    private var lastWidgetIsPlaying: Bool?
    private var lastWidgetHasTrack: Bool?
    private var lastWidgetHadArtwork: Bool?

    /// Delays the Jellyfin "playback started" report so a quick skip (track
    /// changed within `startReportDelay`) never registers the track as played —
    /// keeps drive-by skips out of Recently Played / Recent Albums. Cancelled
    /// and rescheduled on every track change.
    private var reportStartTask: Task<Void, Never>?
    private let startReportDelay: TimeInterval = 2.0

    /// The user's playback INTENT, distinct from `isPlaying` (which is briefly
    /// false during a hard item failure / pause transition). Recovery is gated
    /// on intent so a transient failure doesn't latch playback off.
    private var userWantsPlayback = false
    /// Throttle for `dumpItemLogs` so a stall burst (3–4 events in the same
    /// second) writes AVPlayer's HTTP forensics once, not once per event.
    private var lastItemLogDumpAt: Date = .distantPast
    /// Access-log event count seen for the current item at the last check.
    /// A mid-play increase = AVPlayer opened a fresh HTTP connection for the
    /// same item (the moment a byte-mapping desync can occur) — logged in tick.
    private var lastAccessEventCount = 0

    /// Position the restored (last-session) queue should resume from on the
    /// FIRST play. The queue is restored paused with no AVPlayer item attached
    /// (no launch streaming, Plexamp-style); the actual stream opens + seeks here
    /// only when the user presses play. Consumed by loadCurrent.
    private var pendingRestorePosition: Double?
    /// Serializes the (potentially large) queue snapshot writes off the main
    /// thread so persisting never janks playback.
    private let persistQueue = DispatchQueue(label: "com.bolera.playqueue.persist", qos: .utility)
    private static let queueStateURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("bolera.playqueue.json")
    }()

    // Instant network-restored recovery. Watches the path directly (independent
    // of ConnectivityStore, which only flips on a failed API request — a pure
    // streaming stall often leaves it thinking it's still "online"). The moment
    // the path is usable again we kick a stalled stream rather than waiting out
    // the backoff. Belt-and-suspenders with the ConnectivityStore.didReconnect
    // subscription (fires when the server itself answers again) and foreground.
    #if canImport(UIKit)
    private let audioNetMonitor = NWPathMonitor()
    private let audioNetQueue = DispatchQueue(label: "com.bolera.audio.netmonitor")
    private var lastNetSatisfied = true
    /// Last seen path cost, so a Wi-Fi↔cellular flip can drop assets warmed
    /// under the old conditions (a Wi-Fi-warmed full-quality FLAC must not be
    /// streamed over cellular).
    private var lastNetExpensive = false
    private var reconnectCancellable: AnyCancellable?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    #endif

    /// How far ahead to buffer. A generous forward buffer means short dead spots
    /// (tunnels, rural gaps) are covered by already-downloaded audio and never
    /// even register as a stall — the single biggest "seamless" lever for music.
    private let forwardBufferSeconds: Double = 120
    /// Minimum audio (seconds) buffered ahead before we START a fresh METERED
    /// stream. Jellyfin's progressive transcode (`universal` endpoint, used for
    /// any source above the cellular bitrate ceiling) has a cold ffmpeg ramp:
    /// AVPlayer's own keep-up heuristic sees the fast header bytes, starts, then
    /// underruns a few seconds in when the throttled transcode can't keep up —
    /// the "played a few seconds, stalled, waited, then normal" drive hiccup.
    /// Holding the first play() until a real buffer exists turns that into one
    /// slightly-longer initial wait, then smooth playback. Direct streams (LAN /
    /// local file) skip the gate — they fill instantly and never cold-ramp.
    private let startBufferSeconds: Double = 12
    /// Hard cap on the start-buffer wait so a slow link can't hang playback
    /// forever — past this we play with whatever's buffered (recovery handles
    /// the rest, same as before this gate existed).
    private let startBufferTimeout: TimeInterval = 12

    /// Consecutive endless-mix top-ups that returned nothing. A single empty
    /// result is usually a transient network failure (driving through a dead
    /// spot), not a genuinely tapped-out artist — so we only stop extending
    /// after several empties in a row instead of latching on the first.
    private var extenderEmptyStreak = 0
    private let maxExtenderEmptyStreak = 3

    public override init() {
        super.init()
        // Keep AVPlayer's default pre-buffering (automaticallyWaitsToMinimize-
        // Stalling = true). The engine's stall diagnostics pinpoint the real
        // cause of any mid-track buffering rather than disabling pre-buffer.
        shuffle = UserDefaults.standard.bool(forKey: "bolera.shuffle")
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "bolera.repeat")) ?? .off
        // Stamp the running build into the log — a pulled log must be
        // attributable to a build (48's forensics were silent and we couldn't
        // tell "no events" from "old build without the logging").
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        DebugLog.write("[App] Bolera \(v) (build \(b)) started")
        bindEngine()
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
        // Recover a stalled stream the instant the network path becomes usable
        // again (out of a dead spot / tunnel / cellular handoff) and on app
        // foreground — without waiting for the backoff timer.
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)
        audioNetMonitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive || path.isConstrained
            DispatchQueue.main.async {
                guard let self else { return }
                let wasSatisfied = self.lastNetSatisfied
                self.lastNetSatisfied = satisfied
                if expensive != self.lastNetExpensive {
                    self.lastNetExpensive = expensive
                    // Cost flipped (left Wi-Fi for cellular, or back). Drop assets
                    // warmed under the old conditions so upcoming tracks reopen at
                    // the right bitrate — a Wi-Fi-warmed FLAC streamed over
                    // cellular is exactly what stalled the 4th track silently.
                    if !self.preloadedAssets.isEmpty {
                        self.preloadedAssets.removeAll()
                        DebugLog.write("[AudioPlayer] path expensive=\(expensive) — cleared \(expensive ? "Wi-Fi-warmed" : "cellular-warmed") assets")
                    }
                }
                // Only FORCE a reload when the network genuinely came back after
                // being lost (dead zone / tunnel). On a Wi-Fi→cellular HANDOFF
                // (was satisfied, still satisfied, just a different interface),
                // do NOT reload — AVPlayer fails over to the new interface itself
                // and keeps playing from its buffer. Force-reopening there is what
                // re-buffered (and sometimes restarted) the track on the drive.
                // A genuine handoff stall that doesn't self-heal is still caught
                // by the stall watchdog / timeControl recovery (patiently).
                if satisfied && !wasSatisfied { self.engine.recoverNow(reason: "network restored") }
            }
        }
        audioNetMonitor.start(queue: audioNetQueue)
        // The server answering a connectivity probe again is the most precise
        // "resume now" signal for a LAN-only server reachable via a tunnel.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reconnectCancellable = ConnectivityStore.shared.didReconnect
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.engine.recoverNow(reason: "server reconnected") }
        }
        #endif
        // Persist the play queue when the app backgrounds / resigns / quits, so
        // the next launch can resume (paused) where the user left off.
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWillBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        #elseif canImport(AppKit)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWillBackground),
                                               name: NSApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWillBackground),
                                               name: NSApplication.willTerminateNotification, object: nil)
        #endif
    }

    // MARK: - Session

    public func configureAudioSession() {
        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        // Set the category independently of activation: getting .playback set is
        // what matters for background audio; if activation fails we don't want it
        // to also skip the category.
        do {
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
        } catch {
            DebugLog.write("[AudioPlayer] setCategory failed: \(error)")
        }
        do {
            try session.setActive(true)
        } catch {
            // -50 (param error) can hit if we activate too early / while another
            // app holds the session. Don't leave it dead — retry shortly; the
            // category is already correct so playback will route once active.
            DebugLog.write("[AudioPlayer] setActive failed: \(error) — retrying in 0.5s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                do { try AVAudioSession.sharedInstance().setActive(true) }
                catch { DebugLog.write("[AudioPlayer] setActive retry failed: \(error)") }
            }
        }
        refreshCarPlayRoute()
        #endif
    }

    /// Update `isCarPlayActive` from the current audio route. Cheap; called on
    /// route changes, session setup, and foreground so the CarPlay-bitrate
    /// decision in `playbackStreamURL` always reflects the live route.
    private func refreshCarPlayRoute() {
        #if canImport(UIKit)
        let carplay = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .carAudio }
        if carplay != Self.isCarPlayActive {
            Self.isCarPlayActive = carplay
            DebugLog.write("[AudioPlayer] CarPlay route \(carplay ? "connected" : "disconnected")")
        }
        #endif
    }

    // MARK: - Queue control

    public func play(items: [BaseItem], startAt index: Int = 0) {
        guard !items.isEmpty else { return }
        queueExtender = nil          // a plain play isn't an endless mix
        extenderExhausted = false
        extenderEmptyStreak = 0
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
        loadCurrent(autoplay: true, trigger: "setQueue")
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
                // Nothing new this round. Could be a tapped-out artist OR a
                // transient network failure (the extender returns [] on error).
                // Only give up after several empties in a row so one dead spot
                // while driving doesn't kill the mix for the whole session.
                self.extenderEmptyStreak += 1
                if self.extenderEmptyStreak >= self.maxExtenderEmptyStreak {
                    self.extenderExhausted = true
                }
                return
            }
            self.extenderEmptyStreak = 0
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
                loadCurrent(autoplay: true, trigger: "removeCurrent")
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
        publishWidgetSnapshot()
        clearPersistedQueue()
    }

    // MARK: - Transport

    public func togglePlayPause() { isPlaying ? pause() : play() }

    public func play() {
        guard !queue.isEmpty else { return }
        userWantsPlayback = true
        pausedByInterruption = false   // user took manual control
        // No stream attached — open one and resume where we left off.
        //
        // This is NOT only the first-play-after-restore case it was written for.
        // `pendingRestorePosition` is consumed (set to nil) by loadCurrent, so it
        // is non-nil for exactly one play per launch; any LATER teardown of the
        // player item (media-services reset, a failed item cleared, the system
        // reclaiming it) leaves it nil. Resuming on nil restarts the current track
        // from 0:00 while the user only pressed Play — the "it jumped back to the
        // beginning of the same song" report. Fall back to the live position.
        // Ask the ENGINE to resume. It returns false only when no item is
        // attached, which is the one case that needs a reopen — and that reopen
        // must state a position, or it restarts the song from 0:00.
        //
        // Going straight to `activePlayer.play()` here (as this did immediately
        // after the migration) also desynced the engine: its `wantsPlayback`
        // stayed false, so a later stall was classified as a deliberate pause and
        // recovery never armed.
        if engine.play() {
            isPlaying = true
            updateNowPlaying()
            reportProgress(event: "unpause", paused: false)
            return
        }
        let resume = pendingRestorePosition ?? (currentTime > 1 ? currentTime : nil)
        DebugLog.write("[AudioPlayer] play() with no item — reopening '\(current?.Name ?? "?")' at \(Int(resume ?? 0))s (pendingRestore=\(pendingRestorePosition.map { String(Int($0)) } ?? "nil") currentTime=\(Int(currentTime))s)")
        loadCurrent(autoplay: true, resumeAt: resume, trigger: "playWithNoItem")
    }

    public func pause() {
        engine.pause()
        isPlaying = false
        isBuffering = false
        userWantsPlayback = false
        pausedByInterruption = false
        updateNowPlaying()
        reportProgress(event: "pause", paused: true)
        persistPlaybackState()   // capture the paused position for next launch
    }

    public func stop() {
        userWantsPlayback = false
        pausedByInterruption = false
        reportStartTask?.cancel()
        if let current = current {
            Task { try? await reportStop(item: current) }
        }
        engine.stop()
        unregisterProcessors()
        isPlaying = false
        isBuffering = false
        currentTime = 0
        duration = 0
        // Keep `artwork`: stop() leaves `current` set (the Now Playing screen
        // still shows the last track), so blanking the cover here left a track
        // with a placeholder image until the user pressed play.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        publishWidgetSnapshot()
        persistPlaybackState()
    }

    public func next() { next(trigger: "userNext") }

    /// `trigger` separates a deliberate skip from an automatic end-of-track
    /// advance in the log — without it a track that ended early and a track the
    /// user skipped look identical, which is why the 2026-08-07 "it changed
    /// track by itself" report couldn't be settled from the log.
    func next(trigger nextTrigger: String) {
        if repeatMode == .one {
            loadCurrent(autoplay: true, resumeAt: 0, trigger: "repeatOne")
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
                loadCurrent(autoplay: true, trigger: nextTrigger)
                return
            }
            probe += 1
        }
        if repeatMode == .all {
            // Wrap to first non-ignored track.
            for idx in 0..<queue.count {
                if !isIgnored(queue[idx]) {
                    currentIndex = idx
                    loadCurrent(autoplay: true, trigger: nextTrigger + "/wrap")
                    return
                }
            }
        }
        stop()
    }

    public func previous() {
        // The "restart current track if >3s in" gesture only applies to a track
        // that's actually playing — on a restored-but-not-yet-played queue the
        // position is pre-seeded, so a Previous tap should go to the prior track.
        if activePlayer.currentItem != nil, currentTime > 3 {
            seek(to: 0); return
        }
        if currentIndex > 0 {
            currentIndex -= 1
            loadCurrent(autoplay: true, trigger: "previous")
        } else {
            seek(to: 0)
        }
    }

    public func seek(to seconds: Double) {
        let target = max(0, seconds)
        // No stream attached yet (restored-but-not-played queue): remember where
        // to resume and reflect it in the UI; the stream opens on first play.
        if !engine.hasItem {
            currentTime = target
            pendingRestorePosition = target
            return
        }
        currentTime = target
        // The engine returns false when the target isn't reachable inside the
        // attached stream (a mid-track transcode ignores byte-Range), in which
        // case the only correct move is to reopen AT that position.
        if !engine.seek(to: target) {
            loadCurrent(autoplay: userWantsPlayback, resumeAt: target, trigger: "seekReopen")
            return
        }
        reportProgress(event: "timeupdate", paused: !isPlaying)
    }

    public func jumpTo(index: Int) {
        guard queue.indices.contains(index) else { return }
        currentIndex = index
        loadCurrent(autoplay: true, trigger: "jumpTo")
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

    /// Attach `current` and start at `resumeAt` (nil = the beginning).
    ///
    /// This is the ONLY place audio is attached, and it always hands the engine
    /// an explicit start position. `trigger` records WHY, so a user skip and an
    /// app-initiated change are distinguishable in the log.
    private func loadCurrent(autoplay: Bool, resumeAt: Double? = nil, isRecovery: Bool = false,
                             trigger: String = "?") {
        guard let item = current else { return }
        pendingRestorePosition = nil          // consumed (or superseded)
        if autoplay { userWantsPlayback = true }

        let start = resumeAt ?? 0
        DebugLog.write("[AudioPlayer] load '\(item.Name)' trigger=\(trigger) idx=\(currentIndex)/\(queue.count) startAt=\(Int(start))s")

        // Fresh AudioProcessor + tap for this item; retire the previous one.
        let proc = AudioProcessor()
        Task { @MainActor in EQManager.shared.register(proc) }
        if let old = processor {
            detachMix(from: engine.avPlayer)
            Task { @MainActor in EQManager.shared.unregister(old) }
        }
        processor = proc

        duration = item.durationSeconds
        artwork = nil
        trackStartedAt = Date()
        hasScrobbledCurrent = false
        hasUpdatedNowPlayingCurrent = false
        lastAccessEventCount = 0

        engine.open(trackId: item.Id,
                    duration: item.durationSeconds,
                    startAt: start,
                    autoplay: autoplay,
                    localURL: DownloadManager.shared.localFileURL(for: item.Id),
                    bitrateCap: nil,
                    reason: trigger)

        loadArtwork(for: item)
        updateNowPlaying()
        scheduleStartReport(for: item)
        Task { @MainActor in await LastFmService.shared.updateNowPlaying(item); hasUpdatedNowPlayingCurrent = true }
        maybeExtendQueue()       // endless-mix: top up the queue as it nears the end
        persistPlaybackState()   // remember the queue + new track for next launch
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
        detachMix(from: engine.avPlayer)
        if let p = processor { Task { @MainActor in EQManager.shared.unregister(p) } }
        processor = nil
    }

    /// Detach the tap-bearing audioMix from the item on `player` BEFORE we drop
    /// our Swift reference to the AudioProcessor that owns the tap. Clearing the
    /// mix makes AVFoundation finalize the tap (firing tapFinalizeCallback ->
    /// release) rather than leaving the audio render thread calling process() on
    /// a soon-to-be-freed processor — the rapid-track-change crash.
    private func detachMix(from player: AVPlayer) {
        if let item = player.currentItem, item.audioMix != nil {
            item.audioMix = nil
        }
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
        // Start warming after a 1s lead (was 3s) — soon enough to be ready for
        // dead spots, late enough that the current track's own initial buffer
        // gets priority instead of competing with N simultaneous opens.
        guard currentTime >= 1 else { return }
        // Don't open N upcoming streams while the current one is fighting to
        // recover — they'd just steal bandwidth from the reopen on a bad link.
        guard engine.state != .stalled else { return }
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
                url = client.playbackStreamURL(for: item.Id)
            } else { continue }
            let opts: [String: Any] = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
            let asset = AVURLAsset(url: url, options: opts)
            preloadedAssets[item.Id] = asset
            // Kick off async key load so playable/tracks/duration land
            // before the user actually advances.
            asset.loadValuesAsynchronously(forKeys: ["playable", "tracks", "duration"]) { }
            // Also prefetch the artwork (same 600px the player uses) into the
            // persistent ImageCache so the cover is ready BEFORE the track plays
            // — otherwise driving into a dead spot leaves the next track's art
            // blank. Fires once per track (gated by the warmed-asset check above).
            if let client = client {
                let headers = ["Authorization": authManager?.authHeader() ?? ""]
                let artId = item.artworkItemId, tag = item.artworkTag
                Task.detached {
                    _ = await ImageCache.shared.loadArtwork(itemId: artId, tag: tag,
                                                            client: client, maxWidth: 600,
                                                            headers: headers)
                }
            }
        }
    }

    /// Hand back the warmed asset for `item` and remove it from the
    /// cache. loadCurrent uses this so it doesn't have to open the URL
    /// from scratch.
    fileprivate func consumePreloadedAsset(for item: BaseItem) -> AVURLAsset? {
        return preloadedAssets.removeValue(forKey: item.Id)
    }

    // MARK: - Observation

    /// Wire the engine's callbacks into the queue/metadata layer. The engine is
    /// the sole source of the playhead — nothing here computes position.
    private func bindEngine() {
        engine.makeStream = { [weak self] trackId, startAt, cap in
            guard let self, let client = self.client else {
                return PlaybackEngine.Stream(url: URL(fileURLWithPath: "/dev/null"), offset: 0)
            }
            let s = client.playbackStream(for: trackId, maxBitrateOverride: cap,
                                          startTimeSeconds: startAt)
            return PlaybackEngine.Stream(url: s.url, offset: s.timelineOffset)
        }
        engine.attachProcessor = { [weak self] player, item in
            guard let self, let proc = self.processor,
                  let asset = item.asset as? AVURLAsset else { return }
            self.installTapAsync(processor: proc, asset: asset, on: item) { }
        }
        engine.detachProcessor = { [weak self] player in
            self?.detachMix(from: player)
        }
        engine.onPosition = { [weak self] pos in
            guard let self else { return }
            self.currentTime = pos
            self.onPositionAdvanced()
        }
        engine.onDuration = { [weak self] d in
            guard let self, d.isFinite, d > 0 else { return }
            self.duration = d
        }
        engine.onEndedNaturally = { [weak self] in
            self?.next(trigger: "endOfTrack")
        }
        engine.onState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .playing:
                self.isPlaying = true;  self.isBuffering = false
            case .opening, .stalled:
                self.isPlaying = self.userWantsPlayback
                self.isBuffering = true
            case .paused, .idle:
                self.isPlaying = false; self.isBuffering = false
            case .failed:
                self.isPlaying = false; self.isBuffering = false
            }
            self.updateNowPlaying()
        }
    }

    /// Per-position housekeeping: Now Playing, scrobbling, preload. Position
    /// itself is already set by the engine before this runs.
    private func onPositionAdvanced() {
        updateNowPlaying()
        if let cur = current, !hasScrobbledCurrent {
            let half = duration * 0.5
            let cutoff = min(half, 240)
            if duration > 30, currentTime >= cutoff, let startedAt = trackStartedAt {
                hasScrobbledCurrent = true
                Task { @MainActor in await LastFmService.shared.scrobble(cur, startedAt: startedAt) }
            }
        }
        preloadNextIfNeeded()
        // Throttled Jellyfin progress ping (the old tick did this inline).
        if Date().timeIntervalSince(lastProgressReport) > 10 {
            reportProgress(event: "timeupdate", paused: !isPlaying)
        }
    }

    /// Write AVPlayer's internal per-stream HTTP diagnostics (access + error
    /// logs) into the debug log. These capture what the app's own logging
    /// can't see: every connection the player opened, response codes, server
    /// switches and byte counts — the ground truth for a mid-song desync
    /// (e.g. a mid-file reconnect answered from byte 0 instead of 206).
    /// Called only on stall/failure events and throttled to one dump per 5s.
    private func dumpItemLogs(_ item: AVPlayerItem, context: String, force: Bool = false) {
        if !force {
            guard Date().timeIntervalSince(lastItemLogDumpAt) > 5 else { return }
        }
        lastItemLogDumpAt = Date()
        let accessEvents = item.accessLog()?.events ?? []
        let errorEvents = item.errorLog()?.events ?? []
        // ALWAYS write the summary — an item with ZERO access events never got
        // a connection at all, which is exactly the kind of fact we're hunting.
        // (Build 48 silently wrote nothing for empty logs; that silence was
        // indistinguishable from the dump not running.)
        let t = CMTimeGetSeconds(item.currentTime())
        DebugLog.write("[AVLog] \(context) access=\(accessEvents.count) error=\(errorEvents.count) itemTime=\(t.isFinite ? String(Int(t)) : "nan")s shownTime=\(Int(currentTime))s")
        for e in accessEvents.suffix(3) {
            let uri = e.uri.flatMap(URL.init(string:)).map(DebugLog.redacted) ?? "?"
            DebugLog.write("[AVLog] \(context) access uri=\(uri) server=\(e.serverAddress ?? "?") addrChanges=\(e.numberOfServerAddressChanges) bytes=\(e.numberOfBytesTransferred) stalls=\(e.numberOfStalls) watched=\(Int(e.durationWatched))s transfer=\(String(format: "%.1f", e.transferDuration))s")
        }
        for e in errorEvents.suffix(5) {
            DebugLog.write("[AVLog] \(context) error status=\(e.errorStatusCode) domain=\(e.errorDomain) comment=\(e.errorComment ?? "-") server=\(e.serverAddress ?? "?")")
        }
    }

    #if canImport(UIKit)
    @objc private func handleDidBecomeActive() {
        refreshCarPlayRoute()
        // The engine decides whether this is a genuinely dead stream; a healthy
        // buffer is left alone (reopening one is what restarted the track).
        engine.recoverNow(reason: "app foregrounded")
    }
    private func beginBackgroundTaskIfNeeded() {
        guard bgTask == .invalid else { return }
        // The expiration handler is invoked by UIKit on an arbitrary thread —
        // hop to main so all bgTask mutations stay single-threaded.
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "bolera.stallRecovery") { [weak self] in
            DispatchQueue.main.async { self?.endBackgroundTaskIfNeeded() }
        }
    }
    private func endBackgroundTaskIfNeeded() {
        guard bgTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTask)
        bgTask = .invalid
    }
    #else
    @objc private func handleDidBecomeActive() {}
    private func beginBackgroundTaskIfNeeded() {}
    private func endBackgroundTaskIfNeeded() {}
    #endif

    #if canImport(UIKit)
    @objc private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeRaw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            interruptedWhilePlaying = isPlaying
            DebugLog.write("[AudioPlayer] interruption began (wasPlaying=\(isPlaying))")
            pause()                                  // clears pausedByInterruption…
            pausedByInterruption = interruptedWhilePlaying   // …then mark WE paused it
        case .ended:
            // The system deactivated our session during the interruption. Full
            // reconfigure BEFORE resuming — otherwise the player advances
            // (progress bar moves) but stays silent.
            configureAudioSession()
            let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            DebugLog.write("[AudioPlayer] interruption ended (shouldResume=\(opts.contains(.shouldResume)), pausedByInterruption=\(pausedByInterruption))")
            // Resume only if WE paused it for the interruption and the user hasn't
            // manually paused/played during the call — even WITHOUT .shouldResume,
            // which iOS often omits (that omission used to latch music off after a
            // nav prompt). A manual pause during the call clears the flag, so we
            // honour it and stay paused.
            if pausedByInterruption { play() }
            interruptedWhilePlaying = false
            pausedByInterruption = false
        @unknown default: break
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        refreshCarPlayRoute()   // keep the CarPlay-bitrate flag current on any route change
        guard let info = note.userInfo,
              let reasonRaw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            // Output device (CarPlay / Bluetooth / headphones) went away —
            // pause rather than blast audio out the phone speaker. Quiescing
            // the render thread here also narrows the tap-teardown window.
            DebugLog.write("[AudioPlayer] route change: oldDeviceUnavailable → pause")
            pause()
        default:
            // .newDeviceAvailable / .categoryChange / .override /
            // .routeConfigurationChange — keep playing; the engine reconfigures
            // for the new route itself.
            DebugLog.write("[AudioPlayer] route change: reason \(reason.rawValue) (keep playing)")
            break
        }
    }

    /// The audio server restarted (mediaservicesd reset): the session, both
    /// AVPlayers' items, and the tap are all invalid now. Reconfigure the
    /// session and rebuild the current item so we don't sit "playing" against a
    /// dead engine — silent, with the progress bar still ticking.
    @objc private func handleMediaReset(_ note: Notification) {
        let resumeAt = currentTime
        DebugLog.write("[AudioPlayer] media services were reset — reconfiguring + reloading at \(Int(resumeAt))s")
        configureAudioSession()
        preloadedAssets.removeAll()
        let resume = isPlaying || userWantsPlayback
        // Resume at the position we were at — a media-services reset must NOT
        // restart the track from 0:00 (it did, which is one cause of the
        // "song restarted" oddity heard while driving).
        loadCurrent(autoplay: resume, resumeAt: resumeAt > 1 ? resumeAt : nil, trigger: "mediaServicesReset")
    }
    #endif

    // MARK: - Now Playing / Remote Commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        center.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        // Tagged separately from an in-app skip: this is the CarPlay / lock-screen
        // button, the one that matters for "did the head unit skip, or did we?".
        center.nextTrackCommand.addTarget { [weak self] _ in self?.next(trigger: "remoteNext"); return .success }
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
        // Use the REAL playback rate (0 while stalled buffering), not just the
        // intent — otherwise the system extrapolates elapsed time from rate 1.0
        // and the lock-screen progress keeps advancing while audio is stalled.
        let activelyPlaying = (activePlayer.timeControlStatus == .playing)
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.Name,
            MPMediaItemPropertyArtist: item.primaryArtistName,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: activelyPlaying ? 1.0 : 0.0,
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
        publishWidgetSnapshot()
    }

    // MARK: - Now Playing widget snapshot

    /// Mirror the current playback state into the App Group so the Now Playing
    /// widget can render it, and reload the widget timelines — but only when a
    /// field the widget displays as discrete state actually changed. Called
    /// from `updateNowPlaying()` (every track change / play-pause / seek / tick),
    /// `stop()` and `clearQueue()`. The per-tick calls short-circuit on the
    /// change-detection guard so they cost a few comparisons and nothing else.
    private func publishWidgetSnapshot() {
        let item = current
        let hasTrack = item != nil
        let id = item?.Id ?? ""
        let playing = isPlaying
        let hasArtwork = artwork != nil

        let changed =
            id != lastWidgetTrackId ||
            playing != lastWidgetIsPlaying ||
            hasTrack != lastWidgetHasTrack ||
            hasArtwork != lastWidgetHadArtwork
        guard changed else { return }

        lastWidgetTrackId = id
        lastWidgetIsPlaying = playing
        lastWidgetHasTrack = hasTrack
        lastWidgetHadArtwork = hasArtwork

        let artworkPath: String?
        if hasTrack {
            artworkPath = NowPlayingSharedStore.writeArtwork(artwork)
        } else {
            NowPlayingSharedStore.clearArtwork()
            artworkPath = nil
        }

        let snapshot = NowPlayingSnapshot(
            hasTrack: hasTrack,
            trackId: id,
            title: item?.Name ?? "",
            artist: item?.primaryArtistName ?? "",
            album: item?.Album,
            isPlaying: playing,
            duration: duration,
            elapsed: currentTime,
            anchorDate: Date(),
            artworkRelativePath: artworkPath
        )
        NowPlayingSharedStore.write(snapshot)
        reloadWidgetTimelines()
    }

    private func reloadWidgetTimelines() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - Playback reporting

    /// Schedule the "playback started" report after a short dwell so quick
    /// skips don't count as plays. Cancels any pending report first.
    private func scheduleStartReport(for item: BaseItem) {
        reportStartTask?.cancel()
        reportStartTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.startReportDelay * 1_000_000_000))
            guard !Task.isCancelled, self.current?.Id == item.Id else { return }
            try? await self.reportStart(item: item)
        }
    }

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
    public var activeAudioProcessor: AudioProcessor? { processor }

    // MARK: - Queue persistence (resume across launches)

    private struct QueueSnapshot: Codable {
        let queue: [BaseItem]
        let originalQueue: [BaseItem]
        let currentIndex: Int
        let position: Double
        let shuffle: Bool
        let repeatMode: Int
    }

    /// Persist the queue locally so the next launch can resume PAUSED where the
    /// user left off. Captured on main; written off-main unless `sync` forces it
    /// inline so a background/terminate save flushes before suspension/quit.
    private func persistPlaybackState(sync: Bool = false) {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else {
            clearPersistedQueue(); return
        }
        let snap = QueueSnapshot(queue: queue, originalQueue: originalQueue,
                                 currentIndex: currentIndex,
                                 position: currentTime.isFinite ? currentTime : 0,
                                 shuffle: shuffle, repeatMode: repeatMode.rawValue)
        // Record WHAT we persisted, and whether the index still agrees with the
        // item the player is actually playing. A restore that comes back on the
        // wrong track means these two diverged at write time — this line is the
        // only way to catch that, since the async write may also simply never
        // land before the app is suspended (only `sync: true` guarantees it).
        // Both stream and download URLs carry the item id: `/Audio/{id}/universal`
        // for a stream, `Downloads/{id}.flac` for a local file.
        let playingId = (activePlayer.currentItem?.asset as? AVURLAsset).map { asset -> String in
            asset.url.isFileURL
                ? asset.url.deletingPathExtension().lastPathComponent
                : asset.url.pathComponents.drop(while: { $0 != "Audio" }).dropFirst().first ?? "?"
        }
        // The engine swaps the item synchronously inside open(), so by the time
        // a load-triggered persist runs the player already holds the new item.
        let agrees = playingId == nil || playingId == queue[currentIndex].Id
        DebugLog.write("[AudioPlayer] persist idx=\(currentIndex)/\(queue.count) '\(queue[currentIndex].Name)' at \(Int(snap.position))s sync=\(sync)\(agrees ? "" : " ⚠️ INDEX/ITEM MISMATCH playingId=\(playingId ?? "?")")")
        let write = {
            guard let data = try? JSONEncoder().encode(snap) else { return }
            try? data.write(to: Self.queueStateURL, options: .atomic)
        }
        if sync { persistQueue.sync { write() } } else { persistQueue.async { write() } }
    }

    public func clearPersistedQueue() {
        persistQueue.async { try? FileManager.default.removeItem(at: Self.queueStateURL) }
    }

    private func readLocalSnapshot() -> QueueSnapshot? {
        guard let data = try? Data(contentsOf: Self.queueStateURL) else { return nil }
        return try? JSONDecoder().decode(QueueSnapshot.self, from: data)
    }

    /// Restore the saved queue PAUSED — mini player visible, no stream opened
    /// until the user presses play (the stream + resume-seek happen on the first
    /// play). No-op if already playing, signed out, or nothing saved.
    @objc public func restorePlaybackState() {
        guard queue.isEmpty, !userWantsPlayback, AuthManager.shared.isAuthenticated,
              let snap = readLocalSnapshot() else { return }
        applyRestore(queue: snap.queue, originalQueue: snap.originalQueue, index: snap.currentIndex,
                     position: snap.position, shuffle: snap.shuffle, repeatMode: snap.repeatMode)
    }

    /// Set up the restored queue PAUSED with no AVPlayer item attached — the
    /// stream opens (and seeks to `position`) only on the first play.
    private func applyRestore(queue q: [BaseItem], originalQueue oq: [BaseItem],
                              index: Int, position: Double, shuffle s: Bool, repeatMode r: Int) {
        guard !q.isEmpty else { return }
        originalQueue = oq.isEmpty ? q : oq
        queue = q
        currentIndex = min(max(0, index), q.count - 1)
        shuffle = s
        repeatMode = RepeatMode(rawValue: r) ?? .off
        guard let cur = current else { return }
        duration = cur.durationSeconds
        let pos = max(0, min(position, duration > 0 ? duration : position))
        currentTime = pos
        pendingRestorePosition = pos
        isPlaying = false
        loadArtwork(for: cur)        // show the cover without opening the stream
        updateNowPlaying()
        DebugLog.write("[AudioPlayer] restored queue (\(q.count) tracks) idx=\(currentIndex) '\(cur.Name)' at \(Int(pos))s — paused")
    }

    @objc private func handleWillBackground() { persistPlaybackState(sync: true) }
}
