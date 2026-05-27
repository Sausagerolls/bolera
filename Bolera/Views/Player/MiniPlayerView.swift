import SwiftUI
import BoleraCore

struct MiniPlayerView: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        if let item = player.current {
            HStack(spacing: 12) {
                JellyfinImage(itemId: item.artworkItemId, tag: item.artworkTag, maxWidth: 120, cornerRadius: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.Name).font(.subheadline).lineLimit(1)
                    Text(item.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                Button { player.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.title3)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                    GeometryReader { geo in
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.25))
                            .frame(width: geo.size.width * progress)
                            .animation(.linear(duration: 0.1), value: progress)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            )
        }
    }

    private var progress: CGFloat {
        let d = player.duration
        let c = player.currentTime
        guard d.isFinite, c.isFinite, d > 0 else { return 0 }
        let r = c / d
        guard r.isFinite else { return 0 }
        return CGFloat(min(max(0, r), 1))
    }
}
