import SwiftUI
import BoleraCore

@main
struct BoleraApp: App {
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

    init() {
        LegacyMigration.runIfNeeded()
        // Wire the audio player to the auth singleton up front so CarPlay can
        // start playback before the SwiftUI scene has appeared.
        AudioPlayer.shared.authManager = AuthManager.shared
        AudioPlayer.shared.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
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
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lastFm: LastFmService
    @AppStorage("bolera.onboarding.lastfmSeen") private var lastFmOnboardingSeen = false

    var body: some View {
        Group {
            if !auth.isAuthenticated {
                ServerConnectionView()
            } else if !lastFmOnboardingSeen && !lastFm.isAuthenticated {
                LastFmOnboardingView { lastFmOnboardingSeen = true }
            } else {
                MainTabView()
            }
        }
        .animation(.easeInOut, value: auth.isAuthenticated)
        .animation(.easeInOut, value: lastFmOnboardingSeen)
    }
}
