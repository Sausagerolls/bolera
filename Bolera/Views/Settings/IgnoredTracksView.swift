import SwiftUI
import BoleraCore

struct IgnoredTracksView: View {
    @EnvironmentObject var ignored: IgnoredTracksStore

    var body: some View {
        List {
            if ignored.ignored.isEmpty {
                ContentUnavailableView("Nothing ignored",
                                       systemImage: "hand.raised.slash",
                                       description: Text("Long-press a track and tap \"Ignore\" to silently skip it everywhere."))
            } else {
                ForEach(Array(ignored.ignored).sorted(by: sortBy), id: \.self) { id in
                    HStack {
                        Image(systemName: "hand.raised.slash.fill")
                            .foregroundStyle(.secondary)
                        Text(ignored.labels[id] ?? id)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            ignored.unignore(id)
                        } label: {
                            Label("Unignore", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
        }
        .navigationTitle("Ignored Tracks")
    }

    private func sortBy(_ a: String, _ b: String) -> Bool {
        let la = ignored.labels[a] ?? a
        let lb = ignored.labels[b] ?? b
        return la.localizedCaseInsensitiveCompare(lb) == .orderedAscending
    }
}
