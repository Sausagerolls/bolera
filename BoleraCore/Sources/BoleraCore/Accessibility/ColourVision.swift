import SwiftUI
import Observation
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Colour vision modes, shared by iOS and macOS. Each mode picks a highlight
/// colour that stays distinct for that viewer, a readable text colour for it,
/// and how album art is adjusted. `custom` lets someone who's weak in several
/// colours say which, and derives the rest (or lets them choose directly).
public enum ColourVisionMode: String, CaseIterable, Identifiable, Sendable {
    case standard, protanopia, deuteranopia, tritanopia, monochrome, custom

    /// The mode currently selected in Settings (observation-tracked).
    public static var current: ColourVisionMode { ColourVisionSettings.shared.mode }

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .standard: return "Standard"
        case .protanopia: return "Protanopia (red-weak)"
        case .deuteranopia: return "Deuteranopia (green-weak)"
        case .tritanopia: return "Tritanopia (blue-weak)"
        case .monochrome: return "Monochrome"
        case .custom: return "Custom"
        }
    }
}

/// A colour someone can mark as hard to see or tell apart (custom mode).
public enum WeakColour: String, CaseIterable, Identifiable, Sendable {
    case red, green, blue, yellow, purple
    public var id: String { rawValue }
    public var name: String { rawValue.capitalized }
}

/// Highlight colours on offer. Okabe–Ito colour-blind-safe palette, lightened
/// where needed to read on Bolera's dark background.
public enum HighlightColour: String, CaseIterable, Identifiable, Sendable {
    case skyBlue, orange, yellow, bluishGreen, vermilion, reddishPurple, white

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .skyBlue: return "Sky blue"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .bluishGreen: return "Bluish green"
        case .vermilion: return "Vermilion"
        case .reddishPurple: return "Reddish purple"
        case .white: return "White"
        }
    }

    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .skyBlue: return (0.34, 0.71, 0.91)        // #56B4E9
        case .orange: return (0.90, 0.62, 0.00)         // #E69F00
        case .yellow: return (0.94, 0.89, 0.26)         // #F0E442
        case .bluishGreen: return (0.18, 0.74, 0.56)    // #009E73, lightened
        case .vermilion: return (1.00, 0.44, 0.27)      // #FF7045
        case .reddishPurple: return (0.88, 0.55, 0.75)  // #CC79A7, lightened
        case .white: return (1, 1, 1)
        }
    }

    public var color: Color { Color(red: rgb.r, green: rgb.g, blue: rgb.b) }

    /// Readable text/icon colour on this highlight (WCAG relative luminance).
    public var onColour: Color {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let l = 0.2126 * lin(rgb.r) + 0.7152 * lin(rgb.g) + 0.0722 * lin(rgb.b)
        // Black text beats white once luminance passes ~0.18.
        return l > 0.18 ? .black : .white
    }

    /// Hues this colour relies on — it's avoided for anyone weak in them.
    var reliesOn: Set<WeakColour> {
        switch self {
        case .skyBlue: return [.blue]
        case .orange: return [.red, .yellow]
        case .yellow: return [.yellow]
        case .bluishGreen: return [.green, .blue]
        case .vermilion: return [.red]
        case .reddishPurple: return [.red, .purple]
        case .white: return []
        }
    }

    /// First colour (in preference order) that avoids every weak colour;
    /// white if none does.
    static func automatic(avoiding weak: Set<WeakColour>) -> HighlightColour {
        let preference: [HighlightColour] = [.skyBlue, .orange, .yellow, .bluishGreen, .vermilion, .reddishPurple]
        return preference.first { $0.reliesOn.isDisjoint(with: weak) } ?? .white
    }
}

