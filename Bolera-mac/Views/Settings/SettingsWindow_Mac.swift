import SwiftUI
import BoleraCore

struct SettingsWindow_Mac: View {
    var body: some View {
        TabView {
            GeneralSettings_Mac()
                .tabItem { Label("General", systemImage: "gear") }
            PlaybackSettings_Mac()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            LastFmSettings_Mac()
                .tabItem { Label("Last.fm", systemImage: "waveform") }
            ProSettings_Mac()
                .tabItem { Label("Pro", systemImage: "star.fill") }
            AboutSettings_Mac()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 460)
    }
}

private struct LastFmSettings_Mac: View {
    @EnvironmentObject var lastFm: LastFmService
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var signingIn = false
    @State private var lastError: String?
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section("Account") {
                if lastFm.isAuthenticated {
                    LabeledContent("Signed in as", value: lastFm.username ?? "")
                    Button("Sign Out", role: .destructive) { lastFm.signOut() }
                } else if !lastFm.hasAppCredentials {
                    Text("Last.fm support not configured in this build.")
                        .font(.caption).foregroundStyle(.red)
                } else {
                    TextField("Last.fm username", text: $username)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        signIn()
                    } label: {
                        if signingIn {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Sign In with Last.fm")
                        }
                    }
                    .disabled(signingIn || username.isEmpty || password.isEmpty)
                }
                if let err = lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Scrobbling") {
                Toggle("Scrobble plays + send now-playing", isOn: $lastFm.enabled)
                    .disabled(!lastFm.isAuthenticated)
                Text("Tracks > 30s, scrobbled past 50% or 4 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Last.fm also drives the Similar Artists section on artist pages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("Advanced: use my own Last.fm app", isExpanded: $showAdvanced) {
                    TextField("API Key", text: $lastFm.apiKey)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Shared Secret", text: $lastFm.apiSecret)
                        .textFieldStyle(.roundedBorder)
                    Link("Register an app at last.fm/api/account/create",
                         destination: URL(string: "https://www.last.fm/api/account/create")!)
                        .font(.caption)
                    Text("Leave both blank to use Bolera's built-in credentials.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func signIn() {
        signingIn = true
        lastError = nil
        Task {
            do {
                try await lastFm.signIn(username: username, password: password)
                await MainActor.run {
                    signingIn = false
                    password = ""
                }
            } catch {
                await MainActor.run {
                    signingIn = false
                    lastError = error.localizedDescription
                }
            }
        }
    }
}

private struct GeneralSettings_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @ObservedObject private var prefetcher = LibraryPrefetcher.shared
    @AppStorage("bolera.maxBitrate") private var maxBitrate: Int = 320

