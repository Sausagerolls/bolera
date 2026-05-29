import SwiftUI
import BoleraCore

struct SidebarView_Mac: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var libVisibility: LibraryVisibilityStore
    @EnvironmentObject var pinned: PinnedItemsStore
    @EnvironmentObject var player: AudioPlayer
    @EnvironmentObject var nav: MacNavCoordinator
    @EnvironmentObject var pro: ProEntitlementStore
    @Environment(\.openSettings) private var openSettings
    @Binding var selection: SidebarSelection?

    @State private var libraries: [BaseItem] = []
    @State private var loadingLibs = false
    @State private var avatar: PlatformImage?

    var body: some View {
        VStack(spacing: 0) {
            sidebarList
            statusBanner
        }
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            Section("Discover") {
                row("Home", icon: "house.fill", tag: .home)
                row("Search", icon: "magnifyingglass", tag: .search)
                row("Favorites", icon: "heart.fill", tag: .favorites)
                row("Downloads", icon: "arrow.down.circle.fill", tag: .downloads)
            }

            Section("Library") {
                row("Artists", icon: "music.mic", tag: .artists)
                row("Albums", icon: "square.stack.fill", tag: .albums)
                row("Playlists", icon: "list.bullet.rectangle", tag: .playlists)
            }

            if !pinned.pins.isEmpty {
                Section("Pinned") {
                    ForEach(pinned.pins) { pin in
                        Button {
                            open(pin: pin)
                        } label: {
                            HStack {
                                Image(systemName: pin.type == "MusicArtist" ? "music.mic" : "opticaldisc")
                                    .foregroundStyle(.tint)
                                Text(pin.name).lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                pinned.unpin(itemId: pin.itemId)
                            } label: {
                                Label("Unpin", systemImage: "pin.slash")
                            }
                        }
                    }
                }
            }

            if !libraries.isEmpty {
                Section("Jellyfin Libraries") {
                    ForEach(libraries) { lib in
                        HStack {
                            Image(systemName: icon(for: lib.CollectionType))
                                .foregroundStyle(.tint)
                            Text(lib.Name)
                            Spacer()
                            if libVisibility.isHidden(lib.Id) {
                                Image(systemName: "eye.slash")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                        .tag(SidebarSelection.library(lib.Id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .task { await loadLibs() }
    }

    private var statusBanner: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                avatarView
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(.separator, lineWidth: 0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(auth.userName ?? "Signed Out")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(pro.isPro ? "Bolera Pro" : "Bolera Basic")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .task(id: auth.userId) { await loadAvatar() }
        // Refetch the user avatar whenever the app becomes active so
        // changes made on the Jellyfin server show up without an app
        // restart. Adds a cache-busting timestamp so ImageCache misses
        // and we get the latest image.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await loadAvatar(force: true) }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        if let avatar {
            Image(nsImage: avatar).resizable().scaledToFill()
        } else {
            ZStack {
                Color.gray.opacity(0.2)
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadAvatar(force: Bool = false) async {
        guard let serverURL = auth.serverURL,
              let userId = auth.userId else {
            await MainActor.run { self.avatar = nil }
            return
        }
        // Jellyfin's user avatar endpoint. Returns 404 if user has no
        // primary image; ImageCache silently returns nil on miss.
        guard var comps = URLComponents(url: serverURL.appendingPathComponent("Users/\(userId)/Images/Primary"),
                                        resolvingAgainstBaseURL: false) else { return }
        var items: [URLQueryItem] = [URLQueryItem(name: "maxWidth", value: "128")]
        if force {
            // Cache-bust: a unique query each foreground means we skip
            // both ImageCache and any HTTP intermediate caches and pull
            // whatever's currently on the Jellyfin server.
            items.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970))))
        }
        comps.queryItems = items
        guard let url = comps.url else { return }
        let img = await ImageCache.shared.load(
            url: url,
            headers: ["Authorization": auth.authHeader()])
        await MainActor.run { if img != nil || !force { self.avatar = img } }
    }

    private func open(pin: PinnedItem) {
        let stub = BaseItem.stub(id: pin.itemId, name: pin.name, type: pin.type)
        if pin.type == "MusicArtist" {
            nav.openArtist(stub)
        } else {
            nav.openAlbum(stub)
        }
    }

    private func row(_ title: String, icon: String, tag: SidebarSelection) -> some View {
        Label(title, systemImage: icon).tag(tag)
    }

    private func icon(for kind: String?) -> String {
        switch kind {
        case "music": return "music.note"
        case "movies": return "film"
        case "tvshows": return "tv"
        case "books": return "book"
        default: return "folder"
        }
    }

    private func loadLibs() async {
        guard !loadingLibs, let url = auth.serverURL else { return }
        loadingLibs = true
        defer { loadingLibs = false }
        let client = JellyfinClient(baseURL: url, auth: auth)
        if let views = try? await client.userViews() {
            libraries = views
                .filter { $0.CollectionType == "music" }
                .sorted { $0.Name.localizedCaseInsensitiveCompare($1.Name) == .orderedAscending }
        }
    }
}
