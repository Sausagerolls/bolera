import WidgetKit
import SwiftUI
import AppIntents
import BoleraCore

struct MixTile: Identifiable {
    let id: UUID
    let name: String
    let artwork: Image?
}

struct MixesEntry: TimelineEntry {
    let date: Date
    let mixes: [MixTile]
}

struct MixesProvider: TimelineProvider {
    func placeholder(in context: Context) -> MixesEntry {
        MixesEntry(date: Date(), mixes: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (MixesEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MixesEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> MixesEntry {
        let tiles = MixesSharedStore.read().prefix(4).map { mix in
            MixTile(
                id: mix.id,
                name: mix.name,
                artwork: widgetImage(from: MixesSharedStore.artworkData(id: mix.id))
            )
        }
        return MixesEntry(date: Date(), mixes: Array(tiles))
    }
}

struct MixesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.mixes, provider: MixesProvider()) { entry in
            MixesEntryView(entry: entry)
                .containerBackground(for: .widget) { widgetTileGradient }
        }
        .configurationDisplayName("Daily Mixes")
        .description("Start one of your daily mixes with a tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct MixesEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MixesEntry

    var body: some View {
        if entry.mixes.isEmpty {
            WidgetEmptyState(message: "No mixes yet")
        } else {
            switch family {
            case .systemSmall:
                tile(entry.mixes[0])
            case .systemLarge:
                VStack(alignment: .leading, spacing: 10) {
                    Text("Daily Mixes").font(.headline).foregroundStyle(.white)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                        ForEach(Array(entry.mixes.prefix(4))) { mix in tile(mix) }
                    }
                }
            default: // medium — two side by side
                HStack(spacing: 10) {
                    ForEach(Array(entry.mixes.prefix(2))) { mix in tile(mix) }
                }
            }
        }
    }

    // The mix artwork is a 3:2 mosaic with the playlist name already rendered
    // into it (the same image the in-app Daily Mixes row uses), so present it at
    // its native aspect with no extra overlay. The previous square crop + a
    // second title drawn on top was what made it look like a mash of images.
    private func tile(_ mix: MixTile) -> some View {
        Button(intent: PlayMixIntent(mixId: mix.id.uuidString)) {
            Color.clear
                .aspectRatio(3.0 / 2.0, contentMode: .fit)
                .overlay {
                    if let art = mix.artwork {
                        art.resizable().scaledToFill()
                    } else {
                        ZStack(alignment: .bottomLeading) {
                            LinearGradient(colors: [Color(red: 0.36, green: 0.26, blue: 0.60),
                                                    Color(red: 0.08, green: 0.08, blue: 0.12)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                            Text(mix.name).font(.caption.weight(.semibold))
                                .foregroundStyle(.white).lineLimit(2).padding(8)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
