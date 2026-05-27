import SwiftUI
import BoleraCore

/// Single source of truth for which content pane is shown in the Mac window.
/// Lives at app root so any view (tiles, sidebar pins, immersive player) can
/// drive sidebar selection / push detail pages.
@MainActor
final class MacNavCoordinator: ObservableObject {
    @Published var selection: SidebarSelection? = .home
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
