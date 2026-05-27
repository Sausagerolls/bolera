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
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.white.opacity(0.06))
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: itemId) { await reload() }
    }

    private func reload() async {
        guard let id = itemId, let url = auth.serverURL else { image = nil; return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        guard let imgURL = client.imageURL(for: id, tag: tag, maxWidth: maxWidth) else { return }
        let loaded = await ImageCache.shared.load(url: imgURL, headers: ["Authorization": auth.authHeader()])
        if loaded == nil {
            print("[JellyfinImage] Failed to load \(imgURL.absoluteString)")
        }
        await MainActor.run { self.image = loaded }
    }
}
