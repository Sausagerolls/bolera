import SwiftUI
import Combine
import CoreGraphics
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// An sRGB colour that can be stored, compared and turned into a SwiftUI
/// `Color`. Used for the theme accent.
public struct ThemeRGB: Equatable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double

    public init(r: Double, g: Double, b: Double) {
        self.r = min(max(r, 0), 1); self.g = min(max(g, 0), 1); self.b = min(max(b, 0), 1)
    }

    /// Bolera's own purple (AccentColor asset).
    public static let bolera = ThemeRGB(r: 0.682, g: 0.357, b: 0.918)

    public var color: Color { Color(red: r, green: g, blue: b) }

    /// Readable text/icon colour on this colour (WCAG relative luminance).
    public var onColour: Color {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        return l > 0.18 ? .black : .white
    }

    /// "#AE5BEA", for storage.
    public var hex: String {
        String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    public init?(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    /// From a SwiftUI colour (e.g. a ColorPicker), converted to sRGB.
    public init?(_ color: Color) {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        self.init(r: r, g: g, b: b)
        #else
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        self.init(r: c.redComponent, g: c.greenComponent, b: c.blueComponent)
        #endif
    }

    // HSB helpers for the artwork extraction and dark-UI adjustment.
    var hsb: (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    init(h: Double, s: Double, v: Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: self.init(r: v, g: t, b: p)
        case 1: self.init(r: q, g: v, b: p)
        case 2: self.init(r: p, g: v, b: t)
        case 3: self.init(r: p, g: q, b: v)
        case 4: self.init(r: t, g: p, b: v)
        default: self.init(r: v, g: p, b: q)
        }
    }
}

/// Ready-made accent choices shown as swatches.
public enum AccentPreset: String, CaseIterable, Identifiable {
    case purple, blue, teal, green, yellow, orange, red, pink

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .purple: return "Bolera Purple"
        case .blue: return "Blue"
        case .teal: return "Teal"
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .orange: return "Orange"
        case .red: return "Red"
        case .pink: return "Pink"
        }
    }

    public var rgb: ThemeRGB {
        switch self {
        case .purple: return .bolera
        case .blue: return ThemeRGB(r: 0.25, g: 0.56, b: 1.00)
        case .teal: return ThemeRGB(r: 0.19, g: 0.78, b: 0.76)
        case .green: return ThemeRGB(r: 0.30, g: 0.82, b: 0.42)
        case .yellow: return ThemeRGB(r: 1.00, g: 0.82, b: 0.20)
        case .orange: return ThemeRGB(r: 1.00, g: 0.58, b: 0.20)
        case .red: return ThemeRGB(r: 1.00, g: 0.33, b: 0.35)
        case .pink: return ThemeRGB(r: 1.00, g: 0.42, b: 0.71)
        }
    }
}

/// Where the accent colour comes from.
public enum AccentSource: String, CaseIterable, Identifiable {
    /// A colour the user picked (Bolera purple by default).
    case fixed
    /// Follows the playing track's album art.
    case albumArt

    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .fixed: return "Fixed colour"
        case .albumArt: return "Match album art"
        }
    }
}

/// Theme settings: the app's accent colour, fixed or following album art.
///
/// `@Observable` like `ColourVisionSettings`: views reading `Color.boleraAccent`
/// redraw in place when the accent changes, including on every track change
/// in album-art mode. Colour vision modes other than Standard take priority —
/// they exist to keep the highlight readable, so a theme can't undo them.
@Observable
public final class ThemeSettings {
    public static let shared = ThemeSettings()

    private enum Key {
        static let source = "bolera.theme.accentSource"
        static let colour = "bolera.theme.accentColour"
        static let lastAlbum = "bolera.theme.lastAlbumColour"
    }

