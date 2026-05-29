import SwiftUI
import BoleraCore

/// Manage the three "Do not auto-play" lists: ignored tracks, artists,
/// and albums. Anything in any of these lists is silently skipped by the
/// daily-mix and AI-playlist generators.
struct IgnoredTracksView: View {
    @EnvironmentObject var ignored: IgnoredTracksStore
    @State private var tab: Kind = .tracks

    enum Kind: String, CaseIterable, Identifiable {
        case tracks  = "Tracks"
        case artists = "Artists"
        case albums  = "Albums"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)

            List {
                switch tab {
                case .tracks:
                    section(ids: ignored.ignored,
                            emptyTitle: "No ignored tracks",
                            emptyHint: "Long-press a track and tap \"Ignore\" to silently skip it everywhere.",
                            icon: "music.note.list") { ignored.unignore($0) }
                case .artists:
                    section(ids: ignored.ignoredArtists,
                            emptyTitle: "No ignored artists",
                            emptyHint: "Long-press an artist and tap \"Ignore Artist\" to silently skip their music.",
                            icon: "music.mic") { ignored.unignoreArtist($0) }
                case .albums:
                    section(ids: ignored.ignoredAlbums,
                            emptyTitle: "No ignored albums",
                            emptyHint: "Long-press an album and tap \"Ignore Album\" to silently skip every track on it.",
                            icon: "square.stack") { ignored.unignoreAlbum($0) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Ignored")
    }

    @ViewBuilder
    private func section(ids: Set<String>,
                         emptyTitle: String,
                         emptyHint: String,
                         icon: String,
                         remove: @escaping (String) -> Void) -> some View {
        if ids.isEmpty {
            ContentUnavailableView(emptyTitle,
                                   systemImage: "hand.raised.slash",
                                   description: Text(emptyHint))
        } else {
            ForEach(Array(ids).sorted(by: sortBy), id: \.self) { id in
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                    Text(ignored.labels[id] ?? id)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .swipeActions {
                    Button(role: .destructive) {
                        remove(id)
                    } label: {
                        Label("Unignore", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        }
    }

    private func sortBy(_ a: String, _ b: String) -> Bool {
        let la = ignored.labels[a] ?? a
        let lb = ignored.labels[b] ?? b
        return la.localizedCaseInsensitiveCompare(lb) == .orderedAscending
    }
}
