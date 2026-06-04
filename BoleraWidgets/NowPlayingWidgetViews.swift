import WidgetKit
import SwiftUI
import AppIntents
import BoleraCore

/// Routes each widget family to its own layout. Visual language mirrors the
/// in-app mini player (`MiniPlayerView`): artwork, 1-line title, secondary
/// 1-line artist, SF-symbol transport controls.
struct NowPlayingWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        switch family {
        case .systemSmall:  SmallNowPlayingView(entry: entry)
        case .systemMedium: MediumNowPlayingView(entry: entry)
        default:            MediumNowPlayingView(entry: entry)
        }
    }
}

/// Container background. Home families get the (blurred) artwork behind a dark
/// scrim so overlaid text stays legible; accessory families stay clear and let
/// the system render their vibrant/tinted treatment.
struct NowPlayingWidgetBackground: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        switch family {
        case .systemSmall, .systemMedium:
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.13, blue: 0.24),
                                        Color(red: 0.08, green: 0.08, blue: 0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let art = entry.artwork {
                    art.resizable().scaledToFill().blur(radius: 24).opacity(0.55)
                    LinearGradient(colors: [.black.opacity(0.10), .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        default:
            Color.clear
        }
    }
}

// MARK: - Home screen

private struct SmallNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        let snap = entry.snapshot
        VStack(alignment: .leading, spacing: 0) {
            Artwork(entry: entry, corner: 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 6)
            if snap.hasTrack {
                Text(snap.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(snap.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 14) {
                    TransportButton(system: snap.isPlaying ? "pause.fill" : "play.fill",
                                    intent: PlayPauseIntent(), font: .title3)
                    TransportButton(system: "forward.fill", intent: NextTrackIntent(), font: .body)
                }
            } else {
                EmptyStateLabel()
                Spacer(minLength: 0)
                TransportButton(system: "play.fill", intent: PlayPauseIntent(), font: .title3)
            }
        }
        .foregroundStyle(.white)
    }
}

private struct MediumNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        let snap = entry.snapshot
        HStack(spacing: 14) {
            Artwork(entry: entry, corner: 10)
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                if snap.hasTrack {
                    Text(snap.title).font(.headline).lineLimit(1)
                    Text(snap.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    ProgressBar(snapshot: snap).frame(height: 4).padding(.top, 2)
                    HStack(spacing: 26) {
                        TransportButton(system: "backward.fill", intent: PreviousTrackIntent(), font: .title3)
                        TransportButton(system: snap.isPlaying ? "pause.fill" : "play.fill",
                                        intent: PlayPauseIntent(), font: .title)
                        TransportButton(system: "forward.fill", intent: NextTrackIntent(), font: .title3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
                } else {
                    EmptyStateLabel()
                    Spacer(minLength: 0)
                    TransportButton(system: "play.fill", intent: PlayPauseIntent(), font: .title)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

// MARK: - Shared pieces

/// A transport control button bound to an interactive AppIntent.
private struct TransportButton<I: AppIntent>: View {
    let system: String
    let intent: I
    var font: Font = .title3

    var body: some View {
        Button(intent: intent) {
            Image(systemName: system).font(font)
        }
        .buttonStyle(.plain)
    }
}

/// Crisp foreground artwork, or a branded placeholder when there's no cover.
private struct Artwork: View {
    let entry: NowPlayingEntry
    var corner: CGFloat = 8

    var body: some View {
        ZStack {
            if let art = entry.artwork {
                art.resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: corner)
                    .fill(.white.opacity(0.12))
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: corner))
    }
}

/// Linear progress; uses a wall-clock timer interval while playing so the bar
/// advances smoothly between timeline reloads, falling back to a static value
/// when paused.
private struct ProgressBar: View {
    let snapshot: NowPlayingSnapshot

    var body: some View {
        Group {
            if let interval = snapshot.playbackInterval {
                ProgressView(timerInterval: interval, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .labelsHidden()
            } else {
                ProgressView(value: snapshot.progress())
            }
        }
        .tint(.white)
    }
}

private struct EmptyStateLabel: View {
    var body: some View {
        Text("Nothing playing")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }
}
