import Foundation
import BoleraCore
import SwiftUI

extension Double {
    var mmSS: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

extension View {
    /// Convenience: tap target with platform-default behavior.
    func plainButton<Action>(_ action: @escaping () -> Action) -> some View {
        Button(action: { _ = action() }) { self }.buttonStyle(.plain)
    }
}

struct JellyfinImage: View {
    let itemId: String?
    let tag: String?
    var maxWidth: Int = 600
    var cornerRadius: CGFloat = 8
    @EnvironmentObject var auth: AuthManager
    // Hold the decoded image in @State, keyed to the item it belongs to. This
    // survives NSCache eviction (so artwork doesn't blank under memory pressure)
    // WITHOUT the old `.imageCacheDidEvict` notification — which spawned a reload
    // Task in every visible image on each eviction and, during a memory-pressure
    // burst, flooded the main-thread Swift task allocator and CRASHED the app
    // (EXC_BAD_ACCESS in swift_task_create). `loadedId == itemId` guards against
    // showing the previous item's pixels for a recycled cell before reload lands.
    @State private var image: UIImage?
    @State private var loadedId: String?
    @State private var failed: Bool = false

    var body: some View {
        ZStack {
            if let image, loadedId == itemId {
                // Anchor + overlay center-crops any aspect ratio to the caller's
                // frame (a non-square cover would otherwise overflow the tile).
                Color.clear
                    .overlay {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else if failed, itemId != nil {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    )
            } else {
                ShimmerView(cornerRadius: cornerRadius)
            }
        }
        .task(id: itemId) { await reload() }
    }

    private func reload() async {
        guard let id = itemId, let url = auth.serverURL else {
            await MainActor.run { image = nil; loadedId = itemId; failed = (itemId != nil) }
            return
        }
        let client = JellyfinClient(baseURL: url, auth: auth)
        // A downloaded item's persisted cover art renders offline and at any
        // size — prefer it over the server URL.
        if let localArt = DownloadManager.shared.localArtworkURL(forArtworkId: id),
           let img = await ImageCache.shared.load(url: localArt) {
            await MainActor.run { image = img; loadedId = id; failed = false }
            return
        }
        guard let imgURL = client.imageURL(for: id, tag: tag, maxWidth: maxWidth) else {
            await MainActor.run { failed = true; loadedId = id }
            return
        }
        if let cached = ImageCache.shared.peekMemory(url: imgURL) {
            await MainActor.run { image = cached; loadedId = id; failed = false }
            return
        }
        let loaded = await ImageCache.shared.load(url: imgURL, headers: ["Authorization": auth.authHeader()])
        await MainActor.run {
            if let loaded {
                image = loaded; loadedId = id; failed = false
            } else {
                print("[JellyfinImage] Failed to load \(imgURL.absoluteString)")
                failed = true; loadedId = id
            }
        }
    }
}

/// Leading marker for a track row whose left element is an index number.
/// Shows the app's now-playing glyph (matching the queue's
/// `speaker.wave.2.fill`) when this track is the one AudioPlayer is on,
/// otherwise the track's index. Kept as its own tiny view so only the marker
/// re-renders on the player's frequent `currentTime` ticks — not the whole list.
struct NowPlayingIndexMarker: View {
    let trackId: String
    let index: Int
    @ObservedObject private var player = AudioPlayer.shared

    var body: some View {
        if player.current?.Id == trackId {
            Image(systemName: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
        } else {
            Text("\(index)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Now-playing badge overlaid on a track row's leading artwork thumbnail (for
/// rows that show a cover instead of an index): a dim scrim + speaker glyph,
/// shown only for the track currently playing. Self-contained observer so the
/// surrounding list doesn't re-render on `currentTime` ticks.
struct NowPlayingArtworkBadge: View {
    let trackId: String
    var cornerRadius: CGFloat = 6
    @ObservedObject private var player = AudioPlayer.shared

    var body: some View {
        if player.current?.Id == trackId {
            ZStack {
                Color.black.opacity(0.45)
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// Cross-platform shimmer placeholder for loading artwork. A faint gradient
/// stripe sweeps across a muted background until the real image lands.
struct ShimmerView: View {
    var cornerRadius: CGFloat = 8
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.white.opacity(0.06)
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0),    location: 0.0),
                        .init(color: .white.opacity(0.18), location: 0.5),
                        .init(color: .white.opacity(0),    location: 1.0)
                    ],
                    startPoint: UnitPoint(x: phase, y: 0.5),
                    endPoint:   UnitPoint(x: phase + 0.6, y: 0.5)
                )
                .blendMode(.plusLighter)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                phase = 1.4
            }
        }
    }
}
