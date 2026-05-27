import SwiftUI
import BoleraCore

/// Free users see: enable toggle + preset picker. Per-band tweaking is paywalled.
/// Pro users see: enable + mode picker + per-band sliders + presets + save.
struct EQView: View {
    @ObservedObject private var eq = EQManager.shared
    @EnvironmentObject var pro: ProEntitlementStore

    @State private var showSaveSheet = false
    @State private var newPresetName: String = ""
    @State private var showPaywall = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Equalizer", isOn: $eq.enabled)
            } footer: {
                Text("Sound shaping applied to all playback.")
            }

            if pro.isPro {
                Section {
                    Picker("Mode", selection: Binding(
                        get: { eq.activeConfig.mode },
                        set: { eq.setMode($0) }
                    )) {
                        Text("Graphic").tag(EQMode.graphic)
                        Text("Parametric").tag(EQMode.parametric)
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section(header: bandsHeader) {
                ForEach(Array(eq.activeConfig.bands.enumerated()), id: \.offset) { idx, band in
                    bandRow(idx: idx, band: band)
                }
            }

            if !pro.isPro {
                Section {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "slider.vertical.3")
                                .font(.title3).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("More Bands & Parametric").bold()
                                Text("Unlock Bolera Pro for 10-band, parametric mode, and custom preset saving.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                            ProBadge()
                        }
                    }
                }
            }

            Section("Presets") {
                ForEach(eq.builtInPresets) { preset in
                    presetRow(preset)
                }
                if !eq.customPresets.isEmpty {
                    DisclosureGroup("Your Presets") {
                        ForEach(eq.customPresets) { preset in
                            presetRow(preset, deletable: true)
                        }
                    }
                }
                if pro.isPro {
                    Button {
                        newPresetName = ""
                        showSaveSheet = true
                    } label: {
                        Label("Save Current as Preset…", systemImage: "square.and.arrow.down")
                    }
                }
                Button(role: .destructive) {
                    eq.resetActive()
                } label: {
                    Text("Reset to Flat")
                }
            }
        }
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pro.isPro) { _, isPro in
            eq.useProConfig = isPro
        }
        .onAppear {
            if pro.isPro && !eq.useProConfig { eq.useProConfig = true }
            if !pro.isPro && eq.useProConfig { eq.useProConfig = false }
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack { PaywallView() }.environmentObject(pro)
        }
        .alert("Save Preset", isPresented: $showSaveSheet) {
            TextField("Name", text: $newPresetName)
            Button("Save") {
                let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { eq.savePreset(named: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give this EQ setting a name so you can recall it later.")
        }
    }

    // MARK: - Sections

    private var bandsHeader: some View {
        HStack {
            Text("Bands")
            Spacer()
            Text(eq.activeConfig.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func bandRow(idx: Int, band: EQBand) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label(forHz: band.frequency)).font(.subheadline).monospaced()
                Spacer()
                Text(String(format: "%+.1f dB", band.gain))
                    .font(.caption).foregroundStyle(.secondary).monospaced()
            }
            Slider(value: Binding(
                get: { Double(band.gain) },
                set: { eq.setGain(Float($0), atBand: idx) }
            ), in: -12...12, step: 0.5)
            .disabled(!eq.enabled)

            if eq.activeConfig.mode == .parametric {
                HStack {
                    Text("Freq").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(band.frequency) },
                        set: { eq.setFrequency(Float($0), atBand: idx) }
                    ), in: 20...20_000)
                    .disabled(!eq.enabled)
                    Text("Q").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(band.q) },
                        set: { eq.setQ(Float($0), atBand: idx) }
                    ), in: 0.3...3.0, step: 0.1)
                    .disabled(!eq.enabled)
                    Text(String(format: "%.1f", band.q))
                        .font(.caption2).foregroundStyle(.secondary).monospaced()
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func presetRow(_ preset: EQConfig, deletable: Bool = false) -> some View {
        Button {
            eq.apply(preset: preset)
        } label: {
            HStack {
                Text(preset.name)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .disabled(!eq.enabled)
        .swipeActions {
            if deletable {
                Button(role: .destructive) {
                    eq.deletePreset(preset)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func label(forHz hz: Float) -> String {
        if hz >= 1000 {
            let kHz = hz / 1000
            return kHz.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(kHz)) kHz" : String(format: "%.1f kHz", kHz)
        }
        return "\(Int(hz)) Hz"
    }
}
