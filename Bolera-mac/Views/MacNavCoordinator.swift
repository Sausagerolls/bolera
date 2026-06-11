import SwiftUI
import BoleraCore

/// Single source of truth for which content pane is shown in the Mac window.
/// Lives at app root so any view (tiles, sidebar pins, immersive player) can
/// drive sidebar selection / push detail pages.
@MainActor
final class MacNavCoordinator: ObservableObject {
    @Published var selection: SidebarSelection? = .home
    /// Drives the full-screen immersive player. Set from anywhere (sidebar art,
    /// mini-player) to open it; the immersive view clears it on close.
    @Published var showImmersive = false
    /// Collapses the window into the compact, blended Micro Player.
    @Published var microPlayer = false
    /// When a home favourites rail header opens the Favourites page, the tab it
    /// should land on ("Tracks"/"Albums"/"Artists"). Consumed once on appear.
    @Published var pendingFavoritesMode: String?
    private var history: [SidebarSelection] = []
    private var forwardStack: [SidebarSelection] = []

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func openAlbum(_ item: BaseItem) {
        pushCurrent()
        selection = .albumDetail(item)
    }

    func openArtist(_ item: BaseItem) {
        pushCurrent()
        selection = .artistDetail(item)
    }

    func openPlaylist(_ item: BaseItem) {
        pushCurrent()
        selection = .playlistDetail(item)
    }

    /// Drill into a home rail's full-list page (Recent/Top/Recently Added).
    func openHomeSection(_ section: MacHomeSection) {
        pushCurrent()
        selection = .homeSection(section)
    }

    /// Open the Favourites page, optionally pre-selecting a tab.
    func openFavorites(mode: String?) {
        pushCurrent()
        pendingFavoritesMode = mode
        selection = .favorites
    }

    func goBack() {
        guard let prev = history.popLast() else { return }
        if let current = selection { forwardStack.append(current) }
        selection = prev
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current = selection { history.append(current) }
        selection = next
    }

    /// Called when a top-level sidebar item is picked — clears history so
    /// the new branch starts fresh.
    func clearHistory() {
        history.removeAll()
        forwardStack.removeAll()
    }

    private func pushCurrent() {
        if let current = selection {
            history.append(current)
        }
        // A fresh forward navigation invalidates any forward stack.
        forwardStack.removeAll()
    }
}
