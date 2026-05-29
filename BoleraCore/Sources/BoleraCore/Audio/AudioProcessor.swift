import Foundation
import AVFoundation
import MediaToolbox
import Combine
import Accelerate

// MARK: - Public EQ model

public enum EQMode: String, Codable, CaseIterable, Sendable {
    case graphic
    case parametric
}

public struct EQBand: Codable, Hashable, Sendable {
    public var frequency: Float
    public var gain: Float        // dB, -12...+12
    public var q: Float           // 0.3...3.0

    public init(frequency: Float, gain: Float = 0, q: Float = 1.0) {
        self.frequency = frequency
        self.gain = gain
        self.q = q
    }
}

public struct EQConfig: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: EQMode
    public var bands: [EQBand]

    public init(id: UUID = UUID(), name: String, mode: EQMode, bands: [EQBand]) {
        self.id = id
        self.name = name
        self.mode = mode
        self.bands = bands
    }

    /// Free-tier ISO bands (5-band, matches v1).
    public static let graphicFreqs5: [Float] = [60, 230, 910, 3600, 14000]
    /// Pro-tier ISO bands (10-band).
    public static let graphicFreqs10: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    public static func graphicFlat(bandCount: Int = 10) -> EQConfig {
        let freqs = bandCount == 5 ? graphicFreqs5 : graphicFreqs10
        return EQConfig(
            name: "Flat",
            mode: .graphic,
            bands: freqs.map { EQBand(frequency: $0) }
        )
    }

    public static func parametricFlat() -> EQConfig {
        EQConfig(
            name: "Custom",
            mode: .parametric,
            bands: graphicFreqs10.map { EQBand(frequency: $0, gain: 0, q: 1.0) }
        )
    }

    /// Built-in 10-band graphic presets (Q=1, fixed ISO frequencies).
    public static let builtInPresets: [EQConfig] = [
        .graphicFlat(bandCount: 10),
        preset("Bass Boost",  gains: [ 7,  6,  5,  3,  1, -1, -2, -2, -2, -1]),
        preset("Treble Boost",gains: [-2, -2, -2, -1,  0,  1,  3,  5,  6,  7]),
        preset("Vocal",       gains: [-3, -3, -2, -1,  3,  4,  4,  2,  0, -2]),
        preset("Rock",        gains: [ 5,  4,  3,  2,  0, -1,  1,  3,  4,  4]),
        preset("Jazz",        gains: [ 3,  2,  1,  2,  0, -2,  0,  2,  3,  3]),
        preset("Classical",   gains: [ 4,  3,  2,  1,  0,  0,  0,  2,  3,  3]),
        preset("Electronic",  gains: [ 6,  5,  3,  1, -1,  1,  0,  3,  4,  5]),
        preset("Acoustic",    gains: [ 3,  3,  2,  1,  2,  2,  3,  4,  3,  1]),
        preset("Loudness",    gains: [ 6,  5,  2,  0, -2, -2,  0,  2,  4,  6])
    ]

    private static func preset(_ name: String, gains: [Float]) -> EQConfig {
        EQConfig(name: name, mode: .graphic,
                 bands: zip(graphicFreqs10, gains).map { EQBand(frequency: $0.0, gain: $0.1) })
    }
}

// MARK: - AudioProcessor

/// Owns an `MTAudioProcessingTap` that:
/// 1. Applies an N-band peaking EQ to the audio in real time.
/// 2. Publishes RMS levels (per band, approximated) for the visualizer.
public final class AudioProcessor: ObservableObject {

    private let stateLock = NSLock()
    private var bands: [EQBand] = []
    private var enabled: Bool = false
    private var bypass: Bool = true

    @Published public private(set) var levels: [Float] = Array(repeating: 0, count: 8)

    /// Visualizer views call `startObservingLevels` on appear so the
    /// audio render thread only pushes level updates to the main runloop
    /// while someone is actually watching them. Otherwise the audio
    /// callback fires ~43×/sec, queueing main-thread blocks that
    /// compete with SwiftUI scroll handling and cause visible jitter.
    private var levelsObserverCount: Int = 0

    /// Throttle for level publishes — never push more than once every
    /// ~33ms (30fps). The audio callback fires per buffer (~43Hz at
    /// 1024-sample buffers @ 44.1kHz); without coalescing each tick
    /// posted a dispatch_async to main, flooding the runloop.
    private var lastLevelsPublishAt: CFTimeInterval = 0
    private static let minLevelsInterval: CFTimeInterval = 1.0 / 30.0

