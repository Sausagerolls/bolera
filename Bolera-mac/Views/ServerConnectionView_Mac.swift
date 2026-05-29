import SwiftUI
import BoleraCore

struct ServerConnectionView_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @State private var server: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var loading = false
    @State private var error: String?
    @State private var signInTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.06, green: 0.06, blue: 0.10),
                                    Color(red: 0.18, green: 0.05, blue: 0.22)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Image("BoleraGlyph")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 96, height: 96)
                Text("Bolera").font(.system(size: 36, weight: .heavy))
                Text("Sign in to your Jellyfin server").foregroundStyle(.secondary)

                VStack(spacing: 10) {
                    TextField("https://jellyfin.example.com", text: $server)
                        .textFieldStyle(.roundedBorder)
                    TextField("Username", text: $username)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { signIn() }
                }
                .frame(maxWidth: 380)

                if let err = error {
                    Text(err).font(.callout).foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }

                Button(action: signIn) {
                    if loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign In").frame(maxWidth: 200)
                    }
                }
                .keyboardShortcut(.return)
                .controlSize(.large)
                .disabled(loading || !canSubmit)

                if loading {
                    Button("Cancel") { cancelSignIn() }
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                }

                Spacer()
            }
            .padding(40)
        }
    }

    private var canSubmit: Bool {
        URL(string: server) != nil && !username.isEmpty
    }

    private func signIn() {
        guard canSubmit else { return }
        guard var url = URL(string: server) else { return }
        if url.scheme == nil {
            url = URL(string: "https://\(server)") ?? url
        }
        loading = true
        error = nil
        signInTask = Task {
            do {
                try await auth.login(server: url, username: username, password: password)
            } catch is CancellationError {
                // user cancelled — message set by cancelSignIn()
            } catch let u as URLError where u.code == .cancelled {
                // URLSession surfaced the cancel
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
            await MainActor.run { self.loading = false; self.signInTask = nil }
        }
    }

    private func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        loading = false
        error = "Sign in cancelled."
    }
}

// MARK: - Last.fm onboarding (post sign-in, skippable)

struct LastFmOnboardingView_Mac: View {
    @ObservedObject private var lastFm = LastFmService.shared
    let onFinish: () -> Void

    @State private var username: String = ""
    @State private var password: String = ""
    @State private var signingIn = false
    @State private var error: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.08),
                                    Color(red: 0.12, green: 0.05, blue: 0.18)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 28) {
                    Spacer().frame(height: 50)
                    VStack(spacing: 10) {
                        Image("BoleraGlyph")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 84, height: 84)
                        Text("Connect Last.fm")
                            .font(.system(size: 30, weight: .heavy))
                        Text("Optional, but it makes Bolera better.")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        FeatureRow_Mac(icon: "person.2.fill",
                                       title: "Better Similar Artists",
                                       subtitle: "Curated by Last.fm instead of guessed.")
                        FeatureRow_Mac(icon: "text.alignleft",
                                       title: "Artist Bios",
                                       subtitle: "Background info on every artist page.")
                        FeatureRow_Mac(icon: "wand.and.stars",
                                       title: "Better AI + Daily Mixes",
                                       subtitle: "The Make-a-Mix generator and daily playlists are dramatically richer with Last.fm tag data.")
                        FeatureRow_Mac(icon: "antenna.radiowaves.left.and.right",
                                       title: "Optional Scrobbling",
                                       subtitle: "Build your listening history on last.fm.")
                    }
                    .frame(maxWidth: 380)

                    VStack(spacing: 12) {
                        TextField("Last.fm username", text: $username)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $password)
                            .textFieldStyle(.roundedBorder)
                        if let err = error {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        Button(action: signIn) {
                            if signingIn {
                                ProgressView().controlSize(.small)
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                            } else {
                                Text("Sign In with Last.fm").bold()
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(signingIn || username.isEmpty)

                        Button("Skip for now", action: onFinish)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: 380)

                    Text("You can connect Last.fm any time from Settings → Last.fm.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(40)
            }
        }
    }

    private func signIn() {
        signingIn = true
        error = nil
        Task {
            do {
                try await lastFm.signIn(username: username, password: password)
                await MainActor.run {
                    signingIn = false
                    onFinish()
                }
            } catch {
                await MainActor.run {
                    signingIn = false
                    self.error = error.localizedDescription
                }
            }
        }
    }
}

private struct FeatureRow_Mac: View {
    let icon: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
