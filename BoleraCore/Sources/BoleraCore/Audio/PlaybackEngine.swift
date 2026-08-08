import Foundation
import AVFoundation
import Combine

/// The low-level playback engine: it owns the AVPlayer, the current item, and
/// the playhead. Nothing else in the app is allowed to touch those three things.
///
/// WHY THIS EXISTS
/// The previous implementation spread ownership of the playhead across five
/// independent mechanisms — a periodic time observer, a timeControlStatus
/// observer, a silent-underrun watchdog, a foreground "recover now" kick and a
/// network-restored kick — plus two AVPlayers left over from a removed
/// crossfade. Each could move or freeze the playhead without the others
/// knowing, and several could reopen the current stream with no start position
/// at all, which restarted the song from 0:00. Four rounds of targeted fixes
/// did not stop it because the shape of the code allowed it.
///
/// The invariants below are what make that class of bug impossible rather than
/// merely fixed:
///
///  1. There is exactly ONE way to attach audio: `open(track:startAt:…)`, and
///     `startAt` is NOT optional. No code path can reopen a track without
///     stating where it should resume, so "reopened at 0:00 by accident"
///     cannot be expressed.
///  2. `position` is written in exactly three places: an `open`, a completed
///     seek, and a FINITE clock sample. A non-finite sample is ignored, never
///     treated as zero. There is no early-return that can leave it frozen.
///  3. Recovery is a state in one state machine with one timer, not a set of
///     racing watchdogs.
///  4. `streamOffset` is set once per open, alongside the URL it belongs to,
///     and is the only thing that converts stream time to track time.
public final class PlaybackEngine: NSObject {

    // MARK: - Types

    public enum State: Equatable {
        case idle
        case opening        // item created, not yet ready
        case playing
        case paused
        case stalled        // was playing, ran out of data
        case failed(String)
    }

    /// Everything the engine needs to turn a track into a playable URL. Supplied
    /// by the owner so the engine stays free of networking/library concerns.
    /// `offset` is the track time at which the returned stream's own timeline
    /// begins — non-zero only when the server opened it mid-track.
    public struct Stream {
        public let url: URL
        public let offset: Double
        public init(url: URL, offset: Double) { self.url = url; self.offset = offset }
    }

    // MARK: - Collaborators (injected)

    /// Build a stream for a track starting at `startAt` seconds, capped to
    /// `bitrateCap` kbps when non-nil (recovery steps this down).
    public var makeStream: ((_ trackId: String, _ startAt: Double, _ bitrateCap: Int?) -> Stream)?
    /// Attach the EQ/visualiser tap to a freshly created item.
    public var attachProcessor: ((AVPlayer, AVPlayerItem) -> Void)?
    /// Detach/dispose the tap for an item being discarded.
    public var detachProcessor: ((AVPlayer) -> Void)?

    // MARK: - Callbacks

    public var onPosition: ((Double) -> Void)?
    public var onState: ((State) -> Void)?
    public var onEndedNaturally: (() -> Void)?
    /// Real duration once known; only reported for streams that carry the whole
    /// track (an offset stream holds just the remainder and would lie).
    public var onDuration: ((Double) -> Void)?

    // MARK: - Public read-only state

    /// TRACK time in seconds. The single source of truth for "where we are".
    public private(set) var position: Double = 0
    public private(set) var state: State = .idle { didSet { if oldValue != state { onState?(state) } } }
    public private(set) var currentTrackId: String?
    /// True while the attached stream begins mid-track (server-side resume), so
    /// a client-side seek outside the buffered region would desync.
    public private(set) var streamIsOffset = false

    public var isPlaying: Bool { state == .playing || state == .stalled }
    public var hasItem: Bool { player.currentItem != nil }
    public var avPlayer: AVPlayer { player }

    // MARK: - Internals

