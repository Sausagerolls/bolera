import SwiftUI
import BoleraCore

struct LyricsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @State private var lyrics: Lyrics = .empty
    @State private var loading = false
    @State private var lastItemId: String?

    var body: some View {
        ZStack {
            backdrop
            VStack(spacing: 0) {
                header
                if loading && lyrics.isEmpty {
                    Spacer(); ProgressView(); Spacer()
                } else if lyrics.isEmpty {
                    Spacer()
                    Text("No lyrics available for this track.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    lyricsScroller
                }
            }
        }
        .task(id: player.current?.Id) { await loadIfNeeded() }
        .onChange(of: player.current?.Id) { _, _ in
            lyrics = .empty
            Task { await loadIfNeeded() }
        }
        // Swipe-down anywhere on the screen also dismisses.
        .gesture(
            DragGesture(minimumDistance: 30, coordinateSpace: .global)
                .onEnded { value in
                    if value.translation.height > 80 {
                        isPresented = false
                    }
                }
        )
    }

    private var backdrop: some View {
        ZStack {
            if let art = player.artwork {
                Image(uiImage: art).resizable().scaledToFill().blur(radius: 80).opacity(0.7).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            Color.black.opacity(0.55).ignoresSafeArea()
        }
    }

    private var header: some View {
        HStack {
            Button { isPresented = false } label: {
                Image(systemName: "chevron.down")
                    .font(.title2.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            VStack(spacing: 2) {
                Text("Lyrics").font(.subheadline.weight(.semibold))
                if let t = player.current?.Name {
                    Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { isPresented = false } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    private var lyricsScroller: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Color.clear.frame(height: 40).id("top")
                    ForEach(lyrics.lines) { line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(isCurrent(line) ? Color.white : Color.white.opacity(0.45))
                            .scaleEffect(isCurrent(line) ? 1.05 : 1.0, anchor: .leading)
                            .animation(.easeInOut(duration: 0.25), value: isCurrent(line))
                            .padding(.horizontal, 24)
                            .id(line.id)
                            .onTapGesture {
                                if let ts = line.timestamp { player.seek(to: ts) }
                            }
                    }
                    Color.clear.frame(height: 200)
                }
            }
            .onChange(of: currentLineId) { _, new in
                guard lyrics.isSynced, let id = new else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var currentLineId: UUID? {
        guard lyrics.isSynced else { return nil }
        let t = player.currentTime
        var best: LyricsLine?
        for line in lyrics.lines where (line.timestamp ?? -1) <= t {
            best = line
        }
        return best?.id
    }

    private func isCurrent(_ line: LyricsLine) -> Bool {
        line.id == currentLineId
    }

    private func loadIfNeeded() async {
        guard let item = player.current, let url = auth.serverURL else { return }
        guard item.Id != lastItemId else { return }
        lastItemId = item.Id
        loading = true
        let client = JellyfinClient(baseURL: url, auth: auth)
        let result = (try? await client.lyrics(for: item)) ?? .empty
        await MainActor.run {
            self.lyrics = result
            self.loading = false
        }
    }
}
