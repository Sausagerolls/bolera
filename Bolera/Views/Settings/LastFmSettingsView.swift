import SwiftUI
import BoleraCore

struct LastFmSettingsView: View {
    @ObservedObject private var lastFm = LastFmService.shared
    @State private var username = ""
    @State private var password = ""
    @State private var error: String?
    @State private var working = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            if lastFm.isAuthenticated, let user = lastFm.username {
                Section("Account") {
                    LabeledContent("Signed in as", value: user)
                    Toggle("Scrobble plays", isOn: $lastFm.enabled)
                    Button("Sign Out", role: .destructive) { lastFm.signOut() }
                }
            } else if !lastFm.hasAppCredentials {
                Section("Account") {
                    Text("Last.fm support not configured in this build.")
                        .foregroundStyle(.red).font(.caption)
                }
            } else {
                Section("Sign In with Last.fm") {
                    TextField("Last.fm username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                    if let err = error {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                    Button(action: signIn) {
                        if working { ProgressView() } else { Text("Sign In") }
                    }
                    .disabled(working || username.isEmpty || password.isEmpty)
                }
            }

            Section {
                Text("Scrobbling follows Last.fm's rules: the track must be longer than 30 seconds, and you must have played at least 50% of it (or 4 minutes, whichever comes first) before a scrobble is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced: use my own Last.fm app", isExpanded: $showAdvanced) {
                    TextField("API Key", text: $lastFm.apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("API Secret", text: $lastFm.apiSecret)
                    Link("Register an app at last.fm/api/account/create",
                         destination: URL(string: "https://www.last.fm/api/account/create")!)
                        .font(.caption)
                    Text("Leave both blank to use Bolera's built-in credentials.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Last.fm")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signIn() {
        working = true
        error = nil
        // Hand the password to the task and clear the field immediately —
        // don't keep the plaintext sitting in @State for the request's
        // lifetime (or forever, if the task errors before the cleanup ran).
        let pwd = password
        password = ""
        Task {
            do {
                try await lastFm.signIn(username: username, password: pwd)
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
            await MainActor.run { self.working = false }
        }
    }
}

struct ListenBrainzSettingsView: View {
    @ObservedObject private var listenBrainz = ListenBrainzService.shared
    @State private var token = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        Form {
            if listenBrainz.isAuthenticated {
                Section("Account") {
                    LabeledContent("Signed in as", value: listenBrainz.username ?? "—")
                    Toggle("Submit listens", isOn: $listenBrainz.enabled)
                    if let problem = listenBrainz.lastError {
                        Text(problem).foregroundStyle(.red).font(.caption)
                    }
                    Button("Sign Out", role: .destructive) { listenBrainz.signOut() }
                }
            } else {
                Section {
                    SecureField("User token", text: $token)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if let err = error {
                        Text(err).foregroundStyle(.red).font(.caption)
                    }
                    Button(action: signIn) {
                        if working { ProgressView() } else { Text("Connect") }
                    }
                    .disabled(working || token.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Connect ListenBrainz")
                } footer: {
                    Link("Find your user token at listenbrainz.org/settings",
                         destination: URL(string: "https://listenbrainz.org/settings/")!)
                }
            }

            Section {
                Text("Listens follow the same rules as Last.fm: the track must be longer than 30 seconds, and you must have played at least 50% of it (or 4 minutes, whichever comes first). Listens made offline are sent when you're back online.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("If your Jellyfin server already has the ListenBrainz plugin enabled, leave this off — otherwise every listen is counted twice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("ListenBrainz")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signIn() {
        working = true
        error = nil
        let candidate = token
        Task {
            do {
                try await listenBrainz.signIn(token: candidate)
                await MainActor.run { self.token = "" }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
            await MainActor.run { self.working = false }
        }
    }
}
