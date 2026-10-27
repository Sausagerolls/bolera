import SwiftUI

/// Theme settings as List/Form sections, shared by the iOS Appearance screen
/// and the macOS Appearance settings tab. Changes apply live.
public struct ThemeSettingsSections: View {
    @Bindable private var theme = ThemeSettings.shared
    private var vision = ColourVisionSettings.shared

    public init() {}

    public var body: some View {
        Section {
            Picker("Accent colour", selection: $theme.source) {
                ForEach(AccentSource.allCases) { s in
                    Text(s.name).tag(s)
                }
            }
            #if os(iOS)
            .pickerStyle(.inline)
            .labelsHidden()
            #endif
        } header: {
            Text("Accent colour")
        } footer: {
            Text(theme.source == .albumArt
                 ? "The accent changes with each track, taken from the most vivid colour in its album art. Black-and-white or muted covers use the colour below."
                 : "Used for buttons, sliders, progress bars and highlights throughout Bolera.")
        }

        Section {
            swatches
            ColorPicker("Custom colour", selection: customBinding, supportsOpacity: false)
            if theme.colour != .bolera {
                Button("Reset to Bolera Purple") { theme.colour = .bolera }
            }
        } header: {
            Text(theme.source == .albumArt ? "Fallback colour" : "Colour")
        }

        Section("Preview") {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.boleraAccent)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "play.fill").foregroundStyle(Color.onBoleraAccent))
                VStack(alignment: .leading, spacing: 6) {
                    Text(previewName)
                    ProgressView(value: 0.6).tint(Color.boleraAccent)
                }
            }
            if vision.mode != .standard {
                Label("Colour vision mode \(vision.mode.name) is on, so its highlight colour is used instead. Set it to Standard under Accessibility to use your theme accent.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var previewName: String {
        switch theme.source {
        case .fixed:
            return theme.preset?.name ?? "Custom colour"
        case .albumArt:
            return theme.albumColour == nil ? "Album art (using fallback)" : "From the current album art"
        }
    }

    private var swatches: some View {
        // Fixed-size circles in a flowing grid, ticked when selected.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 10)], spacing: 10) {
            ForEach(AccentPreset.allCases) { p in
                Button { theme.colour = p.rgb } label: {
                    Circle()
                        .fill(p.rgb.color)
                        .frame(width: 32, height: 32)
                        .overlay {
                            if theme.colour == p.rgb {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(p.rgb == .bolera ? .white : p.rgb.onColour)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.name)
                .accessibilityAddTraits(theme.colour == p.rgb ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private var customBinding: Binding<Color> {
        Binding(
            get: { theme.colour.color },
            set: { if let c = ThemeRGB($0) { theme.colour = c } }
        )
    }
}
