import SwiftUI
import BoleraCore

/// Top-level Settings: a short menu that pushes one focused sub-screen per area
/// of the app. Each area lives in its own small view below (kept in this file —
/// the flat pbxproj sometimes drops freshly-added files from the first build).
struct SettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var pro: ProEntitlementStore

    var body: some View {
        List {
            Section {
                navRow("Sign In", "person.crop.circle", subtitle: auth.userName) { SignInSettingsView() }
                navRow("Streaming", "antenna.radiowaves.left.and.right") { StreamingSettingsView() }
                navRow("Library", "books.vertical") { LibrarySettingsView() }
                navRow("AI Features", "sparkles") { AISettingsView() }
                navRow("Bolera Pro", "star.circle", subtitle: pro.isPro ? "Unlocked" : nil) { ProSettingsView() }
                navRow("About", "info.circle") { AboutSettingsView() }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
    }

    @ViewBuilder
    private func navRow<Destination: View>(_ title: String, _ symbol: String,
                                           subtitle: String? = nil,
                                           @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                if let subtitle {
                    Spacer()
                    Text(subtitle).foregroundStyle(.secondary).font(.caption)
                }
            }
        }
    }
}

// MARK: - Sign In

private struct SignInSettingsView: View {
    @EnvironmentObject var auth: AuthManager

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

            Section {
                NavigationLink {
                    LastFmSettingsView()
                } label: {
                    Label("Last.fm", systemImage: "waveform")
                }
            } header: {
                Text("Connected Services")
            } footer: {
                Text("Sign in to Last.fm to scrobble your plays and sharpen AI mix recommendations.")
                    .font(.caption)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Sign In")
    }
}

// MARK: - Streaming

private struct StreamingSettingsView: View {
    @AppStorage("bolera.maxBitrate") private var maxBitrate: Int = 320
    @AppStorage("bolera.carplayBitrateEnabled") private var carplayBitrateEnabled: Bool = false
    @AppStorage("bolera.carplayBitrate") private var carplayBitrate: Int = 192