    public func startObservingLevels() {
        stateLock.lock()
        levelsObserverCount += 1
        stateLock.unlock()
    }

    public func stopObservingLevels() {
        stateLock.lock()
        levelsObserverCount = max(0, levelsObserverCount - 1)
        stateLock.unlock()
    }

    private var biquadL: [BiquadFilter] = []
    private var biquadR: [BiquadFilter] = []
    private var sampleRate: Double = 44100

    public init() {}

    /// Replace the active filter chain.
    public func setConfig(_ config: EQConfig) {
        stateLock.lock(); defer { stateLock.unlock() }
        bands = config.bands
        rebuildFilters()
        recomputeCoefficients()
    }

    public func setEnabled(_ on: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        enabled = on
        bypass = !on
    }

    public func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        let clientInfo = Unmanaged.passRetained(self).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: clientInfo,
            init: tapInitCallback,
            finalize: tapFinalizeCallback,
            prepare: tapPrepareCallback,
            unprepare: tapUnprepareCallback,
            process: tapProcessCallback
        )

        var createdTap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PreEffects,
            &createdTap
        )
        guard status == noErr, let tap = createdTap else {
            Unmanaged<AudioProcessor>.fromOpaque(clientInfo).release()
            return nil
        }

        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap

        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }

    // MARK: - Audio-thread entry points

    fileprivate func prepare(maxFrames: CMItemCount, format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        stateLock.lock()
        rebuildFilters()
        recomputeCoefficients()
        stateLock.unlock()
    }

    fileprivate func process(buffers: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount) {
        stateLock.lock()
        let isEnabled = enabled
        let isBypass = bypass
        stateLock.unlock()

        let bufList = UnsafeMutableAudioBufferListPointer(buffers)
        if !isBypass && isEnabled {
            if bufList.count >= 1, let ptr = bufList[0].mData?.assumingMemoryBound(to: Float.self) {
                applyChain(filters: &biquadL, samples: ptr, count: Int(frames))
            }
            if bufList.count >= 2, let ptr = bufList[1].mData?.assumingMemoryBound(to: Float.self) {
                applyChain(filters: &biquadR, samples: ptr, count: Int(frames))
            }
        }
        publishLevels(buffers: bufList, frames: Int(frames))
    }

    fileprivate func unprepare() {
        biquadL.removeAll()
        biquadR.removeAll()
    }

    // MARK: - DSP

    private func rebuildFilters() {
        biquadL = (0..<bands.count).map { _ in BiquadFilter() }
        biquadR = (0..<bands.count).map { _ in BiquadFilter() }
    }

    private func applyChain(filters: inout [BiquadFilter], samples: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<filters.count {
            filters[i].process(samples: samples, count: count)
        }
        // Pre-attenuate by the headroom we reserved for the biggest band
        // boost — keeps the chain from pushing peaks past 0 dBFS on
        // high-intensity content. Then a soft-knee limiter catches any
        // remaining transients before they clip the DAC.
        var gain = postGainFactor
        if gain != 1.0 {
            vDSP_vsmul(samples, 1, &gain, samples, 1, vDSP_Length(count))
        }
        softClip(samples: samples, count: count)
    }

    /// Single-band peak compensation: any positive band boost steals an
    /// equivalent (slightly attenuated) chunk of headroom from the
    /// post-chain output. Avoids the "bottoming out" / muddy clipping
    /// users hear at high intensity when bands are pushed hot.
    private var postGainFactor: Float = 1.0

    private func recomputeHeadroom() {
        // Sum a fraction of every positive band's gain so combined
        // boosts (e.g. Bass Boost or Loudness presets) get more
        // attenuation than a single +3 dB tweak. Cap so flat or
        // negative-gain configs incur zero attenuation.
        let positives = bands.map { max(0, $0.gain) }
        let weighted = positives.reduce(0) { $0 + $1 * 0.45 }
        let attenDb = -min(weighted, 14)
        postGainFactor = pow(10, attenDb / 20)
    }

    /// Soft-knee tanh limiter applied after the biquad chain. Anything
    /// above the threshold gets compressed toward ±1.0 along a smooth
    /// curve instead of hard clipping.
    private func softClip(samples: UnsafeMutablePointer<Float>, count: Int) {
        let threshold: Float = 0.92
        let limit: Float = 1.0 - threshold
        for i in 0..<count {
            let s = samples[i]
            let absS = s < 0 ? -s : s
            if absS > threshold {
                let over = absS - threshold
                let soft = threshold + limit * tanh(over / limit)
                samples[i] = s >= 0 ? soft : -soft
            }
        }
    }

    /// Peaking-EQ biquad coefficients per band. Called under stateLock.
    private func recomputeCoefficients() {
        recomputeHeadroom()
        guard !biquadL.isEmpty, biquadL.count == bands.count else { return }
        let Fs = Float(sampleRate)
        for (i, band) in bands.enumerated() {
            let g = band.gain
            let Q = max(0.1, band.q)
            let omega = 2 * .pi * band.frequency / Fs
            let A = pow(10, g / 40)
            let alpha = sin(omega) / (2 * Q)
            let cosw = cos(omega)
            let a0 = 1 + alpha / A
            let b0 = (1 + alpha * A) / a0
            let b1 = (-2 * cosw) / a0
            let b2 = (1 - alpha * A) / a0
            let a1 = (-2 * cosw) / a0
            let a2 = (1 - alpha / A) / a0
            biquadL[i].setCoefficients(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
            biquadR[i].setCoefficients(b0: b0, b1: b1, b2: b2, a1: a1, a2: a2)
        }
    }

    // MARK: - Levels (for visualizer)

    private var smoothed: [Float] = Array(repeating: 0, count: 8)
    /// Decaying peak of recent per-bin RMS. The visualizer normalizes
    /// each bin against this so loud tracks stop pinning the bars at
    /// the top (the user-visible "bottoming out") while quiet passages
    /// still drive bars to the ceiling. Fast attack, slow release.
    private var peakRef: Float = 0.10

    private func publishLevels(buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard frames > 0, let ptr = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let bins = 8
        let chunk = max(1, frames / bins)
        var bin: [Float] = Array(repeating: 0, count: bins)
        var framePeak: Float = 0
        for b in 0..<bins {
            let start = b * chunk
            let end = min(start + chunk, frames)
            var rms: Float = 0
            vDSP_rmsqv(ptr + start, 1, &rms, vDSP_Length(end - start))
            bin[b] = rms
            if rms > framePeak { framePeak = rms }
        }
        // Track rolling peak: jump up instantly when the track gets
        // louder, decay slowly so the bars settle back to fill the
        // dynamic range during quieter passages.
        if framePeak > peakRef {
            peakRef = framePeak
        } else {
            peakRef = peakRef * 0.992 + framePeak * 0.008
        }
        let denom = max(0.04, peakRef)
        for b in 0..<bins {
            // Normalize against the rolling peak with a small ceiling
            // buffer so the loudest bin tops out around 0.92 rather
            // than slamming the 1.0 cap.
            bin[b] = min(1, (bin[b] / denom) * 0.92)
        }
        for i in 0..<bins {
            smoothed[i] = smoothed[i] * 0.6 + bin[i] * 0.4
        }
        // Skip the main-thread hop entirely when no visualizer view is
        // currently subscribed AND throttle to 30fps when one is. Either
        // gate alone would help; both together keep the audio callback
        // from dispatching to main when it would be wasted work or
        // out-pace the screen.
        stateLock.lock()
        let observed = levelsObserverCount > 0
        stateLock.unlock()
        guard observed else { return }

        let now = CACurrentMediaTime()
        guard now - lastLevelsPublishAt >= Self.minLevelsInterval else { return }
        lastLevelsPublishAt = now

        let toPublish = smoothed
        DispatchQueue.main.async { [weak self] in
            self?.levels = toPublish
        }
    }
}

