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
