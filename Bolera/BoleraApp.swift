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
    @StateObject private var playerVisibility = PlayerVisibilityState()
    @StateObject private var nowPlaying = PlayerNowPlayingState()
    @StateObject private var connectivity = ConnectivityStore.shared
    @StateObject private var prefetcher = LibraryPrefetcher.shared

    init() {
        LegacyMigration.runIfNeeded()
        // Wire the audio player to the auth singleton up front so CarPlay can
        // start playback before the SwiftUI scene has appeared.
        AudioPlayer.shared.authManager = AuthManager.shared
        AudioPlayer.shared.configureAudioSession()
        // Resume the last session's queue, PAUSED — mini player shows where you
        // left off; nothing streams until you press play.
        AudioPlayer.shared.restorePlaybackState()
        // Replay any favourites queued while offline (also retries on reconnect).
        FavoritesSync.shared.flushNow()
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
                .environmentObject(playerVisibility)
                .environmentObject(nowPlaying)
                .environmentObject(connectivity)
                .environmentObject(prefetcher)
                .preferredColorScheme(.dark)
                .tint(Color("AccentColor"))
        }
    }
}

struct RootView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var lastFm: LastFmService
    @AppStorage("bolera.onboarding.lastfmSeen") private var lastFmOnboardingSeen = false
    @AppStorage("bolera.onboarding.prefetchDone") private var prefetchDone = false

    var body: some View {
        ZStack {
            // Global Bolera-purple gradient backdrop. Matches the app icon
            // and softens the previously stark pure-black background.
            BoleraBackground()
            Group {
                if !auth.isAuthenticated {
                    ServerConnectionView()
                } else if !lastFmOnboardingSeen && !lastFm.isAuthenticated {
                    LastFmOnboardingView { lastFmOnboardingSeen = true }
                } else if !prefetchDone {
                    LibraryPrefetchView { prefetchDone = true }
                } else {
                    MainTabView()
                }
            }
        }
        .animation(.easeInOut, value: auth.isAuthenticated)
        .animation(.easeInOut, value: lastFmOnboardingSeen)
        .animation(.easeInOut, value: prefetchDone)
    }
}

/// Onboarding step: caches the whole library + artwork with a progress bar so
/// later browsing is instant. Skippable; runs once (gated by an AppStorage flag).
struct LibraryPrefetchView: View {
    @EnvironmentObject var auth: AuthManager
    @ObservedObject private var prefetcher = LibraryPrefetcher.shared
    let onFinish: () -> Void
    @State private var started = false

    var body: some View {
        ZStack {
            BoleraBackground()
            VStack(spacing: 22) {
                Spacer()
                Image("BoleraGlyph")
                    .resizable().aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                Text("Preparing your library")
                    .font(.title2.bold())
                Text(prefetcher.phase.isEmpty
                     ? "Caching artists, albums and artwork so browsing is instant — even offline."
                     : prefetcher.phase)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
                ProgressView(value: prefetcher.progress)
                    .tint(.accentColor)
                    .padding(.horizontal, 40)
                Text("\(Int(prefetcher.progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(prefetcher.progress >= 1 ? "Continue" : "Skip for now") { onFinish() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.bottom, 40)
            }
        }
        .task {
            guard !started else { return }
            started = true
            guard let url = auth.serverURL else { onFinish(); return }
            await prefetcher.run(client: JellyfinClient(baseURL: url, auth: auth), auth: auth)
            onFinish()
        }
    }
}

/// App-wide background. Tuned to match the Mac app's neutral dark
/// blue-grey chrome — softer than pure black, no overt purple tint, so
/// album art carries the colour and the UI reads as one piece across
/// iOS + macOS.
struct BoleraBackground: View {
    var body: some View {
        Color(red: 0.09, green: 0.09, blue: 0.13)
            .ignoresSafeArea()
    }
}
