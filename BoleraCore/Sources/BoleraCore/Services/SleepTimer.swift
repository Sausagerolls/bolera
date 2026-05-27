import Foundation
import Combine

@MainActor
public final class SleepTimer: ObservableObject {
    public static let shared = SleepTimer()

    public enum Mode: Equatable {
        case off
        case duration(TimeInterval)
        case endOfTrack
    }

    @Published public private(set) var mode: Mode = .off
    @Published public private(set) var remaining: TimeInterval = 0

    private var timer: Timer?
    private var expiresAt: Date?

    public func start(duration: TimeInterval) {
        cancel()
        mode = .duration(duration)
        expiresAt = Date().addingTimeInterval(duration)
        remaining = duration
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    public func endOfTrack() {
        cancel()
        mode = .endOfTrack
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
        expiresAt = nil
        remaining = 0
        mode = .off
    }

    /// True if we should halt playback at the end of the current track.
    public var willStopAtEndOfTrack: Bool {
        if case .endOfTrack = mode { return true }
        return false
    }

    /// Called by AudioPlayer when the current track finishes naturally. Consumes
    /// the end-of-track mode so subsequent end events behave normally.
    public func consumeEndOfTrackStop() -> Bool {
        if case .endOfTrack = mode {
            cancel()
            return true
        }
        return false
    }

    private func tick() {
        guard let expires = expiresAt else { return }
        remaining = max(0, expires.timeIntervalSinceNow)
        if remaining <= 0 {
            AudioPlayer.shared.pause()
            cancel()
        }
    }
}
