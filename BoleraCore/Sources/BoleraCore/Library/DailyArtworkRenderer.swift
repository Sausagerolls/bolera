import Foundation
import CoreGraphics
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Composes a rectangular tile image from a daily playlist's top artists' artwork,
/// then overlays the playlist name in a legible style. Cross-platform: CGContext only.
public enum DailyArtworkRenderer {

    private static let targetSize = CGSize(width: 720, height: 480)  // 3:2

    public static func render(
        playlist: DailyPlaylist,
        auth: AuthManager,
        client: JellyfinClient
    ) async -> PlatformImage? {
        // Collect 4 unique artist IDs for a 2x2 grid.
        let artistIds = uniqueArtistIds(from: playlist.tracks, max: 4)
        var artistImages: [CGImage] = []
        for id in artistIds {
            if let img = await fetchArtistImage(id: id, auth: auth, client: client) {
                artistImages.append(img)
            }
        }
        // Fall back to album art if too few artist images.
        if artistImages.count < 2 {
            for track in playlist.tracks.prefix(6) {
                if artistImages.count >= 4 { break }
                if let img = await fetchAlbumImage(track: track, auth: auth, client: client) {
                    artistImages.append(img)
                }
            }
        }
        return composeTile(title: playlist.name, images: artistImages)
    }

    // MARK: - Compose

    private static func composeTile(title: String, images: [CGImage]) -> PlatformImage? {
        let size = targetSize
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Flip coordinate system so CoreGraphics draws top-down like UI.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        // 1. Background tint based on hash of title — deterministic.
        let bg = backgroundColor(for: title)
        ctx.setFillColor(bg)
        ctx.fill(CGRect(origin: .zero, size: size))

        // 2. Image mosaic (2x2 or 1 large or 2x1).
        drawMosaic(images: images, in: ctx, canvas: CGRect(origin: .zero, size: size))

        // 3. Bottom-half gradient overlay for legibility.
        if let gradient = CGGradient(colorsSpace: colorSpace,
                                     colors: [
                                        CGColor(red: 0, green: 0, blue: 0, alpha: 0.0),
                                        CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)
                                     ] as CFArray,
                                     locations: [0.0, 1.0]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: size.width / 2, y: size.height * 0.35),
                                   end: CGPoint(x: size.width / 2, y: size.height),
                                   options: [])
        }

        // 4. Title text.
        drawTitle(title, in: ctx, canvas: CGRect(origin: .zero, size: size))

        guard let cg = ctx.makeImage() else { return nil }

        #if canImport(UIKit)
        return UIImage(cgImage: cg, scale: 2.0, orientation: .up)
        #elseif canImport(AppKit)
        return NSImage(cgImage: cg, size: size)
        #endif
    }

    private static func drawMosaic(images: [CGImage], in ctx: CGContext, canvas: CGRect) {
        // Coordinates: ctx was flipped so we treat top-left origin.
        // After flipping, drawing CGImage with ctx.draw uses the flipped Y, so
        // we save/restore + un-flip per image to keep images upright.
        guard !images.isEmpty else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)

        switch images.count {
        case 1:
            draw(images[0], in: canvas, ctx: ctx)
        case 2:
            let w = canvas.width / 2
            draw(images[0], in: CGRect(x: 0, y: 0, width: w, height: canvas.height), ctx: ctx)
            draw(images[1], in: CGRect(x: w, y: 0, width: w, height: canvas.height), ctx: ctx)
        case 3:
            let half = canvas.width / 2
            let hHalf = canvas.height / 2
            draw(images[0], in: CGRect(x: 0, y: 0, width: half, height: canvas.height), ctx: ctx)
            draw(images[1], in: CGRect(x: half, y: 0, width: half, height: hHalf), ctx: ctx)
            draw(images[2], in: CGRect(x: half, y: hHalf, width: half, height: hHalf), ctx: ctx)
        default:
            let w = canvas.width / 2
            let h = canvas.height / 2
            draw(images[0], in: CGRect(x: 0, y: 0, width: w, height: h), ctx: ctx)
            draw(images[1], in: CGRect(x: w, y: 0, width: w, height: h), ctx: ctx)
            draw(images[2], in: CGRect(x: 0, y: h, width: w, height: h), ctx: ctx)
            draw(images[3], in: CGRect(x: w, y: h, width: w, height: h), ctx: ctx)
        }
        ctx.restoreGState()
    }

    /// Draw image with center-cropped aspect fill into rect.
    private static func draw(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        guard imgW > 0, imgH > 0 else { return }
        let scale = max(rect.width / imgW, rect.height / imgH)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let drawRect = CGRect(
            x: rect.midX - drawW / 2,
            y: rect.midY - drawH / 2,
            width: drawW,
            height: drawH
        )
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.draw(image, in: drawRect)
        ctx.restoreGState()
    }

    private static func drawTitle(_ title: String, in ctx: CGContext, canvas: CGRect) {
        let fontSize: CGFloat = 48
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.9))

        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: white
        ]
        let attrStr = CFAttributedStringCreate(nil, title as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        let lineBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        let x = max(24, (canvas.width - lineBounds.width) / 2)

        // Inside this save+flip block, ctx is back to native CG coords
        // (origin bottom-left, y goes up). Baseline at 32pt up from bottom
        // sits the text inside the dark gradient zone.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: canvas.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: 32)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: - Background tint

    private static func backgroundColor(for title: String) -> CGColor {
        let palette: [(Double, Double, Double)] = [
            (0.13, 0.16, 0.32),  // deep blue
            (0.30, 0.10, 0.34),  // plum
            (0.08, 0.22, 0.20),  // teal
            (0.32, 0.16, 0.10),  // rust
            (0.18, 0.22, 0.10),  // moss
            (0.10, 0.10, 0.20)   // ink
        ]
        let idx = abs(title.hashValue) % palette.count
        let c = palette[idx]
        return CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    }

    // MARK: - Fetching

    private static func uniqueArtistIds(from tracks: [BaseItem], max: Int) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for t in tracks {
            for ai in t.ArtistItems ?? [] {
                if seen.insert(ai.Id).inserted {
                    out.append(ai.Id)
                    if out.count >= max { return out }
                }
            }
            if let aa = t.AlbumArtists?.first, seen.insert(aa.Id).inserted {
                out.append(aa.Id)
                if out.count >= max { return out }
            }
        }
        return out
    }

    private static func fetchArtistImage(id: String, auth: AuthManager, client: JellyfinClient) async -> CGImage? {
        guard let url = client.imageURL(for: id, tag: nil, maxWidth: 480) else { return nil }
        let img = await ImageCache.shared.load(url: url, headers: ["Authorization": auth.authHeader()])
        return img.flatMap { cgImage(from: $0) }
    }

    private static func fetchAlbumImage(track: BaseItem, auth: AuthManager, client: JellyfinClient) async -> CGImage? {
        guard let url = client.imageURL(for: track.artworkItemId, tag: track.artworkTag, maxWidth: 480) else { return nil }
        let img = await ImageCache.shared.load(url: url, headers: ["Authorization": auth.authHeader()])
        return img.flatMap { cgImage(from: $0) }
    }

    private static func cgImage(from img: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        return img.cgImage
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #endif
    }
}

