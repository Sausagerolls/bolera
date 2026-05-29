import SwiftUI
import BoleraCore

struct MainTabView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var showNowPlaying = false
    @ObservedObject private var connectivity = ConnectivityStore.shared

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                Tab("Home", systemImage: "house.fill") {
                    NavigationStack {
                        HomeView()
                            .background(BoleraBackground())
                    }
                    .modifier(MiniPlayerScrollInset())
                }
                Tab("Library", systemImage: "music.note.list") {
                    NavigationStack {
                        LibraryView()
                            .background(BoleraBackground())
                    }
                    .modifier(MiniPlayerScrollInset())
                }
                Tab("Settings", systemImage: "gear") {
                    NavigationStack {
                        SettingsView()
                            .background(BoleraBackground())
                    }
                    .modifier(MiniPlayerScrollInset())
                }
                Tab("Search", systemImage: "magnifyingglass", role: .search) {
                    NavigationStack {
                        SearchView()
                            .background(BoleraBackground())
                    }
                    .modifier(MiniPlayerScrollInset())
                }
            }

            // Mini-player overlay isolated into its own view so the
            // AudioPlayer's 10×/sec time updates don't re-evaluate the
            // entire TabView body on every tick (caused scroll jitter).
            MiniPlayerOverlay(showNowPlaying: $showNowPlaying)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !connectivity.isOnline {
                OfflineBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: connectivity.isOnline)
        .onAppear {
            AudioPlayer.shared.authManager = auth
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingContent(collapse: { showNowPlaying = false })
        }
    }
}

/// Hosts the mini player conditional. Observes the narrow visibility
/// flag rather than the full `AudioPlayer`, so the body only re-runs
/// when playback starts or stops — not on every 0.1s tick. (When the
/// outer wrapper re-ran 10×/sec the SwiftUI diffing + ultraThinMaterial
/// recomposition stole main-thread time from the scroll handler in the
/// visible tab, producing jitter.)
private struct MiniPlayerOverlay: View {
    @EnvironmentObject var visibility: PlayerVisibilityState
    @Binding var showNowPlaying: Bool

    var body: some View {
        if visibility.isVisible {
            MiniPlayerView()
                .contentShape(Rectangle())
                .onTapGesture { showNowPlaying = true }
                .padding(.horizontal, 8)
                .padding(.bottom, 60)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Reserves bottom content margin equal to the mini player's height so
/// list/scroll content scrolls clear of it. Observes a narrow visibility
/// flag rather than the full `AudioPlayer` — without this distinction
/// the inset modifier re-evaluated every 0.1s on `currentTime` ticks,
/// causing list scrolling to stutter while music played.
private struct MiniPlayerScrollInset: ViewModifier {
    @EnvironmentObject var visibility: PlayerVisibilityState

    func body(content: Content) -> some View {
        // Apply the inset unconditionally and vary only the VALUE. An
        // `if/else` here produces two structurally distinct view trees, so
        // when `isVisible` flips (first track starts) SwiftUI rebuilds the
        // wrapped NavigationStack from scratch and the nav path pops to root
        // — kicking the user out of any pushed detail view. A branchless
        // modifier keeps the stack's identity stable.
        let inset: CGFloat = visibility.isVisible ? 80 : 0
        content
            .contentMargins(.bottom, inset, for: .scrollContent)
            .contentMargins(.bottom, inset, for: .scrollIndicators)
    }
}

/// App-wide offline notice, hosted as a top safe-area inset in MainTabView.
private struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
            Text("Offline — reconnect to your server")
                .lineLimit(1)
            Spacer()
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.85))
    }
}
