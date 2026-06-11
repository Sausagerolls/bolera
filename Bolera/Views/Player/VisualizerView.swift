import SwiftUI
import BoleraCore

struct VisualizerView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var player: AudioPlayer

    private final class State {
        var smoothed: [Float] = Array(repeating: 0, count: 8)
        var lastT: TimeInterval = 0
    }
    private let state = State()

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header
                Spacer()
                TimelineView(.animation) { ctx in
                    Canvas { gfx, size in
                        let now = ctx.date.timeIntervalSinceReferenceDate
                        let dt = max(0.001, min(0.1, now - state.lastT))
                        state.lastT = now

                        // React to REAL audio levels only — no synthetic motion.
                        // If the tap isn't delivering levels, settle to still.
                        let target: [Float] = {
                            if let real = player.activeAudioProcessor?.levels,
                               real.contains(where: { $0 > 0.01 }) {
                                return real
                            }
                            return Array(repeating: 0, count: 8)
                        }()

                        let n = min(state.smoothed.count, target.count)
                        for i in 0..<n {
                            let s = state.smoothed[i]
                            let t = target[i]
                            let alpha: Float = (t > s) ? Float(min(1.0, dt * 18.0))
                                                        : Float(min(1.0, dt * 6.0))
                            state.smoothed[i] = s + (t - s) * alpha
                        }

                        drawBars(gfx: gfx, size: size, levels: state.smoothed)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 80)
                trackInfo
                Spacer().frame(height: 40)
            }
        }
        .onAppear {
            // Gate the audio render thread's per-buffer publish on having
            // an actual subscriber; this view is the only consumer of
            // `processor.levels`.
            player.activeAudioProcessor?.startObservingLevels()
        }
        .onDisappear {
            player.activeAudioProcessor?.stopObservingLevels()
        }
    }

    private var backdrop: some View {
        ZStack {
            if let art = player.artwork {
                Image(uiImage: art).resizable().scaledToFill().blur(radius: 90).opacity(0.6).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            Color.black.opacity(0.55).ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack {
            Button { isPresented = false } label: {
                Image(systemName: "chevron.down").font(.title3).padding(10).background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            Text("Visualizer").font(.subheadline.weight(.semibold))
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding()
    }

    private var trackInfo: some View {
        VStack(spacing: 4) {
            Text(player.current?.Name ?? "").font(.headline).lineLimit(1)
            Text(player.current?.primaryArtistName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal)
    }

    private func drawBars(gfx: GraphicsContext, size: CGSize, levels: [Float]) {
        let count = levels.count
        let gap: CGFloat = 8
        let totalGap = gap * CGFloat(count - 1)
        let barWidth = (size.width * 0.85 - totalGap) / CGFloat(count)
        let originX = (size.width - (barWidth * CGFloat(count) + totalGap)) / 2
        let maxHeight = size.height * 0.55
        let centerY = size.height / 2

        for i in 0..<count {
            let h = max(8, maxHeight * CGFloat(levels[i]))
            let x = originX + CGFloat(i) * (barWidth + gap)
            let rect = CGRect(x: x, y: centerY - h / 2, width: barWidth, height: h)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            let g = Gradient(colors: [Color.accentColor, Color.accentColor.opacity(0.5)])
            gfx.fill(path, with: .linearGradient(g,
                                                 startPoint: CGPoint(x: rect.midX, y: rect.minY),
                                                 endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        }
    }

}
