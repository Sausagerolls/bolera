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

/// Singleton audio engine. Maintains two `AVPlayer` instances so we can crossfade
/// between consecutive tracks, installs an `MTAudioProcessingTap` on each item
/// for real-time EQ + visualizer levels, prefers locally downloaded files when
/// available, and keeps `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` in
/// sync so lock screen / Control Center / AirPlay / CarPlay all work.
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
    /// Separate observer for the crossfade incoming track during the fade. Kept
    /// distinct from `statusObserver` so warming the next track doesn't drop
    /// failure-observation of the still-playing outgoing track.
    private var crossfadeStatusObserver: NSKeyValueObservation?
    /// KVO on a freshly-loaded metered stream's buffer, holding back the first
    /// play() until enough is buffered to survive a transcode's cold ramp (see
    /// `startBufferSeconds`). Torn down once playback starts or the item changes.
    private var startGateObserver: NSKeyValueObservation?
    private var startGateDeadline: DispatchWorkItem?
    private var rateObserver: NSKeyValueObservation?
    private var rateObserverB: NSKeyValueObservation?

    private var crossfadeTimer: Timer?
    private var crossfadeStartedFor: BaseItem?
    /// True once the DISPLAYED now-playing has flipped to the incoming track —
    /// done at the crossfade MIDPOINT (when the incoming becomes the louder
    /// track), not at fade start (too early) or fade end (lingers past the old
    /// track's finish). While set, tick() reads the incoming (inactive) player.
    private var crossfadeShowingIncoming = false
    private var nextPrepared: Bool = false

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

    // Stall recovery. A streamed item whose connection drops (dead spot while
    // driving, cellular handoff, tunnel blip) sits in .waitingToPlayAtSpecified-
    // Rate forever — a progressive HTTP stream (which we require for the EQ tap)
    // does NOT self-heal the way HLS does once its connection dies, and the
    // periodic time observer doesn't fire while stalled. So we drive recovery
    // ourselves: when a stall begins we schedule a reload; each reload reopens
    // the stream (downgrading bitrate on a marginal link) and resumes at the
    // frozen position. Crucially we NEVER permanently give up — we keep retrying
    // with a capped backoff for as long as the user intends playback, and a
    // network-restored event (path back / server reachable / app foreground)
    // recovers instantly instead of waiting for the next backoff tick. The old
    // code gave up after 3 reloads, which is exactly why a long dead spot left
    // playback frozen until the user manually skipped.
    private var stallStartedAt: Date?
    /// Count of recovery reloads for the current stuck stream. Drives the
    /// backoff interval + adaptive bitrate step-down. Reset to 0 the moment
    /// playback actually resumes or a fresh (non-recovery) track loads.
    private var recoveryAttempt = 0
    /// The scheduled (timed) recovery reload, kept so a network-restored kick
    /// can cancel the pending backoff wait and recover immediately.
    private var recoveryWorkItem: DispatchWorkItem?
    /// Debounce so a timer tick and a network-restored kick (or a flapping path)
    /// can't fire two reloads back-to-back.
    private var lastReloadAt: Date = .distantPast
    /// Bitrate ceiling forced on the CURRENT recovery reload so a marginal link
    /// can be stepped down (320 → 192 → 128 → 96) until it sustains. nil = use
    /// the normal metered-path logic. Cleared when playback resumes.
    private var recoveryBitrateCap: Int?
    /// True once we've tried the cheap "just tell it to play again" nudge for the
    /// current stall, so we escalate to a real reload on the next attempt instead
    /// of nudging forever. Cleared alongside the rest of the recovery ladder.
    private var nudgedCurrentStall = false
    /// The user's playback INTENT, distinct from `isPlaying` (which is briefly
    /// false during a hard item failure / pause transition). Recovery is gated
    /// on intent so a transient failure doesn't latch playback off.
    private var userWantsPlayback = false
    /// Position to seek to once a reloaded item reaches .readyToPlay, so a
    /// stall-recovery reload resumes where it froze instead of from the start.
    /// Always in TRACK time (the offset below is subtracted when seeking).
    private var pendingSeekAfterLoad: Double?
    /// Seconds into the track where the ACTIVE stream's timeline t=0 begins.
    /// Non-zero only for a transcode the server opened mid-track via
    /// `StartTimeTicks` (stall-recovery / restore / scrub on a metered path).
    /// Every position read from the player must add this; every seek handed to
    /// the player must subtract it.
    private var streamTimelineOffset: Double = 0
    /// True when the active item is the `universal` progressive transcode.
    /// Transcode responses ignore byte-Range, so a client-side seek outside the
    /// already-buffered data silently desyncs (timeline jumps, audio restarts
    /// at 0:00) — those seeks must reopen the stream server-side instead.
    private var activeStreamIsTranscode = false
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
    /// Frozen-playhead watchdog (silent-stall detection in tick): the last
    /// position we saw advance and when. A dead progressive stream can stay
    /// .playing with the playhead stuck and never flip to .waiting.
    private var lastTickTime: Double = 0
    private var lastAdvanceAt: Date = .distantPast

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
    /// Smaller forward buffer for the INCOMING crossfade track. During the fade
    /// two streams play at once; if the incoming one also tries to grab the full
    /// 120s it spikes concurrent connections (esp. over HTTP/3/QUIC to Cloudflare)
    /// and the overlap data-stalls a few seconds into the new track. A modest
    /// buffer covers the fade + margin; `completeCrossfade` restores the full
    /// buffer once it's the sole active stream.
    private let crossfadeForwardBufferSeconds: Double = 30
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
        // Stalling = true) so a crossfade has the incoming track buffered ahead
        // of time. The stall diagnostics in handleTimeControl pinpoint the real
        // cause of any mid-track buffering rather than disabling pre-buffer.
        shuffle = UserDefaults.standard.bool(forKey: "bolera.shuffle")
        repeatMode = RepeatMode(rawValue: UserDefaults.standard.integer(forKey: "bolera.repeat")) ?? .off
        // Stamp the running build into the log — a pulled log must be
        // attributable to a build (48's forensics were silent and we couldn't
        // tell "no events" from "old build without the logging").
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        DebugLog.write("[App] Bolera \(v) (build \(b)) started")
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
                if satisfied && !wasSatisfied { self.recoverNowIfStalled("network restored") }
            }
        }
        audioNetMonitor.start(queue: audioNetQueue)
        // The server answering a connectivity probe again is the most precise
        // "resume now" signal for a LAN-only server reachable via a tunnel.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.reconnectCancellable = ConnectivityStore.shared.didReconnect
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.recoverNowIfStalled("server reconnected") }
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
        // First play after a cross-launch restore: no stream is attached yet —
        // open it now and resume at the remembered position.
        if activePlayer.currentItem == nil {
            loadCurrent(autoplay: true, resumeAt: pendingRestorePosition, trigger: "firstPlayAfterRestore")
            return
        }
        activePlayer.play()
        isPlaying = true
        updateNowPlaying()
        reportProgress(event: "unpause", paused: false)
    }

    public func pause() {
        // If a crossfade is mid-flight, both tracks are audible. Pause onto the
        // track the user currently SEES: if the display already flipped to the
        // incoming (past the midpoint), finalize the fade onto it; otherwise snap
        // back to the still-shown outgoing track. Either way everything silences.
        if crossfadeTimer != nil || crossfadeStartedFor != nil {
            if crossfadeShowingIncoming, let inc = current {
                completeCrossfade(to: inc, nextIndex: currentIndex)
            } else {
                cancelCrossfade()
                inactivePlayer.pause()
                inactivePlayer.replaceCurrentItem(with: nil)
                inactivePlayer.volume = 0
                activePlayer.volume = 1.0
            }
        }
        playerA.pause(); playerB.pause()
        isPlaying = false
        userWantsPlayback = false
        pausedByInterruption = false
        cancelStartGate()
        cancelRecovery()
        updateNowPlaying()
        reportProgress(event: "pause", paused: true)
        persistPlaybackState()   // capture the paused position for next launch
    }

    public func stop() {
        userWantsPlayback = false
        pausedByInterruption = false
        cancelRecovery()
        reportStartTask?.cancel()
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
        // No stream attached yet (restored-but-not-played queue): just remember
        // where to resume and reflect it in the UI; the real seek happens when
        // the stream opens on first play.
        if activePlayer.currentItem == nil {
            currentTime = max(0, seconds)
            pendingRestorePosition = currentTime
            return
        }
        let target = max(0, seconds)
        // Translate to the stream's timeline (shifted on a server-resumed
        // transcode). A transcode ignores byte-Range, so a client seek only
        // works inside data the player has ALREADY buffered — anywhere else
        // (before the stream's mid-track start, or past the buffer) it silently
        // desyncs: the bar shows the target while the audio restarts at the
        // stream head. Those seeks reopen the stream server-side instead.
        let itemTarget = target - streamTimelineOffset
        if activeStreamIsTranscode {
            let seekable = activePlayer.currentItem?.seekableTimeRanges.contains { r in
                let range = r.timeRangeValue
                let start = CMTimeGetSeconds(range.start)
                let end = start + CMTimeGetSeconds(range.duration)
                return itemTarget >= start && itemTarget <= end
            } ?? false
            if itemTarget < 0 || !seekable {
                currentTime = target
                loadCurrent(autoplay: userWantsPlayback, resumeAt: target, trigger: "seekReopen")
                return
            }
        }
        // Optimistic update so the UI snaps to the target immediately
        // (avoids the slider flicking back to the pre-scrub position while
        // the AVPlayer seek is in flight). Also blank-out periodic ticks
        // briefly so they don't echo the old position before the seek lands.
        currentTime = target
        ignoreTicksUntil = Date().addingTimeInterval(0.3)
        let time = CMTime(seconds: itemTarget, preferredTimescale: 1000)
        activePlayer.seek(to: time) { [weak self] _ in
            guard let self = self, !self.pendingTrackSwap else { return }
            self.currentTime = target
            self.updateNowPlaying()
            self.reportProgress(event: "timeupdate", paused: !self.isPlaying)
        }
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

    /// `trigger` records WHY this load happened. The debug log previously showed
    /// only that a track loaded, which made a user skip on the head unit and an
    /// app-initiated track change indistinguishable after the fact — exactly the
    /// ambiguity that stalled the "it changed track on its own" investigation.
    private func loadCurrent(autoplay: Bool, resumeAt: Double? = nil, isRecovery: Bool = false,
                             trigger: String = "?") {
        guard let item = current else { return }
        cancelCrossfade()
        pendingSeekAfterLoad = resumeAt
        pendingRestorePosition = nil   // consumed (or superseded by an explicit load)
        if autoplay { userWantsPlayback = true }
        // A fresh (user-initiated) load starts the recovery state machine clean —
        // cancelRecovery() also ends any in-flight background task so a reload
        // that's superseded by a natural track change (or a skip) can't leak it.
        // A recovery reload keeps the attempt counter + stepped-down bitrate so
        // the backoff and quality ladder continue across reopens.
        if !isRecovery { cancelRecovery() }

        // Reuse the warmed asset when possible — saves the HTTP open +
        // track enumeration round-trip that would otherwise stall the
        // start of playback by 1–2 seconds. A recovery reload skips the warmed
        // asset (it may be the dead one) and reopens fresh at a capped bitrate.
        // A resume-at load also skips it: warmed assets always start at the
        // track's first byte, and a mid-track resume on a metered path needs a
        // stream the SERVER opens at the resume point (StartTimeTicks) — the
        // transcode ignores byte-Range, so client-seeking a warmed asset there
        // desyncs (audio restarts at 0:00 under an unmoved progress bar).
        let asset: AVURLAsset
        var timelineOffset: Double = 0
        if !isRecovery, resumeAt == nil, let warmed = consumePreloadedAsset(for: item) {
            // Log this branch too: it used to write NOTHING, so a track change
            // served from a warmed asset left no trace at all in the log.
            DebugLog.write("[AudioPlayer] load '\(item.Name)' src=warmed trigger=\(trigger) idx=\(currentIndex)/\(queue.count)")
            asset = warmed
        } else {
            let url: URL
            if let local = DownloadManager.shared.localFileURL(for: item.Id) {
                url = local
            } else if let client = client {
                let stream = client.playbackStream(for: item.Id,
                                                   maxBitrateOverride: recoveryBitrateCap,
                                                   startTimeSeconds: resumeAt ?? 0)
                url = stream.url
                timelineOffset = stream.timelineOffset
            } else { return }
            DebugLog.write("[AudioPlayer] load '\(item.Name)' src=\(url.isFileURL ? "local" : "stream") trigger=\(trigger) idx=\(currentIndex)/\(queue.count) recovery=\(isRecovery) offset=\(Int(timelineOffset)) \(DebugLog.redacted(url))")
            asset = AVURLAsset(url: url)
        }
        streamTimelineOffset = timelineOffset
        activeStreamIsTranscode = !asset.url.isFileURL && asset.url.path.contains("/universal")
        lastAccessEventCount = 0   // fresh item — reconnect detector re-baselines
        let playerItem = AVPlayerItem(asset: asset)
        // Buffer well ahead so short network gaps are absorbed silently rather
        // than stalling. (0 = AVPlayer's conservative default, which let a brief
        // dead spot empty the buffer and freeze.)
        playerItem.preferredForwardBufferDuration = forwardBufferSeconds

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
        crossfadeShowingIncoming = false
        cancelStartGate()   // supersede any pending start-buffer gate from a prior load

        pendingTrackSwap = true
        // A resume load (recovery / restore) keeps the bar at the resume point
        // instead of flicking to 0:00 while the stream reopens.
        currentTime = resumeAt ?? 0
        duration = item.durationSeconds
        artwork = nil
        trackStartedAt = Date()
        hasScrobbledCurrent = false
        hasUpdatedNowPlayingCurrent = false

        // Shared status observer: .readyToPlay sets the real duration (+ resume-
        // seek after a recovery reload); .failed arms recovery. The crossfade
        // path uses the SAME observer — it previously ignored .failed entirely,
        // so a dead crossfaded track stopped silently with no recovery.
        statusObserver = observeItemStatus(playerItem, resumeSeek: true)
        replaceEndObserver(for: playerItem)

        // Wait for audio tap install, THEN swap in the player item + autoplay.
        installTapAsync(processor: processor, asset: asset, on: playerItem) { [weak self] in
            guard let self = self else { return }
            self.activePlayer.replaceCurrentItem(with: playerItem)
            self.pendingTrackSwap = false
            self.currentTime = resumeAt ?? 0
            if autoplay {
                if resumeAt != nil {
                    // Recovery/resume: do NOT play from 0 here — the readyToPlay
                    // handler seeks to the resume point first and starts playback
                    // only after, so we never audibly play the start of the track
                    // before jumping back (the "flick to the start" glitch).
                    self.isPlaying = true   // optimistic UI; real play() after the seek
                } else if !asset.url.isFileURL && ConnectivityStore.pathIsExpensive {
                    // Metered stream (likely a cold progressive transcode): wait
                    // for a real forward buffer before the first play() so it
                    // doesn't start then immediately underrun. UI shows buffering.
                    self.isPlaying = true
                    self.isBuffering = true
                    self.playWhenBuffered(playerItem)
                } else {
                    self.activePlayer.play()
                    self.isPlaying = true
                }
            }
        }
        loadArtwork(for: item)
        updateNowPlaying()
        scheduleStartReport(for: item)
        Task { @MainActor in await LastFmService.shared.updateNowPlaying(item); hasUpdatedNowPlayingCurrent = true }
        maybeExtendQueue()   // endless-mix: top up the queue as it nears the end
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

    /// Hold back the first play() on a fresh metered stream until `startBufferSeconds`
    /// of audio is buffered ahead (or `isPlaybackLikelyToKeepUp` + the deadline),
    /// then start. Prevents the cold-transcode "play a few seconds then stall".
    private func playWhenBuffered(_ item: AVPlayerItem) {
        cancelStartGate()

        let start: () -> Void = { [weak self, weak item] in
            guard let self = self, let item = item else { return }
            // Only start if this is still the active item and the user still wants
            // playback (a skip / pause / new load supersedes the gate).
            guard self.userWantsPlayback, self.activePlayer.currentItem === item else {
                self.cancelStartGate(); return
            }
            self.cancelStartGate()
            self.activePlayer.play()
            self.isPlaying = true
            self.isBuffering = false
            // Reset the stall watchdog baseline so the just-started track isn't
            // flagged as frozen on its first ticks.
            self.lastTickTime = 0
            self.lastAdvanceAt = Date()
        }

        let bufferedAhead: (AVPlayerItem) -> Double = { item in
            let head = CMTimeGetSeconds(item.currentTime())
            guard let r = item.loadedTimeRanges.first?.timeRangeValue else { return 0 }
            let end = CMTimeGetSeconds(r.start) + CMTimeGetSeconds(r.duration)
            let ahead = end - head
            return ahead.isFinite ? max(0, ahead) : 0
        }

        // Buffer-watch: start as soon as enough is buffered ahead.
        startGateObserver = item.observe(\.loadedTimeRanges, options: [.new]) { [weak self] obsItem, _ in
            guard let self = self else { return }
            if bufferedAhead(obsItem) >= self.startBufferSeconds {
                DispatchQueue.main.async { start() }
            }
        }

        // Safety deadline: never wait longer than the timeout — start with
        // whatever's there (recovery handles a genuinely dead link as before).
        let deadline = DispatchWorkItem { start() }
        startGateDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + startBufferTimeout, execute: deadline)
    }

    private func cancelStartGate() {
        startGateObserver?.invalidate()
        startGateObserver = nil
        startGateDeadline?.cancel()
        startGateDeadline = nil
    }

    /// True while we're deliberately holding playback to build the start buffer.
    /// Recovery must stand down here — the player is paused ON PURPOSE, not stalled.
    private var startGateActive: Bool { startGateObserver != nil || startGateDeadline != nil }

    /// Status observer used by BOTH the normal load path and the crossfade path.
    /// On `.readyToPlay`: set the real duration and, after a recovery reload,
    /// seek back to the frozen position. On `.failed`: a hard open/stream failure
    /// (dead spot, cellular handoff) arms recovery instead of silently killing
    /// the track. KVO fires off-main, so all state mutation hops to main.
    /// - Parameter resumeSeek: only the loadCurrent path should consume
    ///   `pendingSeekAfterLoad` (a recovery resume). The crossfade incoming item
    ///   must NOT seek — it has no pending resume and seeking the fading-in item
    ///   would jump it.
    private func observeItemStatus(_ playerItem: AVPlayerItem, resumeSeek: Bool = false,
                                   setsDuration: Bool = true) -> NSKeyValueObservation {
        return playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard let self = self else { return }
            if item.status == .readyToPlay {
                let d = CMTimeGetSeconds(item.duration)
                DispatchQueue.main.async {
                    // A stream we asked the server to open mid-track should hold
                    // only the REMAINDER. If its duration matches the full track,
                    // the `universal` endpoint chose direct-play and IGNORED
                    // StartTimeTicks — the stream starts at 0:00 after all. Drop
                    // the offset and fall through to the client-side seek below
                    // (direct-played files are byte-range seekable, so it works).
                    if resumeSeek, self.streamTimelineOffset > 0, d.isFinite,
                       let full = self.current?.durationSeconds, full > 0,
                       d > full - self.streamTimelineOffset + 2 {
                        DebugLog.write("[AudioPlayer] server ignored StartTimeTicks (direct play) — falling back to client seek")
                        self.streamTimelineOffset = 0
                    }
                    // The crossfade incoming item readies DURING the fade, while
                    // the display still shows the OUTGOING track — so it must not
                    // overwrite the displayed `duration` (that made the old track's
                    // total jump to the new one's near the end). The midpoint flip
                    // sets duration from the incoming's metadata instead.
                    // An offset stream's duration is only the remainder of the
                    // track — keep the full metadata duration in that case too.
                    if setsDuration, d.isFinite, self.streamTimelineOffset == 0 { self.duration = d }
                    if resumeSeek, let resume = self.pendingSeekAfterLoad {
                        self.pendingSeekAfterLoad = nil
                        let itemTarget = resume - self.streamTimelineOffset
                        DebugLog.write("[AudioPlayer] ready dur=\(d.isFinite ? String(Int(d)) : "inf")s offset=\(Int(self.streamTimelineOffset)) resume=\(Int(resume)) itemTarget=\(String(format: "%.1f", itemTarget)) → \(itemTarget < 0.5 ? "play-in-place" : "client-seek")")
                        if itemTarget < 0.5 {
                            // Server-side resume: the stream already starts at the
                            // resume point. Do NOT client-seek a transcode — it
                            // ignores byte-Range and the seek desyncs (the audio
                            // restarts at 0:00 under an unmoved bar). Just play.
                            self.currentTime = resume
                            if self.userWantsPlayback {
                                self.activePlayer.play()
                                self.isPlaying = true
                            }
                            self.updateNowPlaying()
                            self.reportProgress(event: "timeupdate", paused: !self.isPlaying)
                            return
                        }
                        // Seek to the resume point BEFORE starting playback so a
                        // recovery reload never plays from 0:00 and flicks back.
                        self.currentTime = resume
                        self.ignoreTicksUntil = Date().addingTimeInterval(0.3)
                        let t = CMTime(seconds: itemTarget, preferredTimescale: 1000)
                        self.activePlayer.seek(to: t) { [weak self] _ in
                            guard let self = self else { return }
                            self.currentTime = resume
                            if self.userWantsPlayback {
                                self.activePlayer.play()
                                self.isPlaying = true
                            }
                            self.updateNowPlaying()
                            self.reportProgress(event: "timeupdate", paused: !self.isPlaying)
                        }
                    } else {
                        self.updateNowPlaying()
                    }
                }
            } else if item.status == .failed {
                let reason = item.error?.localizedDescription ?? "unknown"
                DebugLog.write("[AudioPlayer] item failed: \(reason) — scheduling recovery")
                DispatchQueue.main.async {
                    self.dumpItemLogs(item, context: "failed")
                    self.pendingTrackSwap = false
                    if self.userWantsPlayback {
                        if self.stallStartedAt == nil { self.stallStartedAt = Date() }
                        self.scheduleRecovery()
                    } else {
                        self.isPlaying = false
                    }
                }
            }
        }
    }

    private func replaceEndObserver(for item: AVPlayerItem) {
        if let prev = endObserver { NotificationCenter.default.removeObserver(prev) }
        endObserverItem = item
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self, weak item] _ in
            guard let self = self else { return }
            // If a crossfade already swapped to the next track, ignore the dying item's end.
            if self.crossfadeStartedFor != nil { return }
            // Only the item currently attached to the active player should advance
            // the queue — a recovery reload swaps items out, and the stale item's
            // end notification must not fire a spurious skip mid-recovery.
            guard !self.pendingTrackSwap, let item = item, self.activePlayer.currentItem === item else { return }
            DebugLog.write("[AudioPlayer] item played to end at \(Int(self.currentTime))s of \(Int(self.duration))s — advancing")
            self.next(trigger: "endOfTrack")
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
        guard crossfadeTimer == nil else { return }   // a fade is already running
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
            url = client.playbackStreamURL(for: nextItem.Id)
        } else { return }

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        // Modest buffer during the overlap so the incoming stream doesn't spike
        // concurrent connections and data-stall the fade; restored to the full
        // buffer in completeCrossfade once it's the only active stream.
        item.preferredForwardBufferDuration = crossfadeForwardBufferSeconds
        // Watch the incoming track for failure DURING the fade window (it plays
        // on the inactive player, so handleTimeControl ignores it). Without this
        // a crossfaded track whose stream dies on a network boundary stops
        // silently. Uses a SEPARATE observer so the outgoing (still-active) track
        // keeps its own failure observation; promoted in completeCrossfade.
        crossfadeStatusObserver = observeItemStatus(item, setsDuration: false)

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
            // The continuation fires async — if the user paused (which cancels
            // the crossfade) in the meantime, don't resurrect the incoming
            // track on the inactive player.
            guard self.crossfadeStartedFor != nil, self.isPlaying else { return }
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
            // Midpoint: the incoming track is now the louder one — flip the
            // displayed now-playing to it (art/info/time), the natural changeover.
            if t >= 0.5 { self.flipDisplayToIncoming(upcoming, index: nextIndex) }
            if t >= 1.0 {
                timer.invalidate()
                self.completeCrossfade(to: upcoming, nextIndex: nextIndex)
            }
        }
    }

    /// Flip the DISPLAYED now-playing to the incoming track mid-fade. Audio keeps
    /// crossfading on both players; `tick()` reads the incoming (inactive) player
    /// while `crossfadeShowingIncoming`, so the shown time is the new track's.
    private func flipDisplayToIncoming(_ item: BaseItem, index: Int) {
        guard !crossfadeShowingIncoming else { return }
        crossfadeShowingIncoming = true
        currentIndex = index
        let elapsed = CMTimeGetSeconds(inactivePlayer.currentItem?.currentTime() ?? .zero)
        currentTime = elapsed.isFinite ? max(0, elapsed) : 0
        duration = item.durationSeconds
        artwork = nil
        trackStartedAt = Date()
        hasScrobbledCurrent = false
        hasUpdatedNowPlayingCurrent = false
        loadArtwork(for: item)
        updateNowPlaying()
        scheduleStartReport(for: item)
        Task { @MainActor in await LastFmService.shared.updateNowPlaying(item) }
    }

    private func completeCrossfade(to upcoming: BaseItem, nextIndex: Int) {
        crossfadeTimer?.invalidate(); crossfadeTimer = nil
        // Make sure the display flipped (covers a very short fade that jumped the
        // timer past the midpoint). Reads the incoming on the inactive player.
        flipDisplayToIncoming(upcoming, index: nextIndex)
        // Swap roles: drop the outgoing item and make the incoming the active player.
        detachMix(from: activePlayer)   // finalize the outgoing item's tap before releasing it
        activePlayer.pause()
        activePlayer.replaceCurrentItem(with: nil)
        activeIsA.toggle()
        activePlayer.volume = 1.0
        // The incoming stream was opened at the track's start — no timeline shift.
        streamTimelineOffset = 0
        activeStreamIsTranscode = ((activePlayer.currentItem?.asset as? AVURLAsset).map {
            !$0.url.isFileURL && $0.url.path.contains("/universal")
        }) ?? false
        // Re-sync the counter to the incoming track's real elapsed (now active).
        let incomingElapsed = CMTimeGetSeconds(activePlayer.currentItem?.currentTime() ?? .zero)
        currentTime = incomingElapsed.isFinite ? max(0, incomingElapsed) : 0
        crossfadeStartedFor = nil
        crossfadeShowingIncoming = false

        pendingSeekAfterLoad = nil   // a crossfade starts fresh — never resume-seek
        // Promote the incoming track's observer to the primary slot (it's now the
        // active item) and clear the crossfade slot.
        crossfadeStatusObserver = nil
        if let item = activePlayer.currentItem {
            // Now the sole active stream — restore the full forward buffer for
            // dead-spot resilience (it ran with the modest crossfade buffer).
            item.preferredForwardBufferDuration = forwardBufferSeconds
            statusObserver = observeItemStatus(item)
            replaceEndObserver(for: item)
        }
        updateNowPlaying()
    }

    private func cancelCrossfade() {
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeStartedFor = nil
        crossfadeShowingIncoming = false
        crossfadeStatusObserver = nil
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
        // Start warming after a 1s lead (was 3s) — soon enough to be ready for
        // dead spots, late enough that the current track's own initial buffer
        // gets priority instead of competing with N simultaneous opens.
        guard currentTime >= 1 else { return }
        // Don't open N upcoming streams while the current one is fighting to
        // recover — they'd just steal bandwidth from the reload on a bad link.
        guard stallStartedAt == nil else { return }
        // Nor during a crossfade: two streams already overlap, and adding N more
        // concurrent opens spikes connections and data-stalls the incoming track.
        guard crossfadeStartedFor == nil, crossfadeTimer == nil else { return }
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
        // (A second observer used to sit on playerB for the crossfade swap;
        // with crossfade removed playerB is never the active player, and the
        // duplicate just fired tick() twice per interval. Removed.)
    }

    private func tick() {
        // Suppress reads while a new item is being prepared; otherwise the
        // observer would echo the previous track's scrub position before the
        // replaceCurrentItem callback fires.
        guard !pendingTrackSwap else { return }
        // Also skip during the post-programmatic-seek blackout window.
        guard Date() >= ignoreTicksUntil else { return }
        // After the crossfade midpoint the display shows the incoming track,
        // which is still on the inactive player until the fade completes — read
        // its clock so the shown time matches the displayed (new) track.
        let showingIncoming = crossfadeShowingIncoming && crossfadeStartedFor != nil
        let sourcePlayer = showingIncoming ? inactivePlayer : activePlayer
        guard let item = sourcePlayer.currentItem else { return }
        let t = CMTimeGetSeconds(item.currentTime())
        // Add the server-resume offset: an offset stream's t=0 is mid-track.
        // (The crossfade incoming stream always starts at 0 — no offset.)
        let offset = showingIncoming ? 0 : streamTimelineOffset
        currentTime = t.isFinite ? t + offset : 0
        // Silent-stall watchdog. A progressive stream whose connection dies can
        // sit at timeControlStatus == .playing with the playhead FROZEN and never
        // flip to .waiting — so the status-observer recovery never arms. Here we
        // watch the position itself: if it stops advancing while we're supposedly
        // playing and the buffer can't keep up, treat it as a stall and recover.
        if userWantsPlayback, !showingIncoming, activePlayer.timeControlStatus == .playing, currentTime > 1 {
            if abs(currentTime - lastTickTime) > 0.05 {
                lastTickTime = currentTime
                lastAdvanceAt = Date()
            } else if stallStartedAt == nil,
                      Date().timeIntervalSince(lastAdvanceAt) > 3,
                      !item.isPlaybackLikelyToKeepUp {
                DebugLog.write("[AudioPlayer] silent underrun — playhead frozen at \(Int(currentTime))s, arming recovery")
                dumpItemLogs(item, context: "underrun")
                stallStartedAt = Date()
                scheduleRecovery()
            }
        } else {
            // Not actively playing yet (buffering, starting, paused) — keep the
            // baseline fresh so the watchdog never trips on a just-loaded track
            // (the .distantPast init / fresh-track false positive).
            lastTickTime = currentTime
            lastAdvanceAt = Date()
        }
        // Keep the lock-screen / notification / CarPlay elapsed time in sync.
        // Relying on the system to extrapolate from a single anchor left the
        // first track's scrubber stuck at 0 with no progress marker until a
        // skip; pushing the real elapsed each tick fixes it.
        updateNowPlaying()
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
        // Crossfade removed (caused buffering/stutter problems) — tracks now
        // always hard-cut via natural end → next(). maybeStartCrossfade() is no
        // longer called; the dual-player path stays only for its plumbing.
        preloadNextIfNeeded()
        if Date().timeIntervalSince(lastProgressReport) > 10 {
            lastProgressReport = Date()
            reportProgress(event: "timeupdate", paused: !isPlaying)
            // The inactive player must NEVER be audible outside a crossfade —
            // if it is, that's a second audio source playing from ITS stream
            // head (byte 0) under the active track's bar: the only remaining
            // explanation for "audio from the start, bar unmoved" now that the
            // server-side resume streams are verified to start mid-track.
            if crossfadeStartedFor == nil, inactivePlayer.timeControlStatus == .playing {
                let it = inactivePlayer.currentItem.map { CMTimeGetSeconds($0.currentTime()) } ?? -1
                DebugLog.write("[AudioPlayer] ANOMALY inactive player audible: vol=\(inactivePlayer.volume) time=\(String(format: "%.1f", it))s — muting")
                inactivePlayer.pause()
                inactivePlayer.volume = 0
            }
            // Mid-play reconnect detector: a new access-log event means AVPlayer
            // silently opened another HTTP connection for the SAME item — the
            // exact moment a byte-mapping desync (audio restarts, bar doesn't)
            // can happen. No stall event fires for it, so catch it here and
            // dump the HTTP forensics while they're fresh.
            let events = item.accessLog()?.events.count ?? 0
            if events != lastAccessEventCount {
                if lastAccessEventCount > 0, events > lastAccessEventCount,
                   let urlAsset = item.asset as? AVURLAsset, !urlAsset.url.isFileURL {
                    DebugLog.write("[AudioPlayer] mid-play reconnect: access-log events \(lastAccessEventCount)→\(events) at \(Int(currentTime))s")
                    lastItemLogDumpAt = .distantPast   // bypass throttle — this is the event we care about
                    dumpItemLogs(item, context: "reconnect")
                }
                lastAccessEventCount = events
            }
        }
    }

    private func observePlayer() {
        // Observe timeControlStatus, NOT rate. During a buffering stall the
        // rate stays at 1.0 while timeControlStatus becomes
        // .waitingToPlayAtSpecifiedRate — observing rate alone leaves the app
        // thinking it's playing, so the lock-screen keeps advancing while the
        // audio (and the in-app bar) is stalled.
        rateObserver = playerA.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            self?.handleTimeControl(p, isA: true)
        }
        // RETAIN this observation — the old `_ = playerB.observe(...)` discarded
        // the NSKeyValueObservation, which invalidates immediately, so playerB
        // state changes never fired handleTimeControl at all (silent recovery
        // hole if playerB ever becomes the active player again).
        rateObserverB = playerB.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            self?.handleTimeControl(p, isA: false)
        }
    }

    private func handleTimeControl(_ player: AVPlayer, isA: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.activeIsA == isA else { return }
            let status = player.timeControlStatus
            // Deliberately buffering for the start gate — the player is paused ON
            // PURPOSE to build the start buffer, so don't flip isPlaying off or arm
            // recovery. Keep showing buffering until playWhenBuffered starts it.
            if self.startGateActive {
                self.isBuffering = true
                self.isPlaying = true
                self.updateNowPlaying()
                return
            }
            self.isBuffering = (status == .waitingToPlayAtSpecifiedRate)
            if status == .waitingToPlayAtSpecifiedRate, let item = player.currentItem {
                // Diagnostics for the "audio cut out, 30s gap on a fast LAN"
                // stalls — reasonForWaitingToPlay says WHY (e.g. .toMinimizeStalls
                // = waiting on data), plus the buffer flags + any item error.
                DebugLog.write("[AudioPlayer] STALL '\(self.current?.Name ?? "?")' reason=\(player.reasonForWaitingToPlay?.rawValue ?? "nil") bufferEmpty=\(item.isPlaybackBufferEmpty) likelyToKeepUp=\(item.isPlaybackLikelyToKeepUp) bufferFull=\(item.isPlaybackBufferFull) error=\(item.error.map { String(describing: $0) } ?? "none")")
                self.dumpItemLogs(item, context: "stall")
            }
            // .paused means actually paused; .playing and .waiting both mean the
            // user intends playback (a stall isn't a pause).
            self.isPlaying = (status != .paused)
            // Stall recovery bookkeeping.
            switch status {
            case .waitingToPlayAtSpecifiedRate:
                if self.stallStartedAt == nil {
                    self.stallStartedAt = Date()
                    // If the buffer still holds audio, AVPlayer is just
                    // rebuffering/evaluating and will resume on its own (the
                    // .playing case cancels this) — forcing a reload there only
                    // causes a harder gap (the crossfade/cellular "stutter").
                    // Be patient unless the buffer is genuinely EMPTY (real
                    // underrun), which keeps the quick reload.
                    let hasBuffer = !(player.currentItem?.isPlaybackBufferEmpty ?? true)
                    self.scheduleRecovery(firstDelayOverride: hasBuffer ? 20 : nil)
                }
            case .playing:
                // Recovered (or never stalled): reset the whole recovery ladder.
                self.stallStartedAt = nil
                self.recoveryAttempt = 0
                self.recoveryBitrateCap = nil
                self.nudgedCurrentStall = false
                self.recoveryWorkItem?.cancel(); self.recoveryWorkItem = nil
                self.endBackgroundTaskIfNeeded()
            case .paused:
                if self.userWantsPlayback && !self.pendingTrackSwap {
                    // We did NOT ask to pause, yet the player went .paused — a dead
                    // stream that dropped to .paused instead of .waiting (the most
                    // common silent-stop shape: crossfaded track fails on a network
                    // boundary). Arm recovery instead of treating it as a pause.
                    // (A real user pause sets userWantsPlayback=false BEFORE the
                    // player pauses; a deliberate track swap sets pendingTrackSwap —
                    // both are excluded, so only a genuine mid-play death lands here.)
                    if self.stallStartedAt == nil {
                        DebugLog.write("[AudioPlayer] unexpected pause while playback intended — arming recovery")
                        if let item = player.currentItem { self.dumpItemLogs(item, context: "pause") }
                        self.stallStartedAt = Date()
                        // Same patience as the .waiting case: if there's still
                        // buffered audio, let it resume rather than hard-reloading.
                        let hasBuffer = !(player.currentItem?.isPlaybackBufferEmpty ?? true)
                        self.scheduleRecovery(firstDelayOverride: hasBuffer ? 20 : nil)
                    }
                } else {
                    self.stallStartedAt = nil
                    self.recoveryWorkItem?.cancel(); self.recoveryWorkItem = nil
                    self.endBackgroundTaskIfNeeded()
                }
            @unknown default: break
            }
            // On resume, re-read the real position so Now Playing re-syncs after
            // the frozen-bar stall instead of jumping from a stale elapsed time.
            if status == .playing, let item = player.currentItem {
                let t = CMTimeGetSeconds(item.currentTime())
                if t.isFinite { self.currentTime = t + self.streamTimelineOffset }
            }
            self.updateNowPlaying()
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
        DebugLog.write("[AVLog] \(context) access=\(accessEvents.count) error=\(errorEvents.count) itemTime=\(t.isFinite ? String(Int(t)) : "nan")s offset=\(Int(streamTimelineOffset)) shownTime=\(Int(currentTime))s")
        for e in accessEvents.suffix(3) {
            let uri = e.uri.flatMap(URL.init(string:)).map(DebugLog.redacted) ?? "?"
            DebugLog.write("[AVLog] \(context) access uri=\(uri) server=\(e.serverAddress ?? "?") addrChanges=\(e.numberOfServerAddressChanges) bytes=\(e.numberOfBytesTransferred) stalls=\(e.numberOfStalls) watched=\(Int(e.durationWatched))s transfer=\(String(format: "%.1f", e.transferDuration))s")
        }
        for e in errorEvents.suffix(5) {
            DebugLog.write("[AVLog] \(context) error status=\(e.errorStatusCode) domain=\(e.errorDomain) comment=\(e.errorComment ?? "-") server=\(e.serverAddress ?? "?")")
        }
    }

    // MARK: - Stall recovery state machine

    /// Backoff before the next recovery reload, indexed by attempts so far. The
    /// first wait lets AVPlayer try to self-heal; later waits grow so we don't
    /// hammer a dead server — but we NEVER stop retrying while playback is
    /// intended (the old code gave up after 3 reloads → permanent freeze).
    private func recoveryDelay(for attempt: Int) -> TimeInterval {
        switch attempt {
        case 0: return 5
        case 1: return 4
        case 2: return 6
        case 3: return 10
        case 4: return 15
        case 5: return 25
        default: return 40   // steady cap: keep trying forever, battery-friendly
        }
    }

    /// Bitrate ceiling for a given recovery attempt — step the metered-path
    /// quality down on a marginal link until it sustains. nil = normal cap.
    private func bitrateCap(for attempt: Int) -> Int? {
        switch attempt {
        case 0, 1, 2: return nil   // first tries at normal cellular quality (≤320)
        case 3: return 192
        case 4: return 128
        default: return 96
        }
    }

    /// True when the active item still holds enough buffered audio that AVPlayer
    /// will resume on its own — `.waitingToPlayAtSpecifiedRate` with a full /
    /// keep-up buffer is NOT a dead stream. AVPlayer parks there for a beat on
    /// every resume-shaped transition (interruption ended, CarPlay route change,
    /// app foreground) and clears itself a moment later. Reloading such an item
    /// tears down a perfectly good connection and reopens the transcode — which
    /// is exactly the audible "the track restarted" the user hears.
    private var activeItemLooksHealthy: Bool {
        guard let item = activePlayer.currentItem else { return false }
        guard item.status != .failed, item.error == nil else { return false }
        return item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull
    }

    /// How long the current stall has been running (0 if we aren't stalled).
    private var stallAge: TimeInterval {
        stallStartedAt.map { Date().timeIntervalSince($0) } ?? 0
    }

    /// Schedule the next recovery reload after a backoff; replaces any pending
    /// one. Called when a stall (or hard item failure) begins.
    private func scheduleRecovery(firstDelayOverride: TimeInterval? = nil) {
        recoveryWorkItem?.cancel()
        // `firstDelayOverride` lets the caller be MORE patient on the first
        // attempt (e.g. the buffer still has audio, so AVPlayer will likely
        // resume on its own and a reload would just cause a harder gap).
        let delay = (recoveryAttempt == 0 ? firstDelayOverride : nil) ?? recoveryDelay(for: recoveryAttempt)
        let work = DispatchWorkItem { [weak self] in self?.fireRecovery() }
        recoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Perform a recovery reload now, if still stalled and the user still wants
    /// playback. Advances the attempt counter + bitrate ladder. Debounced so a
    /// backoff tick and a network-restored kick can't double-fire.
    private func fireRecovery() {
        guard userWantsPlayback else { endBackgroundTaskIfNeeded(); return }
        guard stallStartedAt != nil else { return }            // already recovered
        guard Date().timeIntervalSince(lastReloadAt) > 2 else {
            // Too soon since the last reopen (e.g. a network-restored kick landed
            // right after a timed reload). Re-arm the timer instead of dropping
            // the recovery on the floor, so we still retry shortly. The backoff
            // delay (≥4s) guarantees the next fire clears this 2s window.
            scheduleRecovery()
            return
        }
        // The stream is still buffered — it isn't dead, it just never got told to
        // start again (the classic shape after `interruption ended` where AVPlayer
        // sits in .waiting with a FULL buffer). Re-assert the session and ask it to
        // play rather than reopening the stream: a reload here is what restarts the
        // track audibly. Only tried once per stall; if it doesn't take we fall
        // through to a real reload on the next backoff tick.
        if activeItemLooksHealthy && !nudgedCurrentStall {
            nudgedCurrentStall = true
            DebugLog.write("[AudioPlayer] stalled with a healthy buffer — nudging play() instead of reloading")
            configureAudioSession()
            activePlayer.play()
            scheduleRecovery()
            return
        }
        lastReloadAt = Date()
        recoveryAttempt += 1
        recoveryBitrateCap = bitrateCap(for: recoveryAttempt)
        DebugLog.write("[AudioPlayer] recovery reload '\(current?.Name ?? "?")' at \(Int(currentTime))s attempt=\(recoveryAttempt) cap=\(recoveryBitrateCap.map(String.init) ?? "default")")
        reloadCurrentResumingPosition()
    }

    /// Network came back (path usable / server reachable / app foreground):
    /// recover a stalled stream immediately instead of waiting out the backoff.
    private func recoverNowIfStalled(_ reason: String) {
        guard userWantsPlayback, stallStartedAt != nil else { return }
        // Don't let an "instant" kick jump the patience the timed path deliberately
        // applies. Two things disqualify a stall from immediate recovery:
        //
        //  1. It only just started. Every resume-shaped transition (interruption
        //     ended, CarPlay connect, app foreground) puts AVPlayer in .waiting for
        //     a beat, and `didBecomeActive` lands in that same beat — so the kick
        //     was firing on a player that was about to resume by itself.
        //  2. The buffer is still healthy, so there's nothing to reopen.
        //
        // In both cases the scheduled recovery stays armed and takes over if the
        // stall is real. This is the mid-song restart: the stream was fine, the
        // foreground kick reloaded it anyway, and the reopened transcode restarted
        // the track (and on a marginal link, spiralled down the bitrate ladder).
        guard stallAge >= 4 else {
            DebugLog.write("[AudioPlayer] \(reason) — stall only \(String(format: "%.1f", stallAge))s old, letting it settle")
            return
        }
        guard !activeItemLooksHealthy else {
            DebugLog.write("[AudioPlayer] \(reason) — buffer still healthy, not reloading")
            return
        }
        DebugLog.write("[AudioPlayer] \(reason) — recovering stalled stream now")
        recoveryWorkItem?.cancel(); recoveryWorkItem = nil
        fireRecovery()
    }

    /// Tear down any pending/active recovery — user paused or stopped.
    private func cancelRecovery() {
        stallStartedAt = nil
        recoveryAttempt = 0
        recoveryBitrateCap = nil
        nudgedCurrentStall = false
        recoveryWorkItem?.cancel(); recoveryWorkItem = nil
        endBackgroundTaskIfNeeded()
    }

    /// Rebuild the current item from scratch (fresh AVURLAsset → reopens the
    /// HTTP connection, at a possibly stepped-down bitrate) and resume at the
    /// position it stalled on, so a dropped stream recovers without skipping.
    /// Wrapped in a background task so a backgrounded app (screen off / CarPlay)
    /// is granted runtime to finish the reopen.
    private func reloadCurrentResumingPosition() {
        beginBackgroundTaskIfNeeded()
        // The item we're about to discard holds the evidence for WHY it died —
        // dump its full HTTP history before replaceCurrentItem destroys it.
        if let dying = activePlayer.currentItem {
            dumpItemLogs(dying, context: "pre-reload", force: true)
        }
        let resumeAt = currentTime
        stallStartedAt = nil
        // Re-baseline the silent-underrun watchdog. It trips when the playhead
        // stops advancing, and a reload freezes the playhead at `resumeAt` by
        // design while the new item opens — without this reset the watchdog sees
        // a "frozen" playhead the instant the reload starts and immediately arms
        // a SECOND recovery on top of the one in flight.
        lastTickTime = resumeAt
        lastAdvanceAt = Date()
        // Drop any warmed asset for the current track so we genuinely reopen the
        // stream instead of reusing the same (possibly dead) asset.
        if let id = current?.Id { preloadedAssets.removeValue(forKey: id) }
        // Full reconfigure (category + active), not just setActive — if the
        // session was left dead (e.g. the launch -50, or a media reset), a bare
        // reactivate reloads audio into a silent session. configureAudioSession
        // re-asserts the .playback category too.
        configureAudioSession()
        loadCurrent(autoplay: true, resumeAt: resumeAt, isRecovery: true, trigger: "stallRecovery")
    }

    #if canImport(UIKit)
    @objc private func handleDidBecomeActive() {
        refreshCarPlayRoute()
        recoverNowIfStalled("app foregrounded")
        // A hard failure can land while the app is suspended (its status-observer
        // recovery may never have fired), leaving a failed item with no armed
        // recovery. Catch that on resume so reopening the app always unsticks it.
        if userWantsPlayback, stallStartedAt == nil,
           activePlayer.currentItem?.status == .failed {
            DebugLog.write("[AudioPlayer] foreground: found failed item — scheduling recovery")
            stallStartedAt = Date()
            scheduleRecovery()
        }
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
    public var activeAudioProcessor: AudioProcessor? {
        activeIsA ? processorA : processorB
    }

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
