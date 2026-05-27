import SwiftUI
import BoleraCore

struct MenuBarPlayer_Mac: View {
    @EnvironmentObject var player: AudioPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let current = player.current {
                Text(current.Name).font(.headline).lineLimit(1)
                Text(current.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Divider()
            } else {
                Text("Nothing Playing").foregroundStyle(.secondary)
                Divider()
            }
            HStack(spacing: 16) {
                Button { player.previous() } label: { Image(systemName: "backward.fill") }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { player.next() } label: { Image(systemName: "forward.fill") }
                Spacer()
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").foregroundStyle(player.shuffle ? Color.accentColor : Color.secondary)
                }
                Button { player.cycleRepeatMode() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                }
            }
            .buttonStyle(.borderless)
            Divider()
            Button("Open Bolera") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
    }
}
