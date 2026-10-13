import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Colour vision modes, shared by iOS and macOS. Each mode swaps Bolera's
/// purple accent for one that stays distinct under that colour-vision
/// deficiency, says which text colour reads on it, and supplies a
/// daltonization matrix that colour-corrects artwork.
///
/// Accents are from the Okabe–Ito colour-blind-safe palette, lightened where
/// needed to read on Bolera's dark background.
public enum ColourVisionMode: String, CaseIterable, Identifiable, Sendable {
    case standard, protanopia, deuteranopia, tritanopia, monochrome

    /// UserDefaults / @AppStorage key holding the selected mode's raw value.
    public static let storageKey = "bolera.colourVision"

    /// The mode currently selected in Settings.
    public static var current: ColourVisionMode {
        ColourVisionMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .standard
    }

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .standard: return "Standard"
        case .protanopia: return "Protanopia (red-weak)"
        case .deuteranopia: return "Deuteranopia (green-weak)"
        case .tritanopia: return "Tritanopia (blue-weak)"
        case .monochrome: return "Monochrome"
        }
    }

    public var accent: Color {
        switch self {
        case .standard: return Color.accentColor   // the asset purple
        // Red-green deficiencies: sky blue stays clear of the red/green axis
        // (Bolera's purple reads as plain blue-grey to them anyway).
        case .protanopia, .deuteranopia: return Color(red: 0.34, green: 0.71, blue: 0.91)  // #56B4E9
        // Blue-yellow deficiency: vermilion stays distinct from blues and greys.
        case .tritanopia: return Color(red: 1.0, green: 0.44, blue: 0.27)                 // #FF7045
        case .monochrome: return .white
        }
    }

    /// Text/icon colour that stays readable ON the accent: the light accents
    /// (sky blue, vermilion, white) need dark text.
    public var onAccent: Color { self == .standard ? .white : .black }

    /// Every non-standard mode also marks active controls with a dot where the
    /// UI supports it, so "on" never depends on colour alone.
    public var showsActiveIndicator: Bool { self != .standard }

    /// Daltonization matrix (row-major 3×3, linear RGB) for artwork:
    /// out = (I + S·(I − M))·rgb, where M simulates the deficiency (Machado et
    /// al. 2009, full severity) and S (Fidaner et al.) shifts the colour
    /// information that viewer can't see into channels they can. Rows sum to 1,
    /// so greys are unchanged. Nil for standard (untouched) and monochrome,
    /// which gets greyscale + contrast instead (see `ArtworkCorrector`).
    public var artworkMatrix: [Double]? {
        let m: [Double]
        switch self {
        case .standard, .monochrome: return nil
        case .protanopia:
            m = [0.152286, 1.052583, -0.204868,
                 0.114503, 0.786281, 0.099216,
                 -0.003882, -0.048116, 1.051998]
        case .deuteranopia:
            m = [0.367322, 0.860646, -0.227968,
                 0.280085, 0.672501, 0.047413,
                 -0.011820, 0.042940, 0.968881]
        case .tritanopia:
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

/// Colour-corrects artwork for the current colour vision mode: daltonization
/// for the colour-deficiency modes, greyscale with boosted contrast for
/// monochrome (no hue shift can help there, so brightness differences carry
/// the image instead). Results are cached per image object; the cache is
/// dropped when the mode changes.
@MainActor
public enum ArtworkCorrector {
    private static let context = CIContext()
    private static let cache = NSCache<PlatformImage, PlatformImage>()
    private static var cachedMode: ColourVisionMode = .standard
    /// Monochrome contrast boost (1 = unchanged).
    private static let monochromeContrast: Float = 1.3

    public static func corrected(_ image: PlatformImage) -> PlatformImage {
        let mode = ColourVisionMode.current
        guard mode != .standard else { return image }
        if mode != cachedMode {
            cache.removeAllObjects()
            cachedMode = mode
        }
        if let hit = cache.object(forKey: image) { return hit }
        #if canImport(UIKit)
        guard let cg = image.cgImage else { return image }
        #else
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        #endif
        let input = CIImage(cgImage: cg)
        let filtered: CIImage?
        if let m = mode.artworkMatrix {
            let f = CIFilter.colorMatrix()
            f.inputImage = input
            f.rVector = CIVector(x: m[0], y: m[1], z: m[2], w: 0)
            f.gVector = CIVector(x: m[3], y: m[4], z: m[5], w: 0)
            f.bVector = CIVector(x: m[6], y: m[7], z: m[8], w: 0)
            f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            filtered = f.outputImage
        } else {
            // Monochrome: drop saturation, stretch contrast around mid-grey.
            let f = CIFilter.colorControls()
            f.inputImage = input
            f.saturation = 0
            f.contrast = monochromeContrast
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
    /// Artwork image, colour-corrected for the current colour vision mode.
    @MainActor public init(artwork: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: ArtworkCorrector.corrected(artwork))
        #else
        self.init(nsImage: ArtworkCorrector.corrected(artwork))
        #endif
    }
}

/// Applies the colour vision mode to a window: tints system controls with the
/// mode's accent and rebuilds the view tree when the mode changes, so views
/// reading `ColourVisionMode.current` pick up the new colours.
public struct ColourVisionRoot: ViewModifier {
    @AppStorage(ColourVisionMode.storageKey) private var mode = ColourVisionMode.standard.rawValue
    public init() {}
    public func body(content: Content) -> some View {
        content
            .tint((ColourVisionMode(rawValue: mode) ?? .standard).accent)
            .id(mode)
    }
}

extension View {
    /// Apply at each window/scene root.
    public func boleraColourVision() -> some View { modifier(ColourVisionRoot()) }
}

extension Color {
    /// Bolera's accent under the current colour vision mode. Use instead of
    /// `Color.accentColor`, which always resolves to the asset purple.
    public static var boleraAccent: Color { ColourVisionMode.current.accent }
    /// Readable text/icon colour for content drawn on `boleraAccent`.
    public static var onBoleraAccent: Color { ColourVisionMode.current.onAccent }
}