    var body: some View {
        List {
            Section {
                Picker("Max Streaming Bitrate", selection: $maxBitrate) {
                    Text("96 kbps").tag(96)
                    Text("128 kbps").tag(128)
                    Text("192 kbps").tag(192)
                    Text("256 kbps").tag(256)
                    Text("320 kbps").tag(320)
                    Text("Lossless").tag(1411)
                }
            } header: {
                Text("Quality")
            } footer: {
                Text("Wi-Fi streams at this quality. On cellular, Bolera automatically caps to a reliable rate so playback doesn't stall in patchy signal.")
                    .font(.caption)
            }

            Section {
                Toggle("Custom CarPlay Bitrate", isOn: $carplayBitrateEnabled)
                if carplayBitrateEnabled {
                    Picker("CarPlay Bitrate", selection: $carplayBitrate) {
                        Text("96 kbps").tag(96)
                        Text("128 kbps").tag(128)
                        Text("192 kbps").tag(192)
                        Text("256 kbps").tag(256)
                        Text("320 kbps").tag(320)
                    }
                }
            } header: {
                Text("CarPlay")
            } footer: {
                Text("When connected to CarPlay, stream at this bitrate instead of your normal setting — pick a lower rate so music keeps up through dead spots while driving. Off uses your Max Streaming Bitrate.")
                    .font(.caption)
            }

            Section("Playback") {
                CrossfadeRow()
                NavigationLink {
                    EQView()
                } label: {
                    Label("Equalizer", systemImage: "slider.vertical.3")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Streaming")
    }
}

/// Isolated subview that owns the AudioPlayer dependency so the whole
/// StreamingSettingsView body doesn't rebuild every time `currentTime` ticks.
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

// MARK: - Library

private struct LibrarySettingsView: View {
    @EnvironmentObject var auth: AuthManager
    @ObservedObject private var prefetcher = LibraryPrefetcher.shared
    @ObservedObject private var live = LiveFilterStore.shared
    @State private var cacheSizeText: String = "—"
    @State private var clearingCache = false

    var body: some View {
        List {
            Section("Offline") {
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
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Library")
        .task { refreshCacheSize() }
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
            let bytes = await Self.cacheDirsTotalBytes()
            let fmt = ByteCountFormatter()
            fmt.allowedUnits = [.useMB, .useKB]
            fmt.countStyle = .file
            let txt = fmt.string(fromByteCount: Int64(bytes))
            await MainActor.run { cacheSizeText = txt }
        }
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

    private static func cacheDirsTotalBytes() async -> UInt64 {
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

// MARK: - AI Features

private struct AISettingsView: View {
    @EnvironmentObject var pro: ProEntitlementStore
    @ObservedObject private var ai = CustomAIStore.shared
    @AppStorage("bolera.ai.moodMixEnabled") private var moodMixEnabled: Bool = true
    @State private var showPaywall = false
    @State private var showConsent = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        List {
            Section {
                Toggle("Enable AI Mood Mixes", isOn: $moodMixEnabled)
            } footer: {
                Text("Make-a-Mix turns a mood phrase into a playlist. Signing in to Last.fm (under Sign In) dramatically improves results.")
                    .font(.caption)
            }

            Section {
                if pro.isPro {
                    Toggle("Use a custom AI server", isOn: $ai.enabled)
                    if ai.enabled {
                        Picker("Provider", selection: $ai.providerId) {
                            ForEach(AIProviders.all) { Text($0.name).tag($0.id) }
                        }
                        TextField("Server URL", text: $ai.baseURL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                        if ai.preset.requiresKey || !ai.apiKey.isEmpty {
                            SecureField("API Key", text: $ai.apiKey)
                                .textContentType(.password)
                        }
                        TextField("Model", text: $ai.model)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        if let help = ai.preset.helpURL, let url = URL(string: help) {
                            Link("Get \(ai.preset.name) details", destination: url).font(.caption)
                        }

                        if ai.isConfigured && !ai.consentGranted {
                            Button {
                                showConsent = true
                            } label: {
                                Label("Review data sharing & allow", systemImage: "hand.raised")
                            }
                        }

                        Button {
                            runTest()
                        } label: {
                            HStack {
                                Text("Test Connection")
                                Spacer()
                                if testing { ProgressView() }
                            }
                        }
                        .disabled(testing || !ai.isConfigured)

                        if let r = testResult {
                            Text(r).font(.caption).foregroundStyle(testOK ? .green : .red)
                        }
                    }
                } else {
                    Button {
                        showPaywall = true
                    } label: {
                        HStack {
                            Label("Use a custom AI server", systemImage: "server.rack")
                            Spacer()
                            ProBadge()
                        }
                    }
                }
            } header: {
                Text("AI Engine")
            } footer: {
                Text("Off uses Apple's on-device intelligence — private, nothing leaves your device. A custom server sends only the mood text you type to the endpoint you choose, and only after you allow it. Works with OpenAI, OpenRouter, Groq, and self-hosted Ollama / LM Studio.")
                    .font(.caption)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("AI Features")
        .sheet(isPresented: $showPaywall) {
            NavigationStack { PaywallView() }.environmentObject(pro)
        }
        .sheet(isPresented: $showConsent) { consentSheet }
    }

    /// Explicit data-sharing consent (App Store guideline 5.1.2(i)): names the
    /// endpoint + the exact data sent, requires an affirmative tap.
    private var consentSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 40)).foregroundStyle(.tint)
                Text("Share mood text with your AI server?")
                    .font(.title2).bold()
                Text("When you use Make-a-Mix, Bolera will send the mood phrase you type to:")
                Text(ai.endpointHost.isEmpty ? ai.baseURL : ai.endpointHost)
                    .font(.headline).foregroundStyle(.tint)
                Text("That phrase is the only thing sent — never your library, account, or sign-in. This is a server you configured; its operator's own privacy terms apply. You can turn this off anytime.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button {
                    ai.grantConsent()
                    showConsent = false
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { showConsent = false }
                    .frame(maxWidth: .infinity)
            }
            .padding()
            .navigationTitle("Data Sharing")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            do {
                let r = try await ai.test()
                testResult = "Works — sample tags: " + r.tags.prefix(3).joined(separator: ", ")
                testOK = true
            } catch {
                testResult = error.localizedDescription
                testOK = false
            }
            testing = false
        }
    }
}

// MARK: - Bolera Pro

private struct ProSettingsView: View {
    @EnvironmentObject var pro: ProEntitlementStore
    @State private var showPaywall = false

    var body: some View {
        List {
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
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Bolera Pro")
        .sheet(isPresented: $showPaywall) {
            NavigationStack { PaywallView() }
                .environmentObject(pro)
        }
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    var body: some View {
        List {
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
        .navigationTitle("About")
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
}
