import SwiftUI
import BoleraCore

/// Full long-press menu for a track, reusable across every track list
/// (album, playlist, queue, search, downloads, now-playing). Self-contained:
/// hosts its own Add-to-Playlist sheet and favourite state.
struct TrackContextMenu: ViewModifier {
    let item: BaseItem
    @EnvironmentObject private var auth: AuthManager
    @EnvironmentObject private var pro: ProEntitlementStore
    @EnvironmentObject private var ignored: IgnoredTracksStore
    @State private var activeSheet: TrackMenuSheet?
    @State private var isFavorite = false

    // IMPORTANT: every menu entry is a plain Button. Nesting a sub-view that
    // carries its own `.sheet` (the old IgnoreToggleButton) inside a
    // `.contextMenu` collapsed the menu to just that item — that's the
    // "only the Pro-ignore option shows" bug. Sheets are hosted here, once,
    // via a single `.sheet(item:)`.
    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { AudioPlayer.shared.playNext(item) } label: { Label("Play Next", systemImage: "text.insert") }
                Button { AudioPlayer.shared.addToQueue(item) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
                Button { activeSheet = .playlist } label: { Label("Add to Playlist…", systemImage: "music.note.list") }
                Button { toggleFavorite() } label: {
                    Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.fill" : "heart")
                }
                downloadButton
                ignoreButton
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .playlist:
                    AddToPlaylistSheet(item: item).presentationDetents([.medium, .large])
                case .paywall:
                    NavigationStack { PaywallView() }.environmentObject(pro)
                }
            }
            .onAppear { isFavorite = item.UserData?.IsFavorite ?? false }
    }

    @ViewBuilder
    private var ignoreButton: some View {
        if pro.isPro {
            if ignored.isIgnored(item.Id) {
                Button { ignored.unignore(item.Id) } label: { Label("Stop Ignoring", systemImage: "arrow.uturn.backward") }
            } else {
                Button(role: .destructive) { ignored.ignore(item) } label: { Label("Ignore Track", systemImage: "hand.raised.slash") }
            }
        } else {
            Button { activeSheet = .paywall } label: { Label("Ignore Track (Pro)", systemImage: "lock.fill") }
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if DownloadManager.shared.isDownloaded(item.Id) {
            Button(role: .destructive) { DownloadManager.shared.delete(item.Id) } label: {
                Label("Remove Download", systemImage: "trash")
            }
        } else {
            Button {
                guard let url = auth.serverURL else { return }
                DownloadManager.shared.download(item, using: JellyfinClient(baseURL: url, auth: auth), individual: true)
            } label: { Label("Download", systemImage: "arrow.down.circle") }
        }
    }

    private func toggleFavorite() {
        guard let url = auth.serverURL else { return }
        isFavorite.toggle()
        let fav = isFavorite
        Task { try? await JellyfinClient(baseURL: url, auth: auth).setFavorite(item.Id, favorite: fav) }
    }
}

private enum TrackMenuSheet: Int, Identifiable {
    case playlist, paywall
    var id: Int { rawValue }
}

extension View {
    /// Attach the full track long-press menu.
    func trackContextMenu(_ item: BaseItem) -> some View { modifier(TrackContextMenu(item: item)) }
}

/// Context-menu entry for ignoring/unignoring a single track.
/// Free users see the entry as a paywall prompt.
struct IgnoreToggleButton: View {
    let item: BaseItem
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore
    @State private var showPaywall = false

    var body: some View {
        if pro.isPro {
            if ignored.isIgnored(item.Id) {
                Button {
                    ignored.unignore(item.Id)
                } label: {
                    Label("Stop Ignoring", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    ignored.ignore(item)
                } label: {
                    Label("Ignore Track", systemImage: "hand.raised.slash")
                }
            }
        } else {
            Button {
                showPaywall = true
            } label: {
                Label("Ignore Track (Pro)", systemImage: "lock.fill")
            }
            .sheet(isPresented: $showPaywall) {
                NavigationStack { PaywallView() }
                    .environmentObject(pro)
            }
        }
    }
}

/// Context-menu entry for ignoring/unignoring a whole artist. Anything by an
/// ignored artist is dropped from mixes, radio, and AI playlists.
struct IgnoreArtistToggleButton: View {
    let item: BaseItem
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore
    @State private var showPaywall = false

    var body: some View {
        if pro.isPro {
            if ignored.isArtistIgnored(item.Id) {
                Button {
                    ignored.unignoreArtist(item.Id)
                } label: {
                    Label("Stop Ignoring Artist", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    ignored.ignoreArtist(item)
                } label: {
                    Label("Ignore Artist", systemImage: "person.slash")
                }
            }
        } else {
            Button {
                showPaywall = true
            } label: {
                Label("Ignore Artist (Pro)", systemImage: "lock.fill")
            }
            .sheet(isPresented: $showPaywall) {
                NavigationStack { PaywallView() }
                    .environmentObject(pro)
            }
        }
    }
}

/// Context-menu entry for ignoring/unignoring a whole album. Every track on an
/// ignored album is dropped from mixes, radio, and AI playlists.
struct IgnoreAlbumToggleButton: View {
    let item: BaseItem
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore
    @State private var showPaywall = false

    var body: some View {
        if pro.isPro {
            if ignored.isAlbumIgnored(item.Id) {
                Button {
                    ignored.unignoreAlbum(item.Id)
                } label: {
                    Label("Stop Ignoring Album", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button(role: .destructive) {
                    ignored.ignoreAlbum(item)
                } label: {
                    Label("Ignore Album", systemImage: "square.stack.3d.up.slash")
                }
            }
        } else {
            Button {
                showPaywall = true
            } label: {
                Label("Ignore Album (Pro)", systemImage: "lock.fill")
            }
            .sheet(isPresented: $showPaywall) {
                NavigationStack { PaywallView() }
                    .environmentObject(pro)
            }
        }
    }
}

/// Swipe-action variant for List rows.
struct IgnoreSwipeButton: View {
    let item: BaseItem
    @EnvironmentObject var ignored: IgnoredTracksStore
    @EnvironmentObject var pro: ProEntitlementStore

    var body: some View {
        if pro.isPro {
            if ignored.isIgnored(item.Id) {
                Button {
                    ignored.unignore(item.Id)
                } label: {
                    Label("Unignore", systemImage: "arrow.uturn.backward")
                }
                .tint(.gray)
            } else {
                Button {
                    ignored.ignore(item)
                } label: {
                    Label("Ignore", systemImage: "hand.raised.slash")
                }
                .tint(.orange)
            }
        } else {
            EmptyView()
        }
    }
}
