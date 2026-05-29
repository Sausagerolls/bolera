import SwiftUI
import BoleraCore

/// Mini player pinned at the bottom of MainTabView. Observes the narrow
/// `PlayerNowPlayingState` (track + play/pause) rather than the full
/// `AudioPlayer`, so its body only re-runs on track change or play/pause
/// toggle — never on the per-0.1s `currentTime` updates. The progress
/// fill rides a `TimelineView` instead, which updates locally without
/// invalidating the surrounding SwiftUI tree.
struct MiniPlayerView: View {
    @EnvironmentObject var nowPlaying: PlayerNowPlayingState

    var body: some View {
        if let item = nowPlaying.current {
            HStack(spacing: 12) {
                JellyfinImage(itemId: item.artworkItemId, tag: item.artworkTag, maxWidth: 120, cornerRadius: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.Name).font(.subheadline).lineLimit(1)
                    Text(item.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { AudioPlayer.shared.togglePlayPause() } label: {
                    Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                Button { AudioPlayer.shared.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                    MiniPlayerProgressFill()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

/// Progress fill driven by a `TimelineView` rather than an
/// `@EnvironmentObject` subscription. Reads `AudioPlayer.shared`
/// directly so its updates stay confined to this leaf view rather than
/// invalidating the mini player or anything above it.
private struct MiniPlayerProgressFill: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let p = progress
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: p, y: 1, anchor: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    private var progress: CGFloat {
        let p = AudioPlayer.shared
        let d = p.duration
        let c = p.currentTime
        guard d.isFinite, c.isFinite, d > 0 else { return 0 }
        let r = c / d
        guard r.isFinite else { return 0 }
        return CGFloat(min(max(0, r), 1))
    }
}
