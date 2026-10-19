import SwiftUI
import PlayerCore

struct DownloadsView: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label(ByteCountFormatter.string(fromByteCount: app.downloads.usedBytes, countStyle: .file), systemImage: "internaldrive")
                        Spacer()
                        Text("on your iPhone").foregroundStyle(.secondary)
                    }.font(.subheadline)
                    Button { app.playback.start(playlistIDs: [], shuffle: true, offlineOnly: true); if app.playback.current != nil { app.tab = .player } } label: {
                        Label("Shuffle downloaded videos", systemImage: "shuffle")
                    }
                    if app.downloads.wifiOnly && !app.network.isWiFi { Text("Downloads wait for Wi-Fi. Saved videos can play now.").font(.caption).foregroundStyle(.secondary) }
                }
                if app.downloads.records.isEmpty {
                    ContentUnavailableView("No offline copies yet", systemImage: "arrow.down.circle", description: Text("Save a video or playlist from your library."))
                        .listRowBackground(Color.clear)
                }
                ForEach(app.downloads.orderedIDs, id: \.self) { id in
                    if let record = app.downloads.records[id] {
                    VStack(alignment: .leading, spacing: 8) {
                        if let item = app.library.catalog.mediaByID[record.mediaID] {
                            MediaRow(item: item, playlistIDs: [])
                        } else { Text(record.mediaID).font(.subheadline) }
                        if !record.isReady {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.error ?? record.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                                    ProgressView(value: record.progress)
                                }
                                if [.downloading, .resolving, .queued].contains(record.state) {
                                    Button("Pause") { app.downloads.pause(record.mediaID) }.buttonStyle(.borderless)
                                } else if record.state != .verifying {
                                    Button("Resume") { app.downloads.resume(record.mediaID) }.buttonStyle(.borderless)
                                }
                            }
                        }
                    }.padding(.vertical, 4)
                    .swipeActions { Button("Remove", role: .destructive) { app.downloads.remove(record.mediaID) } }
                    }
                }
                if let message = app.downloads.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle("Downloads")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { app.sheet = .settings } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") } }
        }
    }
}
