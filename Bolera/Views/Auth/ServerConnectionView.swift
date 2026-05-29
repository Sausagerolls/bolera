import SwiftUI
import BoleraCore

struct ServerConnectionView: View {
    @EnvironmentObject var auth: AuthManager
    @State private var server: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.05, blue: 0.08),
                                    Color(red: 0.12, green: 0.05, blue: 0.18)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 60)
                    VStack(spacing: 8) {
                        Image("BoleraGlyph")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 96, height: 96)
                        Text("Bolera")
                            .font(.system(size: 36, weight: .heavy))
                        Text("Music from your Jellyfin server")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 12)

                    VStack(spacing: 14) {
                        labeled("Server URL", placeholder: "https://jellyfin.example.com", text: $server, keyboard: .URL)
                        labeled("Username", placeholder: "user", text: $username)
                        SecureField("Password", text: $password)
                            .padding(14)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .padding(.horizontal)

                    if let error = error {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Button(action: signIn) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.accentColor)
                                .frame(height: 50)
                            if loading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Sign In")
                                    .font(.headline)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .disabled(loading || !canSubmit)
                    .opacity(canSubmit ? 1 : 0.5)

                    Spacer()
                }
                .padding(.vertical)
            }
        }
    }

    private var canSubmit: Bool {
        URL(string: server) != nil && !username.isEmpty
    }

    private func labeled(_ title: String, placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func signIn() {
        guard var url = URL(string: server) else { return }
        if url.scheme == nil {
            url = URL(string: "https://\(server)") ?? url
        }
        loading = true
        error = nil
        Task {
            do {
                try await auth.login(server: url, username: username, password: password)
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
            await MainActor.run { self.loading = false }
        }
    }
}

// MARK: - Last.fm onboarding (post sign-in, skippable)

struct LastFmOnboardingView: View {
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
                    Spacer().frame(height: 60)
                    VStack(spacing: 10) {
                        Image("BoleraGlyph")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 84, height: 84)
                        Text("Connect Last.fm")
                            .font(.system(size: 30, weight: .heavy))
                        Text("Optional, but it makes Bolera better.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        FeatureRow(icon: "person.2.fill",
                                   title: "Better Similar Artists",
                                   subtitle: "Curated by Last.fm instead of guessed.")
                        FeatureRow(icon: "text.alignleft",
                                   title: "Artist Bios",
                                   subtitle: "Background info on every artist page.")
                        FeatureRow(icon: "wand.and.stars",
                                   title: "Better AI + Daily Mixes",
                                   subtitle: "The Make-a-Mix generator and daily playlists are dramatically richer with Last.fm tag data.")
                        FeatureRow(icon: "antenna.radiowaves.left.and.right",
                                   title: "Optional Scrobbling",
                                   subtitle: "Build your listening history on last.fm.")
                    }
                    .padding(.horizontal, 24)

                    VStack(spacing: 12) {
                        TextField("Last.fm username", text: $username)
                            .textContentType(.username)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        if let err = error {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                        Button(action: signIn) {
                            if signingIn {
                                ProgressView().tint(.white)
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                            } else {
                                Text("Sign In with Last.fm").bold()
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
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
                    .padding(.horizontal, 24)

                    Text("You can connect Last.fm any time from Settings → Last.fm.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.bottom, 40)
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

private struct FeatureRow: View {
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
