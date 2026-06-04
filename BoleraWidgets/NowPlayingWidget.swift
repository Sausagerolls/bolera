import WidgetKit
import SwiftUI
import BoleraCore

/// One timeline entry: the snapshot the app last wrote, plus its decoded
/// artwork. Progress/elapsed are projected from the snapshot's anchor at
/// render time, so a single entry stays accurate as the clock advances.
struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    let artwork: Image?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: .empty, artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        // A single entry with `.never` reload policy: the app calls
        // `WidgetCenter.reloadAllTimelines()` whenever the track / play-pause
        // state changes, and the progress bar / time animate locally via
        // `ProgressView(timerInterval:)`, so we don't need WidgetKit to wake
        // the extension on a schedule (and burn its reload budget).
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> NowPlayingEntry {
        let snapshot = NowPlayingSharedStore.read()
        var artwork: Image?
        if let data = NowPlayingSharedStore.artworkData(relativePath: snapshot.artworkRelativePath) {
            #if canImport(UIKit)
            if let ui = UIImage(data: data) { artwork = Image(uiImage: ui) }
            #elseif canImport(AppKit)
            if let ns = NSImage(data: data) { artwork = Image(nsImage: ns) }
            #endif
        }
        return NowPlayingEntry(date: Date(), snapshot: snapshot, artwork: artwork)
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetKinds.nowPlaying, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    NowPlayingWidgetBackground(entry: entry)
                }
        }
        .configurationDisplayName("Now Playing")
        .description("See what's playing in Bolera and control playback.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
