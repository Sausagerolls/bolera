import SwiftUI
import WidgetKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Decode App Group artwork bytes into a SwiftUI `Image`, cross-platform.
func widgetImage(from data: Data?) -> Image? {
    guard let data else { return nil }
    #if canImport(UIKit)
    if let ui = UIImage(data: data) { return Image(uiImage: ui) }
    #elseif canImport(AppKit)
    if let ns = NSImage(data: data) { return Image(nsImage: ns) }
    #endif
    return nil
}

/// Square artwork with a branded placeholder when no cover is available.
struct ArtworkSquare: View {
    let image: Image?
    var corner: CGFloat = 8

    var body: some View {
        ZStack {
            if let image {
                image.resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: corner).fill(.white.opacity(0.10))
                Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6))
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

struct WidgetEmptyState: View {
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note").font(.title2)
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(.white)
    }
}

/// Shared dark gradient backing for the home-screen library widgets.
let widgetTileGradient = LinearGradient(
    colors: [Color(red: 0.16, green: 0.13, blue: 0.24),
             Color(red: 0.08, green: 0.08, blue: 0.12)],
    startPoint: .topLeading, endPoint: .bottomTrailing)
