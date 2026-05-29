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
    /// Bumped each time an async load completes so SwiftUI re-evaluates
    /// the body and picks up the newly-cached image. We don't store the
    /// image in `@State` because that would persist the previous item's
    /// pixels across a cell recycle, causing the wrong artwork to flash
    /// briefly before the new load lands.
    @State private var loadStamp: UUID = UUID()
    @State private var failedItemId: String?

    var body: some View {
        let resolved = resolvedImage()
        // `loadStamp` is read here so the view formally depends on it,
        // triggering a body re-evaluation when a load completes.
        let _ = loadStamp
        return ZStack {
            if let resolved {
                // Size to the frame the caller imposes (via a Color.clear
                // anchor), fill the image into it, then clip at THAT boundary.
                // Clipping the image directly clips to the image's own bounds —
                // so a non-square cover (e.g. a wide 2:1 art) overflows the
                // tile and draws over neighbouring cells. Anchoring + overlay
                // center-crops any aspect ratio to the tile.
                Color.clear
                    .overlay {
                        Image(uiImage: resolved)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else if failedItemId == itemId, itemId != nil {
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
        // NSCache evicts under memory pressure even for items that are
        // still visible (a long playback session through a big library
        // can blow past 600 thumbnails / 200MB). When that happens the
        // mini player would otherwise go blank until the user manually
        // changes tracks — re-fetch on the eviction signal.
        .onReceive(NotificationCenter.default.publisher(for: .imageCacheDidEvict)) { _ in
            if resolvedImage() == nil {
                Task { await reload() }
            }
        }
    }

    /// Synchronously look up the current `itemId`'s image in the memory
    /// cache. When a cell recycles to a new item this lets us render the
    /// correct artwork on the very first frame if it's already cached,
    /// instead of briefly showing the prior cell's image.
    private func resolvedImage() -> UIImage? {
        guard let id = itemId, let url = auth.serverURL else { return nil }
        let client = JellyfinClient(baseURL: url, auth: auth)
        guard let imgURL = client.imageURL(for: id, tag: tag, maxWidth: maxWidth) else { return nil }
        return ImageCache.shared.peekMemory(url: imgURL)
    }

    private func reload() async {
        guard let id = itemId, let url = auth.serverURL else {
            await MainActor.run { failedItemId = itemId }
            return
        }
        let client = JellyfinClient(baseURL: url, auth: auth)
        guard let imgURL = client.imageURL(for: id, tag: tag, maxWidth: maxWidth) else {
            await MainActor.run { failedItemId = id }
            return
        }
        // If it's already in memory, no async work needed — just nudge
        // SwiftUI to re-read it.
        if ImageCache.shared.peekMemory(url: imgURL) != nil {
            await MainActor.run {
                failedItemId = nil
                loadStamp = UUID()
            }
            return
        }
        let loaded = await ImageCache.shared.load(url: imgURL, headers: ["Authorization": auth.authHeader()])
        await MainActor.run {
            if loaded != nil {
                failedItemId = nil
                loadStamp = UUID()
            } else {
                print("[JellyfinImage] Failed to load \(imgURL.absoluteString)")
                failedItemId = id
            }
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