/// How album art is adjusted.
public enum ArtworkTreatment: String, CaseIterable, Identifiable, Sendable {
    case unchanged, redWeak, greenWeak, blueYellow, greyscale

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .unchanged: return "Unchanged"
        case .redWeak: return "Correct for red"
        case .greenWeak: return "Correct for green"
        case .blueYellow: return "Correct for blue–yellow"
        case .greyscale: return "Greyscale + contrast"
        }
    }

    /// Picks a treatment from the colours someone is weak in. Weak on both the
    /// red–green and blue–yellow axes means no single hue shift helps, so
    /// brightness carries the image instead. Purple weakness is the red end of
    /// purple going missing (it reads as blue), so it's treated as red.
    static func automatic(for weak: Set<WeakColour>) -> ArtworkTreatment {
        let redGreen = !weak.isDisjoint(with: [.red, .green, .purple])
        let blueYellow = !weak.isDisjoint(with: [.blue, .yellow])
        if redGreen && blueYellow { return .greyscale }
        if weak.contains(.red) || weak.contains(.purple) { return .redWeak }
        if weak.contains(.green) { return .greenWeak }
        if blueYellow { return .blueYellow }
        return .unchanged
    }

    /// Daltonization matrix (row-major 3×3, linear RGB): out = (I + S·(I − M))·rgb,
    /// where M simulates the deficiency (Machado et al. 2009, full severity) and
    /// S (Fidaner et al.) shifts the colour information that viewer can't see
    /// into channels they can. Rows sum to 1, so greys are unchanged. Nil for
    /// unchanged and greyscale (handled separately).
    var matrix: [Double]? {
        let m: [Double]
        switch self {
        case .unchanged, .greyscale: return nil
        case .redWeak:
            m = [0.152286, 1.052583, -0.204868,
                 0.114503, 0.786281, 0.099216,
                 -0.003882, -0.048116, 1.051998]
        case .greenWeak:
            m = [0.367322, 0.860646, -0.227968,
                 0.280085, 0.672501, 0.047413,
                 -0.011820, 0.042940, 0.968881]
        case .blueYellow:
            m = [1.255528, -0.076749, -0.178779,
                 -0.078411, 0.930809, 0.147602,
                 0.004733, 0.691367, 0.303900]
        }
        let shift: [Double] = [0, 0, 0,
                               0.7, 1, 0,
                               0.7, 0, 1]
        var e = [Double](repeating: 0, count: 9)          // e = I − M
        for i in 0..<9 { e[i] = (i % 4 == 0 ? 1 : 0) - m[i] }
        var out = [Double](repeating: 0, count: 9)        // out = I + shift·e
        for r in 0..<3 {
            for c in 0..<3 {
                var v = r == c ? 1.0 : 0.0
                for k in 0..<3 { v += shift[r * 3 + k] * e[k * 3 + c] }
                out[r * 3 + c] = v
            }
        }
        return out
    }
}

/// The selected colour vision settings, persisted to UserDefaults.
///
/// `@Observable`, so any view whose body reads it — including indirectly via
/// `Color.boleraAccent` or `Image(artwork:)` — redraws when it changes. That
/// replaces rebuilding the whole window on a change, which reset navigation
/// (iOS jumped back to the Home tab mid-adjustment).
@Observable
public final class ColourVisionSettings {
    public static let shared = ColourVisionSettings()

    private enum Key {
        static let mode = "bolera.colourVision"
        static let weak = "bolera.colourVision.weak"
        static let highlight = "bolera.colourVision.highlight"
        static let artwork = "bolera.colourVision.artwork"
    }

    public var mode: ColourVisionMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Key.mode) }
    }
    /// Custom mode: colours the viewer finds hard to see or tell apart.
    public var weakColours: Set<WeakColour> {
        didSet { UserDefaults.standard.set(weakColours.map(\.rawValue).sorted(), forKey: Key.weak) }
    }
    /// Custom mode: chosen highlight, or nil to pick one automatically.
    public var customHighlight: HighlightColour? {
        didSet { UserDefaults.standard.set(customHighlight?.rawValue, forKey: Key.highlight) }
    }
    /// Custom mode: chosen artwork treatment, or nil to pick automatically.
    public var customArtwork: ArtworkTreatment? {
        didSet { UserDefaults.standard.set(customArtwork?.rawValue, forKey: Key.artwork) }
    }

    private init() {
        let d = UserDefaults.standard
        mode = ColourVisionMode(rawValue: d.string(forKey: Key.mode) ?? "") ?? .standard
        weakColours = Set((d.stringArray(forKey: Key.weak) ?? []).compactMap(WeakColour.init(rawValue:)))
        customHighlight = d.string(forKey: Key.highlight).flatMap(HighlightColour.init(rawValue:))
        customArtwork = d.string(forKey: Key.artwork).flatMap(ArtworkTreatment.init(rawValue:))
    }

    /// The highlight in use; nil = Bolera's standard purple.
    public var highlight: HighlightColour? {
        switch mode {
        case .standard: return nil
        case .protanopia, .deuteranopia: return .skyBlue
        case .tritanopia: return .vermilion
        case .monochrome: return .white
        case .custom: return customHighlight ?? automaticHighlight
        }
    }
    /// What custom mode's "Automatic" highlight resolves to.
    public var automaticHighlight: HighlightColour { .automatic(avoiding: weakColours) }

    /// The colour vision highlight when a mode is on; otherwise the theme's
    /// accent (fixed colour or album art — Settings › Appearance).
    public var accent: Color { highlight?.color ?? ThemeSettings.shared.accent }
    public var onAccent: Color { highlight?.onColour ?? ThemeSettings.shared.onAccent }

    public var artwork: ArtworkTreatment {
        switch mode {
        case .standard: return .unchanged
        case .protanopia: return .redWeak
        case .deuteranopia: return .greenWeak
        case .tritanopia: return .blueYellow
        case .monochrome: return .greyscale
        case .custom: return customArtwork ?? automaticArtwork
        }
    }
    /// What custom mode's "Automatic" artwork treatment resolves to.
    public var automaticArtwork: ArtworkTreatment { .automatic(for: weakColours) }

    /// Every non-standard mode also marks active controls with a dot where the
    /// UI supports it, so "on" never depends on colour alone.
    public var showsActiveIndicator: Bool { mode != .standard }

    /// Two-way binding for one weak-colour toggle.
    public func isWeak(_ c: WeakColour) -> Binding<Bool> {
        Binding(get: { self.weakColours.contains(c) },
                set: { on in
                    if on { self.weakColours.insert(c) } else { self.weakColours.remove(c) }
                })
    }
}