// MARK: - Biquad

private struct BiquadFilter {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

    mutating func setCoefficients(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    mutating func process(samples: UnsafeMutablePointer<Float>, count: Int) {
        var X1 = x1, X2 = x2, Y1 = y1, Y2 = y2
        for i in 0..<count {
            let x = samples[i]
            let y = b0 * x + b1 * X1 + b2 * X2 - a1 * Y1 - a2 * Y2
            X2 = X1; X1 = x
            Y2 = Y1; Y1 = y
            samples[i] = y
        }
        x1 = X1; x2 = X2; y1 = Y1; y2 = Y2
    }
}

// MARK: - MTAudioProcessingTap C callbacks

private let tapInitCallback: MTAudioProcessingTapInitCallback = { tap, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo
}

private let tapFinalizeCallback: MTAudioProcessingTapFinalizeCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    Unmanaged<AudioProcessor>.fromOpaque(storage).release()
}

private let tapPrepareCallback: MTAudioProcessingTapPrepareCallback = { tap, maxFrames, format in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<AudioProcessor>.fromOpaque(storage).takeUnretainedValue()
    processor.prepare(maxFrames: maxFrames, format: format.pointee)
}

private let tapUnprepareCallback: MTAudioProcessingTapUnprepareCallback = { tap in
    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<AudioProcessor>.fromOpaque(storage).takeUnretainedValue()
    processor.unprepare()
}