    private let player = AVPlayer()
    /// Track time at which the current stream's own timeline starts.
    private var streamOffset: Double = 0
    /// Full track duration from library metadata — trusted over the item's own
    /// duration, which is indefinite for progressive transcodes.
    private var trackDuration: Double = 0
    /// Set while `open` is in flight so a dying item's end-notification cannot
    /// be mistaken for the new item finishing. Deliberately NOT consulted by the
    /// clock: a stuck flag must never be able to freeze the playhead.
    private var opening = false
    private var wantsPlayback = false
    private var pendingSeek: Double?

    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?

    // Recovery: one timer, one counter, one owner.
    private var recoveryTimer: DispatchWorkItem?
    private var recoveryAttempt = 0
    private var lastOpenAt: Date = .distantPast
    /// Last position at which the playhead was observed to advance, for the
    /// frozen-playhead check (a dead progressive stream can sit at .playing
    /// forever without AVPlayer ever reporting a stall).
    private var lastAdvance = Date()
    private var lastAdvancePosition: Double = 0

    public override init() {
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        installClock()
        installRateObserver()
    }

    deinit {
        if let t = timeObserver { player.removeTimeObserver(t) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
    }

    // MARK: - The one load path

    /// Attach `track` and resume at `startAt` seconds. This is the ONLY way audio
    /// is attached. `startAt` is required — callers must always state where the
    /// track should begin, which is what stops an incidental reopen from
    /// restarting the song.
    ///
    /// `localURL` short-circuits streaming for a downloaded file (always whole,
    /// always seekable). `bitrateCap` is honoured only for streams.
    public func open(trackId: String,
                     duration: Double,
                     startAt: Double,
                     autoplay: Bool,
                     localURL: URL?,
                     bitrateCap: Int? = nil,
                     reason: String) {
        let start = max(0, startAt)
        opening = true
        wantsPlayback = autoplay || wantsPlayback
        currentTrackId = trackId
        trackDuration = duration
        lastOpenAt = Date()

        let url: URL
        if let local = localURL {
            url = local
            streamOffset = 0
        } else if let make = makeStream {
            let s = make(trackId, start, bitrateCap)
            url = s.url
            streamOffset = s.offset
        } else {
            state = .failed("no stream factory")
            opening = false
            return
        }
        streamIsOffset = streamOffset > 0

        DebugLog.write("[Engine] open '\(trackId)' reason=\(reason) startAt=\(Int(start))s offset=\(Int(streamOffset))s cap=\(bitrateCap.map(String.init) ?? "none") \(url.isFileURL ? "local" : DebugLog.redacted(url))")

        // Position moves to the requested start IMMEDIATELY and stays there while
        // the item opens, so the UI never flicks to 0:00 mid-reopen.
        setPosition(start, from: "open")
        // Anything the stream doesn't cover has to be made up client-side.
        pendingSeek = (start - streamOffset) > 0.5 ? start : nil

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 0
        installEndObserver(for: item)
        installStatusObserver(for: item)
        detachProcessor?(player)
        player.replaceCurrentItem(with: item)
        attachProcessor?(player, item)
        state = .opening
        opening = false
    }

    // MARK: - Transport

    /// Resume. Never reopens anything: if there is no item the caller must
    /// `open` with an explicit position — the engine will not invent one.
    @discardableResult
    public func play() -> Bool {
        wantsPlayback = true
        guard player.currentItem != nil else {
            DebugLog.write("[Engine] play() with no item — caller must open() with a position")
            return false
        }
        DebugLog.write("[Engine] play at \(Int(position))s")
        player.play()
        if state != .stalled { state = .playing }
        return true
    }

    public func pause() {
        wantsPlayback = false
        cancelRecovery()
        player.pause()
        state = .paused
        DebugLog.write("[Engine] pause at \(Int(position))s")
    }

    public func stop() {
        wantsPlayback = false
        cancelRecovery()
        player.pause()
        detachProcessor?(player)
        player.replaceCurrentItem(with: nil)
        currentTrackId = nil
        streamOffset = 0
        streamIsOffset = false
        setPosition(0, from: "stop")
        state = .idle
    }

    /// Seek within the current track. Returns false when the target can't be
    /// reached in the attached stream (an offset transcode ignores byte-Range),
    /// telling the caller to reopen at that position instead.
    @discardableResult
    public func seek(to trackTime: Double) -> Bool {
        guard let item = player.currentItem else { return false }
        let target = max(0, trackTime)
        let itemTarget = target - streamOffset
        if itemTarget < 0 { return false }          // before this stream begins
        if streamIsOffset {
            let reachable = item.seekableTimeRanges.contains { r in
                let range = r.timeRangeValue
                let s = CMTimeGetSeconds(range.start)
                return itemTarget >= s && itemTarget <= s + CMTimeGetSeconds(range.duration)
            }
            if !reachable { return false }
        }
        setPosition(target, from: "seek")
        player.seek(to: CMTime(seconds: itemTarget, preferredTimescale: 1000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] done in
            guard let self, done else { return }
            self.setPosition(target, from: "seek-done")
        }
        return true
    }

    // MARK: - The clock (invariant 2)

    private func installClock() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main) { [weak self] t in
                guard let self else { return }
                let s = CMTimeGetSeconds(t)
                // A non-finite sample is NOISE, not a position. The old code
                // mapped it to 0, which both threw the bar to the start and
                // poisoned every later reader of the position (resume points,
                // persisted queue). Ignore it and keep the last good value.
                guard s.isFinite else { return }
                // Do not let a stale sample from a torn-down item overwrite a
                // freshly opened position.
                guard !self.opening else { return }
                self.setPosition(s + self.streamOffset, from: "clock")
                self.checkForFrozenPlayhead()
            }
    }

    private func setPosition(_ p: Double, from: String) {
        guard p.isFinite else { return }
        position = max(0, p)
        onPosition?(position)
    }

    /// A progressive stream whose connection dies can sit at `.playing` with the
    /// playhead frozen and never report a stall, so watch the position itself.
    private func checkForFrozenPlayhead() {
        guard state == .playing, wantsPlayback else {
            lastAdvance = Date(); lastAdvancePosition = position; return
        }
        if abs(position - lastAdvancePosition) > 0.05 {
            lastAdvance = Date()
            lastAdvancePosition = position
            return
        }
        guard Date().timeIntervalSince(lastAdvance) > 4,
              let item = player.currentItem, !item.isPlaybackLikelyToKeepUp else { return }
        DebugLog.write("[Engine] playhead frozen at \(Int(position))s while playing — treating as stall")
        enterStalled()
    }

    // MARK: - State observers

    private func installRateObserver() {
        rateObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                switch p.timeControlStatus {
                case .playing:
                    self.recoveryAttempt = 0
                    self.cancelRecovery()
                    self.state = .playing
                case .paused:
                    // Only a stall if WE still want playback; a real pause set
                    // wantsPlayback false before touching the player.
                    if self.wantsPlayback, self.player.currentItem != nil {
                        self.enterStalled()
                    } else {
                        self.state = .paused
                    }
                case .waitingToPlayAtSpecifiedRate:
                    if self.wantsPlayback { self.enterStalled() }
                @unknown default: break
                }
            }
        }
    }

    private func installStatusObserver(for item: AVPlayerItem) {
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self, self.player.currentItem === it else { return }
                switch it.status {
                case .readyToPlay:
                    let d = CMTimeGetSeconds(it.duration)
                    // Verify the server honoured a mid-track start. If the item
                    // carries the WHOLE track, it ignored the request and the
                    // audio really begins at 0:00 — drop the offset and seek
                    // client-side instead of silently playing the intro under a
                    // bar parked at the resume point.
                    if self.streamIsOffset, d.isFinite, self.trackDuration > 0,
                       d > self.trackDuration - self.streamOffset + 2 {
                        DebugLog.write("[Engine] server ignored the mid-track start (item is the whole track) — reverting to a client seek")
                        let intended = self.position
                        self.streamOffset = 0
                        self.streamIsOffset = false
                        self.pendingSeek = intended
                    }
                    if !self.streamIsOffset, d.isFinite, d > 0 { self.onDuration?(d) }
                    self.finishOpening(it)
                case .failed:
                    let msg = it.error?.localizedDescription ?? "unknown"
                    DebugLog.write("[Engine] item failed: \(msg)")
                    if self.wantsPlayback { self.enterStalled() } else { self.state = .failed(msg) }
                default: break
                }
            }
        }
    }

    private func finishOpening(_ item: AVPlayerItem) {
        if let target = pendingSeek {
            pendingSeek = nil
            let itemTarget = target - streamOffset
            DebugLog.write("[Engine] ready — seeking to \(Int(target))s (itemTarget=\(String(format: "%.1f", itemTarget)))")
            player.seek(to: CMTime(seconds: itemTarget, preferredTimescale: 1000),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self else { return }
                self.setPosition(target, from: "resume-seek")
                if self.wantsPlayback { self.player.play() }
            }
        } else {
            DebugLog.write("[Engine] ready at \(Int(position))s — playing in place")
            if wantsPlayback { player.play() }
        }
        lastAdvance = Date()
        lastAdvancePosition = position
    }

    private func installEndObserver(for item: AVPlayerItem) {
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
                guard let self, let item, self.player.currentItem === item else { return }
                DebugLog.write("[Engine] played to end at \(Int(self.position))s of \(Int(self.trackDuration))s")
                self.cancelRecovery()
                self.onEndedNaturally?()
            }
    }

    // MARK: - Recovery (invariant 3)

    private func enterStalled() {
        guard state != .stalled else { return }
        guard let item = player.currentItem else { return }
        // A full/healthy buffer means AVPlayer is re-evaluating, not dying — it
        // resumes on its own, and reopening the stream there is what produced an
        // audible restart. Wait it out; the .playing transition cancels this.
        let healthy = item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull
        state = .stalled
        DebugLog.write("[Engine] stalled at \(Int(position))s (bufferHealthy=\(healthy))")
        scheduleRecovery(after: healthy ? 20 : 5)
    }

    private func scheduleRecovery(after delay: TimeInterval) {
        recoveryTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fireRecovery() }
        recoveryTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fireRecovery() {
        guard wantsPlayback, state == .stalled, let trackId = currentTrackId else { return }
        guard Date().timeIntervalSince(lastOpenAt) > 2 else { scheduleRecovery(after: 4); return }
        // Reopen AT THE CURRENT POSITION — never at 0. This is invariant 1 doing
        // the work: there is no expressible reopen that loses the playhead.
        recoveryAttempt += 1
        let cap: Int? = {
            switch recoveryAttempt {
            case 0, 1, 2: return nil
            case 3: return 192
            case 4: return 128
            default: return 96
            }
        }()
        DebugLog.write("[Engine] recovery reopen attempt=\(recoveryAttempt) at \(Int(position))s")
        open(trackId: trackId, duration: trackDuration, startAt: position,
             autoplay: true, localURL: nil, bitrateCap: cap, reason: "recovery")
    }

    /// External nudge (network came back, app foregrounded). Only acts on a
    /// genuinely dead stream — a healthy buffer is left alone.
    public func recoverNow(reason: String) {
        guard wantsPlayback, state == .stalled, let item = player.currentItem else { return }
        guard !(item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull) else {
            DebugLog.write("[Engine] \(reason) — buffer healthy, leaving it alone")
            return
        }
        DebugLog.write("[Engine] \(reason) — recovering now")
        recoveryTimer?.cancel()
        fireRecovery()
    }

    private func cancelRecovery() {
        recoveryTimer?.cancel()
        recoveryTimer = nil
    }
}