/// Adjusts artwork for the current colour vision settings: daltonization for
/// colour deficiencies, greyscale with boosted contrast where no hue shift can
/// help. Results are cached per image object; the cache is dropped when the
/// treatment changes.
@MainActor
public enum ArtworkCorrector {
    private static let context = CIContext()
    private static let cache = NSCache<PlatformImage, PlatformImage>()
    private static var cachedTreatment: ArtworkTreatment = .unchanged
    /// Greyscale contrast boost (1 = unchanged).
    private static let greyscaleContrast: Float = 1.3

    public static func corrected(_ image: PlatformImage) -> PlatformImage {
        let treatment = ColourVisionSettings.shared.artwork
        guard treatment != .unchanged else { return image }
        if treatment != cachedTreatment {
            cache.removeAllObjects()
            cachedTreatment = treatment
        }
        if let hit = cache.object(forKey: image) { return hit }
        #if canImport(UIKit)
        guard let cg = image.cgImage else { return image }
        #else
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        #endif
        let input = CIImage(cgImage: cg)
        let filtered: CIImage?
        if let m = treatment.matrix {
            let f = CIFilter.colorMatrix()
            f.inputImage = input
            f.rVector = CIVector(x: m[0], y: m[1], z: m[2], w: 0)
            f.gVector = CIVector(x: m[3], y: m[4], z: m[5], w: 0)
            f.bVector = CIVector(x: m[6], y: m[7], z: m[8], w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            filtered = f.outputImage
        } else {
            // Greyscale: drop saturation, stretch contrast around mid-grey.
            let f = CIFilter.colorControls()
            f.inputImage = input
            f.saturation = 0
            f.contrast = greyscaleContrast
            filtered = f.outputImage
        }
        guard let out = filtered?.cropped(to: input.extent),
              let outCG = context.createCGImage(out, from: input.extent) else { return image }
        #if canImport(UIKit)
        let result = UIImage(cgImage: outCG, scale: image.scale, orientation: image.imageOrientation)
        #else
        let result = NSImage(cgImage: outCG, size: image.size)
        #endif
        cache.setObject(result, forKey: image)
        return result
    }
}

extension Image {
    /// Artwork image, adjusted for the current colour vision settings.
    @MainActor public init(artwork: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: ArtworkCorrector.corrected(artwork))
        #else
        self.init(nsImage: ArtworkCorrector.corrected(artwork))
        #endif
    }
}

/// Tints system controls (sliders, toggles, progress…) with the current
/// highlight. Apply at each window/scene root. Updates in place — no rebuild.
public struct ColourVisionRoot: ViewModifier {
    public init() {}
    public func body(content: Content) -> some View {
        content.tint(ColourVisionSettings.shared.accent)
    }
}

extension View {
    public func boleraColourVision() -> some View { modifier(ColourVisionRoot()) }
}

extension Color {
    /// Bolera's accent under the current colour vision settings. Use instead of
    /// `Color.accentColor`, which always resolves to the asset purple.
    public static var boleraAccent: Color { ColourVisionSettings.shared.accent }
    /// Readable text/icon colour for content drawn on `boleraAccent`.
    public static var onBoleraAccent: Color { ColourVisionSettings.shared.onAccent }
}
