import SwiftUI
import BoleraCore

struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var pro: ProEntitlementStore
    @ObservedObject private var prefetcher = LibraryPrefetcher.shared
    @ObservedObject private var live = LiveFilterStore.shared
    @AppStorage("bolera.maxBitrate") private var maxBitrate: Int = 320
    @State private var cacheSizeText: String = "—"
    @State private var clearingCache = false
    @State private var showPaywall = false

    var body: some View {
        List {
            Section("Account") {
                if let user = auth.userName {
                    LabeledContent("Signed in as", value: user)
                }
                if let url = auth.serverURL {
                    LabeledContent("Server", value: url.host ?? url.absoluteString)
                }
                Button("Sign Out", role: .destructive) { auth.logout() }
            }

            Section("Services") {
                NavigationLink {
                    LastFmSettingsView()
                } label: {
                    Label("Last.fm", systemImage: "waveform")
                }
            }

            Section("Playback") {
                Picker("Max Streaming Bitrate", selection: $maxBitrate) {
                    Text("96 kbps").tag(96)
                    Text("128 kbps").tag(128)
                    Text("192 kbps").tag(192)
                    Text("256 kbps").tag(256)
                    Text("320 kbps").tag(320)
                    Text("Lossless").tag(1411)
                }
                CrossfadeRow()
                NavigationLink {
                    EQView()
                } label: {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                }
            }

            Section("Library") {
                NavigationLink {
                    DownloadsView()
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
                if prefetcher.isRunning {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(prefetcher.phase.isEmpty ? "Updating…" : prefetcher.phase,
                              systemImage: "arrow.triangle.2.circlepath")
                        ProgressView(value: prefetcher.progress).tint(.accentColor)
                    }
                } else {
                    Button {
                        guard let url = auth.serverURL else { return }
                        Task { await prefetcher.run(client: JellyfinClient(baseURL: url, auth: auth), auth: auth) }
                    } label: {
                        Label("Update Offline Cache", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(auth.serverURL == nil)
                }
                LabeledContent("Cache Size", value: cacheSizeText)
                Button(role: .destructive) {
                    clearCache()
                } label: {
                    HStack {
                        Label("Clear Cache", systemImage: "trash")
                        Spacer()
                        if clearingCache { ProgressView() }
                    }
                }
                .disabled(clearingCache)
            }

            Section {
                Toggle("Enable AI Mood Mixes",
                       isOn: Binding(
                        get: { UserDefaults.standard.object(forKey: "bolera.ai.moodMixEnabled") as? Bool ?? true },
                        set: { UserDefaults.standard.set($0, forKey: "bolera.ai.moodMixEnabled") }))
            } header: {
                Text("AI Features")
            } footer: {
                Text("Make-a-Mix uses Apple Intelligence to turn a mood phrase into a playlist. Last.fm sign-in dramatically improves results.")
                    .font(.caption)
            }

            Section {
                Toggle("Exclude Live Recordings", isOn: $live.enabled)
                    .onChange(of: live.enabled) { _, _ in refreshLiveAlbums() }
                if live.enabled {
                    HStack {
                        Text("Live Tag")
                        Spacer()
                        TextField("Live", text: $live.tag)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .frame(maxWidth: 160)
                            .onSubmit { refreshLiveAlbums() }
                    }
                }
            } header: {
                Text("Mixes & Radio")
            } footer: {
                Text("Keeps live recordings out of daily mixes, Make-a-Mix, and radio. Detected by name (e.g. \"(Live)\", \"Unplugged\") and by the tag or genre above — set it to whatever you tag your live albums with on the server. Doesn't affect browsing or playing an album directly.")
                    .font(.caption)
            }

            Section("Bolera Pro") {
                if pro.isPro {
                    HStack {
                        Label("Unlocked", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.tint)
                        Spacer()
                        Text("Thank you").foregroundStyle(.secondary).font(.caption)
                    }
                    NavigationLink {
                        LibraryTogglesView()
                    } label: {
                        Label("Libraries", systemImage: "rectangle.stack")
                    }
                    NavigationLink {
                        IgnoredTracksView()
                    } label: {
                        Label("Ignored Items", systemImage: "hand.raised.slash")
                    }
                } else {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Label("Unlock Bolera Pro", systemImage: "lock.fill")
                            Spacer()
                            ProBadge()
                        }
                    }
                    Button {
                        Task { await pro.restore() }
                    } label: {
                        Label("Restore Purchases", systemImage: "arrow.clockwise")
                    }
                }
            }

            Section("Support") {
                Link(destination: contactURL()) {
                    Label("Contact Developer", systemImage: "envelope.fill")
                }
                Link("Visit giantmushroom.studio",
                     destination: URL(string: "https://giantmushroom.studio/bolera")!)
            }

            Section("Legal") {
                Link(destination: URL(string: "https://giantmushroom.studio/bolera/privacy.html")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                Link(destination: URL(string: "https://giantmushroom.studio/bolera/terms.html")!) {
                    Label("Terms of Use", systemImage: "doc.text")
                }
            }

            Section("About") {
                LabeledContent("Version", value: AuthManager.clientVersion)
                LabeledContent("Device ID", value: String(AuthManager.deviceId.prefix(8)))
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        .task { refreshCacheSize() }
        .sheet(isPresented: $showPaywall) {
            NavigationStack { PaywallView() }
                .environmentObject(pro)
        }
    }

    /// Re-fetch the set of live-tagged albums after the toggle/tag changes so
    /// the exclusion reflects the new setting immediately.
    private func refreshLiveAlbums() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        Task {
            await LiveFilterStore.shared.refresh(client: client)
            // Rebuild today's daily mixes so the change applies now (Make-a-Mix
            // and radio already filter on their next run).
            await DailyPlaylistStore.shared.regenerate(client: client, auth: auth, lastFm: LastFmService.shared)
        }
    }

    private func refreshCacheSize() {
        Task.detached(priority: .utility) {
            let bytes = await cacheDirsTotalBytes()
            let fmt = ByteCountFormatter()
            fmt.allowedUnits = [.useMB, .useKB]
            fmt.countStyle = .file
            let txt = fmt.string(fromByteCount: Int64(bytes))
            await MainActor.run { cacheSizeText = txt }
        }
    }

    /// Builds a mailto URL pre-filled with subject + diagnostic body so any
    /// support email arrives with version/device context already attached.
    private func contactURL() -> URL {
        let subject = "Bolera support"
        let body = """
        \n\n---\nApp: Bolera \(AuthManager.clientVersion)\nDevice: iOS\nDevice ID: \(String(AuthManager.deviceId.prefix(8)))
        """
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = "contact@giantmushroom.studio"
        comps.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return comps.url ?? URL(string: "mailto:contact@giantmushroom.studio")!
    }

    private func clearCache() {
        clearingCache = true
        Task.detached(priority: .utility) {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            for sub in ["ImageCache", "LibraryCache"] {
                try? FileManager.default.removeItem(at: caches.appendingPathComponent(sub))
            }
            await MainActor.run {
                clearingCache = false
                refreshCacheSize()
            }
        }
    }

    private func cacheDirsTotalBytes() async -> UInt64 {
        return await Self._cacheDirsTotalBytes()
    }

    private static func _cacheDirsTotalBytes() async -> UInt64 {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        var total: UInt64 = 0
        for sub in ["ImageCache", "LibraryCache"] {
            let url = caches.appendingPathComponent(sub)
            if let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let u as URL in en {
                    if let s = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                        total += UInt64(s)
                    }
                }
            }
        }
        return total
    }
}

/// Isolated subview that owns the AudioPlayer dependency so the whole
/// SettingsView body doesn't rebuild every time `currentTime` ticks.
private struct CrossfadeRow: View {
    @EnvironmentObject var player: AudioPlayer
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Crossfade")
                Spacer()
                Text(player.crossfadeDuration > 0
                     ? String(format: "%.0f sec", player.crossfadeDuration)
                     : "Off")
                    .foregroundStyle(.secondary).font(.caption)
            }
            Slider(value: $player.crossfadeDuration, in: 0...12, step: 1)
        }
        .padding(.vertical, 4)
    }
}
