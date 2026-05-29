import Foundation
import Combine

/// Narrow observable that exposes a single Bool: "is anything in the
/// player's queue right now?". Subscribes once to the underlying
/// `AudioPlayer` and republishes only when that flag changes — so views
/// that drive layout off of mini-player presence (scroll-content insets,
/// for example) don't get re-rendered on every 0.1s `currentTime` tick.
///
/// Inject as an `EnvironmentObject` once at the app root; consume it
/// anywhere the per-tick `AudioPlayer` updates would be wasted work.
@MainActor
public final class PlayerVisibilityState: ObservableObject {
    @Published public private(set) var isVisible: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    public init(player: AudioPlayer = .shared) {
        player.$queue
            .combineLatest(player.$currentIndex)
            .map { queue, idx in queue.indices.contains(idx) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in self?.isVisible = visible }
            .store(in: &cancellables)
    }
}

/// Narrow observable for everything the mini player needs to render
/// itself *except* its progress fill. Republishes only when the current
/// track changes or when play/pause toggles — never on the per-0.1s
/// `currentTime` ticks that `AudioPlayer` itself emits. The mini player's
/// progress bar reads `AudioPlayer.shared.currentTime` directly via a
/// `TimelineView`, so it doesn't need to ride this object's signal.
@MainActor
public final class PlayerNowPlayingState: ObservableObject {
    @Published public private(set) var current: BaseItem?
    @Published public private(set) var isPlaying: Bool = false

    private var cancellables: Set<AnyCancellable> = []

    public init(player: AudioPlayer = .shared) {
        player.$queue
            .combineLatest(player.$currentIndex)
            .map { queue, idx -> BaseItem? in
                guard queue.indices.contains(idx) else { return nil }
                return queue[idx]
            }
            .removeDuplicates(by: { $0?.Id == $1?.Id })
            .receive(on: RunLoop.main)
            .sink { [weak self] item in self?.current = item }
            .store(in: &cancellables)

        player.$isPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in self?.isPlaying = playing }
            .store(in: &cancellables)
    }
}
