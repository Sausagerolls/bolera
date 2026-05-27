import SwiftUI
import BoleraCore

struct EQWindow_Mac: View {
    @ObservedObject private var eq = EQManager.shared
    @EnvironmentObject var pro: ProEntitlementStore
    @State private var showPaywall = false

    var body: some View {
        VStack(spacing: 16) {
            // Top bar: enable + preset menu (free + pro)
            HStack {
                Toggle("Enable EQ", isOn: $eq.enabled)
                Spacer()
                Menu("Presets") {
                    ForEach(eq.builtInPresets) { preset in
                        Button(preset.name) { eq.apply(preset: preset) }
                    }
                    if !eq.customPresets.isEmpty {
                        Divider()
                        ForEach(eq.customPresets) { preset in
                            Button(preset.name) { eq.apply(preset: preset) }
                        }
                    }
                    Divider()
                    Button("Reset to Flat") { eq.resetActive() }
                }
            }
            .padding(.horizontal)

            if pro.isPro {
                Picker("Mode", selection: Binding(
                    get: { eq.activeConfig.mode },
                    set: { eq.setMode($0) }
                )) {
                    Text("Graphic").tag(EQMode.graphic)
                    Text("Parametric").tag(EQMode.parametric)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }

            // Band sliders — 5-band for free, 10-band (or parametric) for pro
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Array(eq.activeConfig.bands.enumerated()), id: \.offset) { idx, band in
                    BandColumn_Mac(idx: idx, band: band, enabled: eq.enabled,
                                   isParametric: eq.activeConfig.mode == .parametric)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Text(eq.activeConfig.name)
                .font(.caption).foregroundStyle(.secondary)

            if !pro.isPro {
                Button {
                    showPaywall = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "slider.vertical.3").foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("More Bands & Parametric").bold()
                            Text("Unlock Bolera Pro for 10-band, parametric mode, and custom presets.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical)
        .frame(minWidth: 600, minHeight: 380)
        .onChange(of: pro.isPro) { _, isPro in
            eq.useProConfig = isPro
        }
        .onAppear {
            if pro.isPro && !eq.useProConfig { eq.useProConfig = true }
            if !pro.isPro && eq.useProConfig { eq.useProConfig = false }
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView_Mac().environmentObject(pro)
        }
    }
}

private struct BandColumn_Mac: View {
    let idx: Int
    let band: EQBand
    let enabled: Bool
    let isParametric: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(String(format: "%+.1f dB", band.gain))
                .font(.caption2).monospacedDigit()
            VerticalSlider_Mac(value: Binding(
                get: { Double(band.gain) },
                set: { EQManager.shared.setGain(Float($0), atBand: idx) }
            ), range: -12...12)
                .frame(width: 36, height: 180)
                .disabled(!enabled)
            Text(label(band.frequency))
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            if isParametric {
                Text(String(format: "Q %.1f", band.q))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }

    private func label(_ hz: Float) -> String {
        if hz >= 1000 {
            let k = hz / 1000
            return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(Int(hz))"
    }
}

/// Vertical slider built from a rotated SwiftUI Slider.
private struct VerticalSlider_Mac: View {
    @Binding var value: Double
    var range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            Slider(value: $value, in: range)
                .frame(width: geo.size.height, height: geo.size.width)
                .rotationEffect(.degrees(-90))
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
