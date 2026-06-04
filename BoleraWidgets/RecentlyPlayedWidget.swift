import WidgetKit
import SwiftUI
import AppIntents
import BoleraCore

struct RecentTrackTile: Identifiable {
    let id: String
    let title: String
    let artist: String
    let artwork: Image?
}

struct RecentlyPlayedEntry: TimelineEntry {
    let date: Date
    let tracks: [RecentTrackTile]
}

struct RecentlyPlayedProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecentlyPlayedEntry {
        RecentlyPlayedEntry(date: Date(), tracks: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (RecentlyPlayedEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecentlyPlayedEntry>) -> Void) {
        // The app pushes a reload (reloadTimelines(ofKind:)) whenever recents
        // change, so a single non-expiring entry is enough.
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> RecentlyPlayedEntry {
        let tiles = RecentTracksSharedStore.read().prefix(8).map { item in
            RecentTrackTile(
                id: item.Id,
                title: item.Name,
                artist: item.primaryArtistName,
                artwork: widgetImage(from: RecentTracksSharedStore.artworkData(id: item.Id))
            )
        }
        return RecentlyPlayedEntry(date: Date(), tracks: Array(tiles))
    }
}

struct RecentlyPlayedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.recentlyPlayed, provider: RecentlyPlayedProvider()) { entry in
            RecentlyPlayedEntryView(entry: entry)
                .containerBackground(for: .widget) { widgetTileGradient }
        }
        .configurationDisplayName("Recently Played")
        .description("Jump back into tracks you played recently.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct RecentlyPlayedEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: RecentlyPlayedEntry

    var body: some View {
        if entry.tracks.isEmpty {
            WidgetEmptyState(message: "No recent tracks")
        } else {
            switch family {
            case .systemSmall:
                grid(columns: 2, count: 4, showTitle: false)
            case .systemLarge:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recently Played").font(.headline).foregroundStyle(.white)
                    grid(columns: 4, count: 8, showTitle: true)
                }
            default: // medium
                grid(columns: 4, count: 4, showTitle: true)
            }
        }
    }

    private func grid(columns: Int, count: Int, showTitle: Bool) -> some View {
        let tiles = Array(entry.tracks.prefix(count))
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: columns)
        return LazyVGrid(columns: cols, spacing: 8) {
            ForEach(tiles) { tile in
                Button(intent: PlayRecentTrackIntent(trackId: tile.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        ArtworkSquare(image: tile.artwork)
                        if showTitle {
                            Text(tile.title)
                                .font(.caption2).lineLimit(1)
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