private let tapProcessCallback: MTAudioProcessingTapProcessCallback = { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    let storage = MTAudioProcessingTapGetStorage(tap)
    let processor = Unmanaged<AudioProcessor>.fromOpaque(storage).takeUnretainedValue()
    processor.process(buffers: bufferListInOut, frames: numberFramesOut.pointee)
}

// MARK: - EQManager

/// User-facing EQ controller. Singleton; mirrors its state into all
/// `AudioProcessor` instances that AudioPlayer creates.
///
/// State is split into two configs:
/// - `freeConfig`: 5-band graphic, always editable. Matches v1 behavior.
/// - `proConfig`: 10-band graphic OR parametric. Editable when Pro is unlocked.
///
/// `activeConfig` returns proConfig if `useProConfig == true`, else freeConfig.
@MainActor
public final class EQManager: ObservableObject {
    public static let shared = EQManager()

    private static let enabledKey = "bolera.eq.enabled"
    private static let freeKey = "bolera.eq.freeConfig"
    private static let proKey = "bolera.eq.proConfig"
    private static let usingProKey = "bolera.eq.usingPro"
    private static let customPresetsKey = "bolera.eq.customPresets"
    private static let legacyGainsKey = "eq.gains"
    private static let legacyEnabledKey = "eq.enabled"