    public var source: AccentSource {
        didSet { UserDefaults.standard.set(source.rawValue, forKey: Key.source) }
    }
    /// The fixed accent, and the fallback when album art has no strong colour.
    public var colour: ThemeRGB {
        didSet { UserDefaults.standard.set(colour.hex, forKey: Key.colour) }
    }
    /// Colour taken from the playing track's artwork; nil when the artwork is
    /// greyscale/muted (the fixed colour is used instead).
    public private(set) var albumColour: ThemeRGB? {
        didSet { UserDefaults.standard.set(albumColour?.hex, forKey: Key.lastAlbum) }
    }

    @ObservationIgnored private var cancellable: AnyCancellable?

    private init() {
        let d = UserDefaults.standard
        source = AccentSource(rawValue: d.string(forKey: Key.source) ?? "") ?? .fixed
        colour = d.string(forKey: Key.colour).flatMap(ThemeRGB.init(hex:)) ?? .bolera
        // Last track's colour, so a relaunch doesn't flash purple before the
        // restored artwork loads.
        albumColour = d.string(forKey: Key.lastAlbum).flatMap(ThemeRGB.init(hex:))
        cancellable = AudioPlayer.shared.$artwork
            .compactMap { $0 }      // keep the old colour across the gap between tracks
            .receive(on: DispatchQueue.global(qos: .utility))
            .map { AlbumColourExtractor.accent(from: $0) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] c in
                guard let self, self.albumColour != c else { return }
                withAnimation(.easeInOut(duration: 0.6)) { self.albumColour = c }
            }
    }

    /// The accent the theme asks for.
    public var accentRGB: ThemeRGB {
        switch source {
        case .fixed: return colour
        case .albumArt: return albumColour ?? colour
        }
    }

    public var accent: Color { accentRGB == .bolera ? Color.accentColor : accentRGB.color }
    /// Bolera purple keeps its long-standing white text (it sits right on the
    /// luminance threshold); every other accent picks black or white by contrast.
    public var onAccent: Color { accentRGB == .bolera ? .white : accentRGB.onColour }

    /// The preset matching the fixed colour, if any (nil = custom colour).
    public var preset: AccentPreset? { AccentPreset.allCases.first { $0.rgb == colour } }
}

/// Picks a vivid, readable accent from album artwork.
enum AlbumColourExtractor {
    /// Downsample, bucket the saturated pixels by hue, take the strongest
    /// bucket's average, then lift it to stay legible on Bolera's dark UI.
    /// Nil when the artwork has too little colour to choose from.
    static func accent(from image: PlatformImage) -> ThemeRGB? {
        #if canImport(UIKit)
        guard let cg = image.cgImage else { return nil }
        #else
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        #endif
        let side = 32
        var px = [UInt8](repeating: 0, count: side * side * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }

        let bins = 18
        var weight = [Double](repeating: 0, count: bins)
        var sum = [(r: Double, g: Double, b: Double)](repeating: (0, 0, 0), count: bins)
        var vivid = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let c = ThemeRGB(r: Double(px[i]) / 255, g: Double(px[i + 1]) / 255, b: Double(px[i + 2]) / 255)
            let (h, s, v) = c.hsb
            guard s > 0.25, v > 0.2 else { continue }
            vivid += 1
            let w = s * s * s * v
            let k = min(Int(h * Double(bins)), bins - 1)
            weight[k] += w
            sum[k].r += c.r * w; sum[k].g += c.g * w; sum[k].b += c.b * w
        }
        // Under ~4% colourful pixels reads as a black-and-white cover.
        guard vivid >= side * side / 25,
              let best = weight.indices.max(by: { weight[$0] < weight[$1] }), weight[best] > 0 else { return nil }
        let avg = ThemeRGB(r: sum[best].r / weight[best], g: sum[best].g / weight[best], b: sum[best].b / weight[best])
        let (h, s, v) = avg.hsb
        // Bright and saturated enough to stand out on the near-black background,
        // without going neon.
        return ThemeRGB(h: h, s: min(max(s, 0.55), 0.85), v: max(v, 0.85))
    }
}
