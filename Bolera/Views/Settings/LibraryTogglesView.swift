import SwiftUI
import BoleraCore

struct LibraryTogglesView: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var visibility: LibraryVisibilityStore
    @State private var libraries: [BaseItem] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            Section {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if libraries.isEmpty {
                    ContentUnavailableView("No libraries",
                                           systemImage: "rectangle.stack",
                                           description: Text(error ?? "Sign in to your Jellyfin server to see your libraries."))
                } else {
                    ForEach(libraries) { lib in
                        Toggle(isOn: bindingFor(lib)) {
                            VStack(alignment: .leading) {
                                Text(lib.Name)
                                if let kind = lib.CollectionType {
                                    Text(kind.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } footer: {
                Text("Hidden libraries are skipped on Home, Library, Search, Shuffle-All, and CarPlay.")
            }
        }
        .navigationTitle("Libraries")
        .task { await load() }
    }

    private func bindingFor(_ lib: BaseItem) -> Binding<Bool> {
        Binding(
            get: { !visibility.isHidden(lib.Id) },
            set: { visibility.setHidden(lib.Id, !$0) }
        )
    }

    private func load() async {
        loading = true
        defer { loading = false }
        guard let url = auth.serverURL else {
            error = "Not signed in."
            return
        }
        do {
            let client = JellyfinClient(baseURL: url, auth: auth)
            let views = try await client.userViews()
            libraries = views
                .filter { $0.CollectionType == "music" }
                .sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
