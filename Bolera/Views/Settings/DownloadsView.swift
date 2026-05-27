import SwiftUI
import BoleraCore

struct DownloadsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    @EnvironmentObject var auth: AuthManager

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Downloaded Tracks")
                    Spacer()
                    Text("\(dm.completed.count)")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Storage Used")
                    Spacer()
                    Text(formattedSize(dm.totalBytesOnDisk()))
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    dm.deleteAll()
                } label: {
                    Text("Delete All Downloads")
                }
                .disabled(dm.completed.isEmpty)
            }

            if !dm.inProgress.isEmpty {
                Section("In Progress") {
                    ForEach(Array(dm.inProgress.keys), id: \.self) { id in
                        VStack(alignment: .leading) {
                            Text(dm.metadata[id]?.Name ?? id).lineLimit(1)
                            if let p = dm.inProgress[id] {
                                ProgressView(value: p.fraction)
                                Text("\(formattedSize(p.received)) / \(formattedSize(p.total))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { dm.cancel(id) } label: { Label("Cancel", systemImage: "xmark") }
                        }
                    }
                }
            }

            if !dm.completed.isEmpty {
                Section("Available Offline") {
                    ForEach(Array(dm.completed).sorted { (dm.metadata[$0]?.Name ?? "") < (dm.metadata[$1]?.Name ?? "") }, id: \.self) { id in
                        downloadRow(id: id)
                    }
                }
            }
        }
        .navigationTitle("Downloads")
    }

    @ViewBuilder
    private func downloadRow(id: String) -> some View {
        let item = dm.metadata[id]
        HStack(spacing: 12) {
            JellyfinImage(itemId: item?.AlbumId ?? id, tag: item?.AlbumPrimaryImageTag, maxWidth: 120, cornerRadius: 6)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading) {
                Text(item?.Name ?? id).lineLimit(1)
                Text(item?.primaryArtistName ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let item = item {
                Button {
                    AudioPlayer.shared.play(items: [item])
                } label: {
                    Image(systemName: "play.circle").font(.title2)
                }
                .buttonStyle(.plain)
            }
        }
        .swipeActions {
            Button(role: .destructive) { dm.delete(id) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}
