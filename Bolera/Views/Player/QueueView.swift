import SwiftUI
import BoleraCore

struct QueueView: View {
    @EnvironmentObject var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var editMode: EditMode = .inactive
    @State private var showSaveSheet = false

    var body: some View {
        NavigationStack {
            List {
                Section("Up Next") {
                    ForEach(Array(player.queue.enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 12) {
                            JellyfinImage(itemId: item.AlbumId ?? item.Id, tag: item.AlbumPrimaryImageTag, maxWidth: 120, cornerRadius: 6)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading) {
                                Text(item.Name).lineLimit(1)
                                Text(item.primaryArtistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if idx == player.currentIndex {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { player.jumpTo(index: idx) }
                        .swipeActions(edge: .leading) {
                            IgnoreSwipeButton(item: item)
                        }
                    }
                    .onMove { src, dst in player.move(from: src, to: dst) }
                    .onDelete { idx in player.remove(at: idx) }
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
                        .disabled(player.queue.isEmpty)
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
    }
}
