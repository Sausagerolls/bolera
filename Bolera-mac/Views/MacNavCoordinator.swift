import SwiftUI
import BoleraCore

/// Single source of truth for which content pane is shown in the Mac window.
/// Lives at app root so any view (tiles, sidebar pins, immersive player) can
/// drive sidebar selection / push detail pages.
@MainActor
final class MacNavCoordinator: ObservableObject {
    @Published var selection: SidebarSelection? = .home
    /// When a home favourites rail header opens the Favourites page, the tab it
    /// should land on ("Tracks"/"Albums"/"Artists"). Consumed once on appear.
    @Published var pendingFavoritesMode: String?
    private var history: [SidebarSelection] = []

    var canGoBack: Bool { !history.isEmpty }

    func openAlbum(_ item: BaseItem) {
        pushCurrent()
        selection = .albumDetail(item)
    }

    func openArtist(_ item: BaseItem) {
        pushCurrent()
        selection = .artistDetail(item)
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
        if let prev = history.popLast() {
            selection = prev
        } else {
            selection = .home
        }
    }

    /// Called when a top-level sidebar item is picked — clears history so
    /// the new branch starts fresh.
    func clearHistory() {
        history.removeAll()
    }

    private func pushCurrent() {
        if let current = selection {
            history.append(current)
        }
    }
}
