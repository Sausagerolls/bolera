import SwiftUI
import BoleraCore

struct SettingsWindow_Mac: View {
    var body: some View {
        TabView {
            GeneralSettings_Mac()
                .tabItem { Label("General", systemImage: "gear") }
            PlaybackSettings_Mac()
                .tabItem { Label("Playback", systemImage: "play.circle") }
            NavigationSettings_Mac()
                .tabItem { Label("Navigation", systemImage: "hand.draw") }
            ScrobblingSettings_Mac()
                .tabItem { Label("Scrobbling", systemImage: "music.note.list") }
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

    // Sections only — hosted inside ScrobblingSettings_Mac's Form.
    var body: some View {
        Group {
            Section("Last.fm") {
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
            Section("Last.fm scrobbling") {
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

/// Every scrobbling service — Last.fm, Libre.fm and ListenBrainz — in one tab.
private struct ScrobblingSettings_Mac: View {
    var body: some View {
        Form {
            LastFmSettings_Mac()
            LibreFmSettings_Mac()
            ListenBrainzSettings_Mac()
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct LibreFmSettings_Mac: View {
    @ObservedObject private var libreFm = LibreFmService.shared
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var signingIn = false
    @State private var lastError: String?

    var body: some View {
        Section("Libre.fm") {
            if libreFm.isAuthenticated {
                LabeledContent("Signed in as", value: libreFm.username ?? "—")
                Toggle("Scrobble plays + send now-playing", isOn: $libreFm.enabled)
                if let problem = libreFm.lastError {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                Button("Sign Out", role: .destructive) { libreFm.signOut() }
            } else {
                TextField("Libre.fm username", text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                Button {
                    signIn()
                } label: {
                    if signingIn {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In with Libre.fm")
                    }
                }
                .disabled(signingIn || username.isEmpty || password.isEmpty)
                Link("Create a free account at libre.fm", destination: URL(string: "https://libre.fm/")!)
                    .font(.caption)
            }
            if let err = lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Text("Free, open-source scrobbling. Tracks > 30s, scrobbled past 50% or 4 minutes; offline scrobbles are sent when you're back online.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func signIn() {
        signingIn = true
        lastError = nil
        let user = username, pwd = password
        password = ""
        Task {
            do {
                try await libreFm.signIn(username: user, password: pwd)
                await MainActor.run { signingIn = false }
            } catch {
                await MainActor.run {
                    signingIn = false
                    lastError = error.localizedDescription
                }
            }
        }
    }
}

private struct ListenBrainzSettings_Mac: View {
    @ObservedObject private var listenBrainz = ListenBrainzService.shared
    @State private var token: String = ""
    @State private var connecting = false
    @State private var lastError: String?

    // Sections only — hosted inside OpenScrobblingSettings_Mac's Form.
    var body: some View {
        Group {
            Section("ListenBrainz") {
                if listenBrainz.isAuthenticated {
                    LabeledContent("Signed in as", value: listenBrainz.username ?? "—")
                    if let problem = listenBrainz.lastError {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    Button("Sign Out", role: .destructive) { listenBrainz.signOut() }
                } else {
                    SecureField("User token", text: $token)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        connect()
                    } label: {
                        if connecting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Connect ListenBrainz")
                        }
                    }
                    .disabled(connecting || token.trimmingCharacters(in: .whitespaces).isEmpty)
                    Link("Find your user token at listenbrainz.org/settings",
                         destination: URL(string: "https://listenbrainz.org/settings/")!)
                        .font(.caption)
                }
                if let err = lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            Section("ListenBrainz listens") {
                Toggle("Submit listens + send now-playing", isOn: $listenBrainz.enabled)
                    .disabled(!listenBrainz.isAuthenticated)
                Text("Tracks > 30s, submitted past 50% or 4 minutes. Offline listens are sent when you're back online.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("If your Jellyfin server already has the ListenBrainz plugin enabled, leave this off — otherwise every listen is counted twice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func connect() {
        connecting = true
        lastError = nil
        let candidate = token
        Task {
            do {
                try await listenBrainz.signIn(token: candidate)
                await MainActor.run {
                    connecting = false
                    token = ""
                }
            } catch {
                await MainActor.run {
                    connecting = false
                    lastError = error.localizedDescription
                }
            }
        }
    }
}

private struct NavigationSettings_Mac: View {
    private struct Shortcut: Identifiable {
        let id = UUID()
        let icon: String
        let action: String
        let gesture: String
        let key: String
    }

    private let rows: [Shortcut] = [
        .init(icon: "chevron.left",  action: "Back",
              gesture: "Swipe right with two fingers", key: "⌘ ["),
        .init(icon: "chevron.right", action: "Forward",
              gesture: "Swipe left with two fingers", key: "⌘ ]"),
        .init(icon: "magnifyingglass", action: "Search",
              gesture: "—", key: "⌘ F"),
    ]

    var body: some View {
        Form {
            Section("Trackpad & Keyboard") {
                ForEach(rows) { row in
                    HStack(spacing: 12) {
                        Image(systemName: row.icon)
                            .frame(width: 22)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.action).font(.body)
                            Text(row.gesture)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(row.key)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                Text("Back and Forward move through pages you've visited — albums, artists, and the lists you open from the Home screen. You can also use the ◀ ▶ buttons in the toolbar.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Trackpad swipes follow the macOS \u{201C}Swipe between pages\u{201D} setting (System Settings → Trackpad → More Gestures).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct GeneralSettings_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @ObservedObject private var prefetcher = LibraryPrefetcher.shared
    @AppStorage("bolera.maxBitrate") private var maxBitrate: Int = 320
    @AppStorage(MacA11y.scaleKey) private var uiScale = 1.0
    @AppStorage(MacA11y.colourModeKey) private var colourMode = MacA11y.ColourMode.standard.rawValue
    @AppStorage(MacA11y.labelsKey) private var controlLabels = false

    var body: some View {
        Form {
            Section("Accessibility") {
                Picker("Control size", selection: $uiScale) {
                    ForEach(MacA11y.scales, id: \.self) { s in
                        Text(MacA11y.name(for: s)).tag(s)
                    }
                }
                Text("Sizes the player bar and full-screen player controls. Also in View → Make Controls Larger / Smaller (⌘+ / ⌘−).")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Colour vision", selection: $colourMode) {
                    ForEach(MacA11y.ColourMode.allCases) { m in
                        Text(m.name).tag(m.rawValue)
                    }
                }
                Text("Replaces the purple highlight with a colour that stays distinct for that type of colour blindness, and marks controls that are switched on (shuffle, repeat, favourite…) with a dot so they never rely on colour alone. Album art is colour-corrected to match; in Monochrome it's shown in greyscale with boosted contrast.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show control labels", isOn: $controlLabels)
                Text("Adds a short label under each player control.")
                    .font(.caption).foregroundStyle(.secondary)
            }
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
                        ProgressView(value: prefetcher.progress).tint(MacA11y.accent)
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
    @ObservedObject private var ai = CustomAIStore.shared
    @ObservedObject private var pro = ProEntitlementStore.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage("bolera.ai.moodMixEnabled") private var moodMixEnabled: Bool = true
    @AppStorage(inlineVolumeSliderKey) private var inlineVolume = false
    @State private var showConsent = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        Form {
            Section("Volume") {
                Toggle("Always show volume slider", isOn: $inlineVolume)
                Text("Shows the slider next to the speaker button in the player bar and full-screen player, instead of in a pop-up when you click the button.")
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
                Text("Make-a-Mix turns a mood phrase into a playlist. Last.fm sign-in dramatically improves results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI Engine") {
                if pro.isPro {
                    Toggle("Use a custom AI server", isOn: $ai.enabled)
                    if ai.enabled {
                        Picker("Provider", selection: $ai.providerId) {
                            ForEach(AIProviders.all) { Text($0.name).tag($0.id) }
                        }
                        TextField("Server URL", text: $ai.baseURL)
                            .autocorrectionDisabled()
                        if ai.preset.requiresKey || !ai.apiKey.isEmpty {
                            SecureField("API Key", text: $ai.apiKey)
                        }
                        TextField("Model", text: $ai.model)
                            .autocorrectionDisabled()
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
                        HStack {
                            Button("Test Connection") { runTest() }
                                .disabled(testing || !ai.isConfigured || !ai.consentGranted)
                            if testing { ProgressView().controlSize(.small) }
                        }
                        if let r = testResult {
                            Text(r).font(.caption).foregroundStyle(testOK ? .green : .red)
                        }
                    }
                } else {
                    Text("Custom AI server requires Bolera Pro.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Off uses Apple's on-device intelligence — private, nothing leaves your Mac. A custom server sends only the mood text you type to the endpoint you choose, after you allow it. Works with OpenAI, OpenRouter, Groq, and self-hosted Ollama / LM Studio.")
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
        .sheet(isPresented: $showConsent) { consentSheet }
    }

    /// Explicit data-sharing consent (App Store guideline 5.1.2(i)).
    private var consentSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Share mood text with your AI server?", systemImage: "hand.raised.fill")
                .font(.title3).bold()
            Text("When you use Make-a-Mix, Bolera will send the mood phrase you type to:")
            Text(ai.endpointHost.isEmpty ? ai.baseURL : ai.endpointHost)
                .font(.headline).foregroundStyle(.tint)
            Text("That phrase is the only thing sent — never your library, account, or sign-in. This is a server you configured; its operator's own privacy terms apply. You can turn this off anytime.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showConsent = false }
                Button("Allow") { ai.grantConsent(); showConsent = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
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

    private func refreshLiveAlbums() {
        guard let url = auth.serverURL else { return }
        let client = JellyfinClient(baseURL: url, auth: auth)
        Task {
            await LiveFilterStore.shared.refresh(client: client)
            await DailyPlaylistStore.shared.regenerate(client: client, auth: auth, lastFm: LastFmService.shared)
        }
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

            #if DEBUG
            Section("Developer") {
                Toggle("Simulate Pro", isOn: $pro.debugSimulatePro)
                Text("Debug builds only — StoreKit can't see your purchase on a local build, so Pro features hide. Turn on to test them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif

            Section("Libraries") {
                if libraries.isEmpty {
                    Text("Sign in to your server to manage library visibility.")
                        .foregroundStyle(.secondary).font(.caption)
                } else {
                    ForEach(libraries) { lib in
                        Toggle(lib.Name, isOn: Binding(
                            get: { !libVisibility.isHidden(lib.Id) },
                            set: { visible in
                                libVisibility.setHidden(lib.Id, !visible)
                                // Re-resolve the hidden libraries' album/artist IDs
                                // so the filter reflects the toggle straight away,
                                // and drop today's mixes so they rebuild.
                                guard let url = auth.serverURL else { return }
                                Task { await libVisibility.refresh(client: JellyfinClient(baseURL: url, auth: auth)) }
                                DailyPlaylistStore.shared.clear()
                            }
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
            Image("BoleraGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Bolera").font(.title).bold()
            Text("Version \(AuthManager.displayVersion)").foregroundStyle(.secondary)
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
        \n\n---\nApp: Bolera \(AuthManager.displayVersion)\nDevice: macOS
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