    @Published public var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
            broadcast()
        }
    }

    @Published public var freeConfig: EQConfig {
        didSet { persist(); broadcast() }
    }

    @Published public var proConfig: EQConfig {
        didSet { persist(); broadcast() }
    }

    /// If true, use proConfig in the audio chain. The UI toggles this when
    /// the user is unlocked and has picked a 10-band/parametric setup.
    @Published public var useProConfig: Bool {
        didSet {
            UserDefaults.standard.set(useProConfig, forKey: Self.usingProKey)
            broadcast()
        }
    }

    /// User-saved presets (any mode). Persisted to UserDefaults.
    @Published public var customPresets: [EQConfig] {
        didSet { persistCustomPresets() }
    }

    public var activeConfig: EQConfig { useProConfig ? proConfig : freeConfig }

    /// All built-in presets in the order they should appear in the picker.
    public var builtInPresets: [EQConfig] { EQConfig.builtInPresets }

    private var processors: [AudioProcessor] = []

    private init() {
        let defaults = UserDefaults.standard

        // Legacy → new migration: lift old 5-band gains into freeConfig.
        var initialFreeConfig: EQConfig
        if let data = defaults.data(forKey: Self.freeKey),
           let saved = try? JSONDecoder().decode(EQConfig.self, from: data) {
            initialFreeConfig = saved
        } else if let arr = defaults.array(forKey: Self.legacyGainsKey) as? [Double],
                  arr.count == EQConfig.graphicFreqs5.count {
            let gains = arr.map { Float($0) }
            initialFreeConfig = EQConfig(
                name: "Custom",
                mode: .graphic,
                bands: zip(EQConfig.graphicFreqs5, gains).map { EQBand(frequency: $0.0, gain: $0.1) }
            )
        } else {
            initialFreeConfig = .graphicFlat(bandCount: 5)
        }
        // Defensive: free config must always be 5-band graphic. Snap any
        // stale state (from earlier dev builds) back to the 5-band layout.
        if initialFreeConfig.bands.count != EQConfig.graphicFreqs5.count ||
           initialFreeConfig.mode != .graphic {
            initialFreeConfig = Self.downsampleTo5Band(initialFreeConfig)
        }
        self.freeConfig = initialFreeConfig

        if let data = defaults.data(forKey: Self.proKey),
           let saved = try? JSONDecoder().decode(EQConfig.self, from: data) {
            self.proConfig = saved
        } else {
            self.proConfig = .graphicFlat(bandCount: 10)
        }

        if let data = defaults.data(forKey: Self.customPresetsKey),
           let saved = try? JSONDecoder().decode([EQConfig].self, from: data) {
            self.customPresets = saved
        } else {
            self.customPresets = []
        }

        // Enabled state: prefer new key, fall back to legacy.
        if defaults.object(forKey: Self.enabledKey) != nil {
            self.enabled = defaults.bool(forKey: Self.enabledKey)
        } else {
            self.enabled = defaults.bool(forKey: Self.legacyEnabledKey)
        }

        self.useProConfig = defaults.bool(forKey: Self.usingProKey)
    }

    // MARK: - Processor wiring

    public func register(_ processor: AudioProcessor) {
        processors.append(processor)
        processor.setEnabled(enabled)
        processor.setConfig(activeConfig)
    }

    public func unregister(_ processor: AudioProcessor) {
        processors.removeAll { $0 === processor }
    }

    private func broadcast() {
        for p in processors {
            p.setEnabled(enabled)
            p.setConfig(activeConfig)
        }
    }

    // MARK: - User actions

    /// Set the gain of a single band in the active config.
    public func setGain(_ gain: Float, atBand idx: Int) {
        var cfg = activeConfig
        guard cfg.bands.indices.contains(idx) else { return }
        cfg.bands[idx].gain = gain
        cfg.name = "Custom"
        writeActive(cfg)
    }

    public func setFrequency(_ freq: Float, atBand idx: Int) {
        var cfg = activeConfig
        guard cfg.bands.indices.contains(idx), cfg.mode == .parametric else { return }
        cfg.bands[idx].frequency = freq
        cfg.name = "Custom"
        writeActive(cfg)
    }

    public func setQ(_ q: Float, atBand idx: Int) {
        var cfg = activeConfig
        guard cfg.bands.indices.contains(idx), cfg.mode == .parametric else { return }
        cfg.bands[idx].q = q
        cfg.name = "Custom"
        writeActive(cfg)
    }

    public func setMode(_ mode: EQMode) {
        var cfg = activeConfig
        guard cfg.mode != mode else { return }
        cfg.mode = mode
        if mode == .parametric, cfg.bands.count < 10 {
            cfg.bands = EQConfig.parametricFlat().bands
        }
        cfg.name = "Custom"
        writeActive(cfg)
    }

    public func resetActive() {
        if useProConfig {
            writeActive(.graphicFlat(bandCount: 10))
        } else {
            writeActive(.graphicFlat(bandCount: 5))
        }
    }

    public func apply(preset: EQConfig) {
        var copy = preset
        copy.id = UUID() // local copy
        writeActive(copy)
    }

    public func savePreset(named name: String) {
        var snapshot = activeConfig
        snapshot.id = UUID()
        snapshot.name = name
        customPresets.append(snapshot)
    }

    public func deletePreset(_ preset: EQConfig) {
        customPresets.removeAll { $0.id == preset.id }
    }

    // MARK: - Persistence

    private func writeActive(_ cfg: EQConfig) {
        if useProConfig {
            proConfig = cfg
        } else {
            // Free mode is locked to 5-band graphic. Snap any incoming
            // config (e.g. a 10-band preset) down to the legacy 5 bands.
            freeConfig = Self.downsampleTo5Band(cfg)
        }
    }

    /// Project an N-band config onto the free-tier 5-band layout.
    /// For each free freq, take the gain from the closest band in the source.
    static func downsampleTo5Band(_ cfg: EQConfig) -> EQConfig {
        var bands: [EQBand] = []
        for f in EQConfig.graphicFreqs5 {
            if let nearest = cfg.bands.min(by: { abs($0.frequency - f) < abs($1.frequency - f) }) {
                bands.append(EQBand(frequency: f, gain: nearest.gain))
            } else {
                bands.append(EQBand(frequency: f))
            }
        }
        return EQConfig(id: cfg.id, name: cfg.name, mode: .graphic, bands: bands)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(freeConfig) {
            UserDefaults.standard.set(data, forKey: Self.freeKey)
        }
        if let data = try? JSONEncoder().encode(proConfig) {
            UserDefaults.standard.set(data, forKey: Self.proKey)
        }
    }

    private func persistCustomPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: Self.customPresetsKey)
        }
    }
}
