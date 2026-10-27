import SwiftUI

/// Colour vision settings as List/Form sections, shared by the iOS
/// Accessibility screen and the macOS General settings tab. Edits apply live
/// and in place — the screen stays put so the user can keep adjusting.
public struct ColourVisionSettingsSections: View {
    @Bindable private var settings = ColourVisionSettings.shared

    public init() {}

    public var body: some View {
        Section {
            Picker("Colour vision", selection: $settings.mode) {
                ForEach(ColourVisionMode.allCases) { m in
                    Text(m.name).tag(m)
                }
            }
            #if os(iOS)
            .pickerStyle(.inline)
            .labelsHidden()
            #endif
        } header: {
            Text("Colour vision")
        } footer: {
            Text(modeFooter)
        }

        if settings.mode == .custom {
            Section {
                ForEach(WeakColour.allCases) { c in
                    Toggle(isOn: settings.isWeak(c)) {
                        Label {
                            Text(c.name)
                        } icon: {
                            Circle().fill(sample(c)).frame(width: 14, height: 14)
                        }
                    }
                }
            } header: {
                Text("Colours I find hard to see or tell apart")
            } footer: {
                Text("Tick every colour that gives you trouble. Bolera picks a highlight colour that avoids them all, and an album art adjustment to match — or choose your own below.")
            }

            Section {
                Picker("Highlight colour", selection: $settings.customHighlight) {
                    Text("Automatic (\(settings.automaticHighlight.name))").tag(HighlightColour?.none)
                    ForEach(HighlightColour.allCases) { h in
                        Label {
                            Text(h.name)
                        } icon: {
                            Circle().fill(h.color).frame(width: 14, height: 14)
                        }
                        .tag(HighlightColour?.some(h))
                    }
                }
                Picker("Album art", selection: $settings.customArtwork) {
                    Text("Automatic (\(settings.automaticArtwork.name))").tag(ArtworkTreatment?.none)
                    ForEach(ArtworkTreatment.allCases) { t in
                        Text(t.name).tag(ArtworkTreatment?.some(t))
                    }
                }
            } header: {
                Text("Custom adjustments")
            } footer: {
                Text("If the automatic choice still isn't clear, try the others — what works best varies from person to person.")
            }
        }

        Section("Preview") {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.boleraAccent)
                    .frame(width: 44, height: 44)
                    .overlay(Image(systemName: "play.fill").foregroundStyle(Color.onBoleraAccent))
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.highlight?.name ?? "Your theme accent")
                    Text("Album art: \(settings.artwork.name)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modeFooter: String {
        switch settings.mode {
        case .standard:
            return "Bolera's usual purple highlight and unchanged album art."
        case .custom:
            return "For anyone weak in more than one colour, or whom the presets don't suit."
        default:
            return "Replaces the purple highlight with a colour that stays distinct for that type of colour blindness, keeps text on it readable, adjusts album art so colours you'd otherwise confuse stand apart, and marks switched-on controls with a dot where supported. Monochrome shows album art in greyscale with boosted contrast."
        }
    }

    private func sample(_ c: WeakColour) -> Color {
        switch c {
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        case .yellow: return .yellow
        case .purple: return .purple
        }
    }
}
