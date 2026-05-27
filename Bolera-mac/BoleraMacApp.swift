import SwiftUI
import BoleraCore

@main
struct BoleraMacApp: App {
    @StateObject private var auth = AuthManager.shared
    @StateObject private var player = AudioPlayer.shared
    @StateObject private var library = LibraryStore()
    @StateObject private var sleepTimer = SleepTimer.shared
    @StateObject private var downloads = DownloadManager.shared
    @StateObject private var lastFm = LastFmService.shared
    @StateObject private var pro = ProEntitlementStore.shared
    @StateObject private var libVisibility = LibraryVisibilityStore.shared
    @StateObject private var ignoredTracks = IgnoredTracksStore.shared
    @StateObject private var daily = DailyPlaylistStore.shared
    @StateObject private var pinned = PinnedItemsStore.shared
    @StateObject private var nav = MacNavCoordinator()

    @State private var showPaywall = false
    @Environment(\.openWindow) private var openWindow

    init() {
        LegacyMigration.runIfNeeded()
        AudioPlayer.shared.authManager = AuthManager.shared
        AudioPlayer.shared.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup("Bolera", id: "main") {
            RootView_Mac()
                .frame(minWidth: 960, minHeight: 600)
                .environmentObject(auth)
                .environmentObject(player)
                .environmentObject(library)
                .environmentObject(sleepTimer)
                .environmentObject(downloads)
                .environmentObject(lastFm)
                .environmentObject(pro)
                .environmentObject(libVisibility)
                .environmentObject(ignoredTracks)
                .environmentObject(daily)
                .environmentObject(pinned)
                .environmentObject(nav)
                .preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Bolera") { showPaywall = false /* placeholder */ }
            }
            CommandMenu("Playback") {
                Button("Play / Pause") { player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Next") { player.next() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Previous") { player.previous() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Divider()
                Button("Shuffle") { player.toggleShuffle() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Cycle Repeat") { player.cycleRepeatMode() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Open Now Playing") {
                    openWindow(id: "now-playing")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Open Equalizer") {
                    openWindow(id: "eq")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsWindow_Mac()
                .environmentObject(auth)
                .environmentObject(player)
                .environmentObject(pro)
                .environmentObject(libVisibility)
                .environmentObject(ignoredTracks)
                .environmentObject(lastFm)
        }

        WindowGroup("Equalizer", id: "eq") {
            EQWindow_Mac()
                .environmentObject(pro)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 720, height: 480)
        .windowResizability(.contentMinSize)

        WindowGroup("Now Playing", id: "now-playing") {
            NowPlayingPane_Mac()
                .frame(minWidth: 420, minHeight: 600)
                .environmentObject(auth)
                .environmentObject(player)
                .environmentObject(pro)
                .environmentObject(ignoredTracks)
                .environmentObject(daily)
                .environmentObject(pinned)
                .environmentObject(nav)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 540, height: 760)
        .windowResizability(.contentMinSize)

        MenuBarExtra("Bolera", systemImage: menuBarIcon) {
            MenuBarPlayer_Mac()
                .environmentObject(player)
                .environmentObject(auth)
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        player.isPlaying ? "speaker.wave.2.fill" : "music.note"
    }
}

struct RootView_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lastFm: LastFmService
    @AppStorage("bolera.onboarding.lastfmSeen") private var lastFmOnboardingSeen = false

    var body: some View {
        Group {
            if !auth.isAuthenticated {
                ServerConnectionView_Mac()
            } else if !lastFmOnboardingSeen && !lastFm.isAuthenticated {
                LastFmOnboardingView_Mac { lastFmOnboardingSeen = true }
            } else {
                MainWindow_Mac()
            }
        }
        .animation(.easeInOut, value: auth.isAuthenticated)
        .animation(.easeInOut, value: lastFmOnboardingSeen)
    }
}
