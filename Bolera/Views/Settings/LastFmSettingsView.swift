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
        Task {
            do {
                try await lastFm.signIn(username: username, password: password)
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
            await MainActor.run {
                self.working = false
                self.password = ""
            }
        }
    }
}