    var body: some View {
        Form {
            Section("Account") {
                if let user = auth.userName {
                    LabeledContent("Signed in as", value: user)
                }
                if let url = auth.serverURL {
                    LabeledContent("Server", value: url.host ?? url.absoluteString)
                }
                Button("Sign Out", role: .destructive) { auth.logout() }
            }
            Section("Library") {
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
                if let last = prefetcher.lastCompleted {
                    LabeledContent("Last updated",
                                   value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Streaming") {
                Picker("Max Bitrate", selection: $maxBitrate) {
                    Text("96 kbps").tag(96)
                    Text("128 kbps").tag(128)
                    Text("192 kbps").tag(192)
                    Text("256 kbps").tag(256)
                    Text("320 kbps").tag(320)
                    Text("Lossless").tag(1411)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct PlaybackSettings_Mac: View {
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var auth: AuthManager
    @ObservedObject private var live = LiveFilterStore.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("bolera.ai.moodMixEnabled") private var moodMixEnabled: Bool = true

    var body: some View {
        Form {
            Section("Crossfade") {
                Slider(value: $player.crossfadeDuration, in: 0...12, step: 1) {
                    Text("Duration")
                }
                Text(player.crossfadeDuration > 0
                     ? "\(Int(player.crossfadeDuration)) seconds"
                     : "Off (hard cut)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Equalizer") {
                Button("Open Equalizer Window…") {
                    openWindow(id: "eq")
                }
                Text("Or use Window → Equalizer (⌘⇧E).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI Features") {
                Toggle("Enable AI Mood Mixes", isOn: $moodMixEnabled)
                Text("Make-a-Mix uses Apple Intelligence to turn a mood phrase into a playlist. Last.fm sign-in dramatically improves results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Mixes & Radio") {
                Toggle("Exclude Live Recordings", isOn: $live.enabled)
                    .onChange(of: live.enabled) { _, _ in refreshLiveAlbums() }
                if live.enabled {
                    TextField("Live tag", text: $live.tag)
                        .onSubmit { refreshLiveAlbums() }
                }
                Text("Keeps live recordings out of daily mixes, Make-a-Mix, and radio — detected by name and by the tag/genre above. Doesn't affect browsing or playing an album directly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func refreshLiveAlbums() {
        guard let url = auth.serverURL else { return }
        Task { await LiveFilterStore.shared.refresh(client: JellyfinClient(baseURL: url, auth: auth)) }
    }
}

private struct ProSettings_Mac: View {
    @EnvironmentObject var pro: ProEntitlementStore
    @EnvironmentObject var libVisibility: LibraryVisibilityStore
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var auth: AuthManager

    @State private var libraries: [BaseItem] = []
    @State private var showPaywall = false

    var body: some View {
        Form {
            Section("Bolera Pro") {
                if pro.isPro {
                    HStack {
                        Label("Unlocked", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.tint)
                        Spacer()
                    }
                } else {
                    Button("Unlock Bolera Pro — \(displayPrice)") { showPaywall = true }
                        .controlSize(.large)
                    Button("Restore Purchases") {
                        Task { await pro.restore() }
                    }
                }
            }

            Section("Libraries") {
                if libraries.isEmpty {
                    Text("Sign in to your server to manage library visibility.")
                        .foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(libraries) { lib in
                        Toggle(lib.Name, isOn: Binding(
                            get: { !libVisibility.isHidden(lib.Id) },
                            set: { libVisibility.setHidden(lib.Id, !$0) }
                        ))
                        .disabled(!pro.isPro)
                    }
                }
            }

            ignoreSection(title: "Ignored Tracks",
                          empty: "Right-click a track and choose Ignore.",
                          ids: ignored.ignored,
                          remove: { ignored.unignore($0) })

            ignoreSection(title: "Ignored Artists",
                          empty: "Right-click an artist tile and choose Ignore Artist.",
                          ids: ignored.ignoredArtists,
                          remove: { ignored.unignoreArtist($0) })

            ignoreSection(title: "Ignored Albums",
                          empty: "Right-click an album tile and choose Ignore Album.",
                          ids: ignored.ignoredAlbums,
                          remove: { ignored.unignoreAlbum($0) })
        }
        .formStyle(.grouped)
        .padding()
        .task { await loadLibraries() }
        .sheet(isPresented: $showPaywall) {
            PaywallView_Mac().environmentObject(pro)
        }
    }

    @ViewBuilder
    private func ignoreSection(title: String,
                               empty: String,
                               ids: Set<String>,
                               remove: @escaping (String) -> Void) -> some View {
        Section("\(title) (\(ids.count))") {
            if ids.isEmpty {
                Text(empty).foregroundStyle(.secondary).font(.caption)
            } else {
                List {
                    ForEach(Array(ids), id: \.self) { id in
                        HStack {
                            Text(ignored.labels[id] ?? id).lineLimit(1)
                            Spacer()
                            Button("Remove") { remove(id) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    private var displayPrice: String {
        pro.products.first(where: { $0.id == ProProductIDs.lifetime })?.displayPrice ?? "$4.99"
    }

    private func loadLibraries() async {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let views = try? await client.userViews() {
            libraries = views
                .filter { $0.CollectionType == "music" }
                .sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
        }
    }
}

private struct AboutSettings_Mac: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 64)).foregroundStyle(.tint)
            Text("Bolera").font(.title).bold()
            Text("Version \(AuthManager.clientVersion)").foregroundStyle(.secondary)
            Text("Native Jellyfin music client").font(.caption).foregroundStyle(.tertiary)

            HStack(spacing: 10) {
                Link(destination: contactURL()) {
                    Label("Contact Developer", systemImage: "envelope.fill")
                }
                .buttonStyle(.borderedProminent)
                Link("Visit Website",
                     destination: URL(string: "https://giantmushroom.studio/bolera")!)
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 8)

            HStack(spacing: 16) {
                Link("Privacy Policy",
                     destination: URL(string: "https://giantmushroom.studio/bolera/privacy.html")!)
                Link("Terms of Use",
                     destination: URL(string: "https://giantmushroom.studio/bolera/terms.html")!)
            }
            .font(.caption)
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    private func contactURL() -> URL {
        let subject = "Bolera support"
        let body = """
        \n\n---\nApp: Bolera \(AuthManager.clientVersion)\nDevice: macOS
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
