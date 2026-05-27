import SwiftUI
import BoleraCore

struct MainTabView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var player: AudioPlayer
    @State private var showNowPlaying = false

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                Tab("Home", systemImage: "house.fill") {
                    NavigationStack { HomeView() }
                        .modifier(MiniPlayerScrollInset(active: player.current != nil))
                }
                Tab("Library", systemImage: "music.note.list") {
                    NavigationStack { LibraryView() }
                        .modifier(MiniPlayerScrollInset(active: player.current != nil))
                }
                Tab("Settings", systemImage: "gear") {
                    NavigationStack { SettingsView() }
                        .modifier(MiniPlayerScrollInset(active: player.current != nil))
                }
                Tab("Search", systemImage: "magnifyingglass", role: .search) {
                    NavigationStack { SearchView() }
                        .modifier(MiniPlayerScrollInset(active: player.current != nil))
                }
            }

            if player.current != nil {
                MiniPlayerView()
                    .contentShape(Rectangle())
                    .onTapGesture { showNowPlaying = true }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            AudioPlayer.shared.authManager = auth
        }
        .fullScreenCover(isPresented: $showNowPlaying) {
            NowPlayingContent(collapse: { showNowPlaying = false })
        }
    }
}

/// Adds a bottom content margin to each tab's scrollable surface roughly
/// matching the mini player's height so last items scroll up clear of the
/// floating player. contentMargins reaches into the nearest ScrollView /
/// List, including plain-styled Lists that ignore safeAreaInset.
private struct MiniPlayerScrollInset: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content
                .contentMargins(.bottom, 80, for: .scrollContent)
                .contentMargins(.bottom, 80, for: .scrollIndicators)
        } else {
            content
        }
    }
}
