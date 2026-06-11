import SwiftUI
import BoleraCore

struct QueueView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var showSaveSheet = false
    // Mirror only queue + currentIndex locally. Observing AudioPlayer directly
    // re-rendered this view every ~0.5s as currentTime ticked, which made the
    // open toolbar menu's text visibly pulse while music played.
    @State private var queue: [BaseItem] = []
    @State private var currentIndex = 0

    private var player: AudioPlayer { AudioPlayer.shared }

    // Only the currently-playing track and everything after it. Already-played
    // tracks stay in the underlying queue (so `previous()` works) but are hidden
    // from the queue list. `index` is the absolute position in `player.queue`,
    // which the AudioPlayer index ops (jumpTo/move/remove) all expect.
    private var upcoming: [(index: Int, item: BaseItem)] {
        guard currentIndex < queue.count else { return [] }
        return queue[currentIndex...].enumerated().map { (currentIndex + $0.offset, $0.element) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Up Next") {
                    ForEach(upcoming, id: \.item.id) { idx, item in
                        HStack(spacing: 12) {
                            JellyfinImage(itemId: item.AlbumId ?? item.Id, tag: item.AlbumPrimaryImageTag, maxWidth: 120, cornerRadius: 6)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading) {
                                Text(item.Name).lineLimit(1)
                                Text(item.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if idx == currentIndex {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { player.jumpTo(index: idx) }
                        .trackContextMenu(item)
                        .swipeActions(edge: .leading) {
                            IgnoreSwipeButton(item: item)
                        }
                    }
                    // onMove/onDelete report offsets relative to the rendered
                    // (sliced) rows — shift them back into absolute queue indices.
                    .onMove { src, dst in
                        player.move(from: IndexSet(src.map { $0 + currentIndex }), to: dst + currentIndex)
                    }
                    .onDelete { idx in
                        player.remove(at: IndexSet(idx.map { $0 + currentIndex }))
                    }
                }
            }
            .navigationTitle("Queue")
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.editMode, $editMode)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showSaveSheet = true
                        } label: {
                            Label("Save as Playlist…", systemImage: "square.and.arrow.down")
                        }
                        .disabled(queue.isEmpty)
                        EditButton()
                        Divider()
                        Button(role: .destructive) {
                            player.clearQueue()
                            dismiss()
                        } label: {
                            Label("Clear Queue", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showSaveSheet) {
                SavePlayQueueSheet()
                    .presentationDetents([.medium])
            }
        }
        .onReceive(player.$queue) { queue = $0 }
        .onReceive(player.$currentIndex) { currentIndex = $0 }
    }
}
