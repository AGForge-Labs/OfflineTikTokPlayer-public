import SwiftUI
import PlayerCore

struct LibraryView: View {
    @Binding var importing: Bool
    @Environment(AppModel.self) private var app
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var matches: [MediaRecord] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Button { play(shuffle: false) } label: { Label(selected.isEmpty ? "Play all" : "Play selected", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.borderedProminent)
                        Button { play(shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                    }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
                    if !selected.isEmpty { Text("\(selected.count) selected · shared videos play once").font(.caption).foregroundStyle(.secondary) }
                }
                Section {
                    Button { app.playback.setAudioOnly(!app.playback.isAudioOnly) } label: {
                        HStack {
                            Label("Audio only", systemImage: "headphones")
                            Spacer()
                            Text(app.playback.isAudioOnly ? "On" : "Off").foregroundStyle(app.playback.isAudioOnly ? Color.cyan : Color.gray)
                        }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).foregroundStyle(.primary)
                    .accessibilityIdentifier("library.audioOnly")
                } footer: {
                    Text("Listen in the background without the floating video. Turn off to watch again.")
                }
                if query.isEmpty {
                    Section("Your playlists") {
                        if app.library.catalog.playlists.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Bring your music with you").font(.headline)
                                Text("Connect your private library in Settings, or add videos from Files to try the player.").font(.subheadline).foregroundStyle(.secondary)
                                Button("Add local videos") { importing = true }.buttonStyle(.bordered)
                            }.padding(.vertical, 8)
                        }
                        ForEach(app.library.catalog.playlists) { playlist in
                            HStack(spacing: 12) {
                                Button {
                                    if selected.contains(playlist.id) { selected.remove(playlist.id) } else { selected.insert(playlist.id) }
                                } label: {
                                    Image(systemName: selected.contains(playlist.id) ? "checkmark.circle.fill" : "circle").font(.title2).frame(width: 40, height: 44)
                                }.buttonStyle(.borderless).accessibilityLabel("Select \(playlist.name)")
                                NavigationLink(value: playlist.id) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(playlist.name).font(.headline).lineLimit(2)
                                        Text("\(playlist.itemIDs.count.formatted()) videos").font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 8)
                                }
                            }
                        }
                    }
                } else {
                    Section("\(matches.count.formatted()) results") {
                        ForEach(matches) { item in MediaRow(item: item, playlistIDs: []) }
                    }
                }
                if let status = app.library.refreshStatus { Section { Label(status, systemImage: "arrow.triangle.2.circlepath").font(.footnote) } }
                if let message = app.library.message { Section { Text(message).foregroundStyle(.secondary).font(.footnote) } }
            }
            .navigationTitle("Library")
            .searchable(text: $query, prompt: "Title or creator")
            .onChange(of: query) { _, _ in updateMatches() }
            .onChange(of: app.library.catalog.updatedAt) { _, _ in updateMatches() }
            .refreshable { await app.library.refresh(checkTikTok: true) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { importing = true } label: { Image(systemName: "plus") }.accessibilityLabel("Import videos or catalog") }
                ToolbarItem(placement: .topBarTrailing) { Button { app.sheet = .settings } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") }
            }
            .navigationDestination(for: String.self) { id in
                if let playlist = app.library.catalog.playlists.first(where: { $0.id == id }) { PlaylistView(playlist: playlist) }
            }
        }
    }

    private func updateMatches() { matches = app.library.catalog.search(query) }
    private func play(shuffle: Bool) {
        app.playback.start(playlistIDs: app.library.catalog.playlists.filter { selected.contains($0.id) }.map(\.id), shuffle: shuffle)
        if app.playback.current != nil, !app.playback.isAudioOnly { app.tab = .player }
    }
}

private struct PlaylistView: View {
    let playlist: PlaylistRecord
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var matches: [MediaRecord] = []

    var body: some View {
        List {
            Section {
                HStack {
                    Button { play(shuffle: false) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                    Button { play(shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                }.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                Button {
                    app.downloads.enqueue(playlist.itemIDs.compactMap { app.library.catalog.mediaByID[$0] })
                    if let message = app.downloads.message { app.alert = message }
                } label: {
                    Label("Save playlist offline · \(estimate)", systemImage: "arrow.down.circle")
                }
                Text("\(playlist.itemIDs.count.formatted()) entries · \(availableCount.formatted()) available")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(matches) { item in MediaRow(item: item, playlistIDs: [playlist.id]) }
        }
        .navigationTitle(playlist.name).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search this playlist")
        .onAppear { updateMatches() }
        .onChange(of: query) { _, _ in updateMatches() }
        .onChange(of: app.library.catalog.updatedAt) { _, _ in updateMatches() }
    }
    private var availableCount: Int { app.library.catalog.queue(playlistIDs: [playlist.id], localIDs: app.downloads.readyIDs).count }
    private var estimate: String {
        let assets = playlist.itemIDs.compactMap { app.library.catalog.mediaByID[$0]?.asset }
        let bytes = DownloadRecord.estimatedBytes(assets, verifiedHashes: Set(app.downloads.records.values.filter(\.isReady).map(\.asset.sha256)))
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func updateMatches() { matches = app.library.catalog.search(query, within: playlist.itemIDs) }
    private func play(shuffle: Bool) { app.playback.start(playlistIDs: [playlist.id], shuffle: shuffle); if app.playback.current != nil, !app.playback.isAudioOnly { app.tab = .player } }
}

struct MediaRow: View {
    let item: MediaRecord
    let playlistIDs: [String]
    @Environment(AppModel.self) private var app
    private var saved: Bool { app.downloads.records[item.id]?.isReady == true }
    private var playable: Bool { saved || (item.status == .ready && item.asset != nil) }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard playable else { app.alert = "This post does not have an archived video yet. Its place in your playlist is preserved."; return }
                app.playback.start(playlistIDs: playlistIDs, at: item.id, shuffle: app.playback.queue.isShuffled)
                if !app.playback.isAudioOnly { app.tab = .player }
            } label: {
                HStack(spacing: 12) {
                    MediaThumbnail(item: item).frame(width: 55, height: 72).clipShape(.rect(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(playable ? .primary : .secondary)
                        Text(item.creator).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if !playable { Text(item.status == .unavailable ? "Unavailable" : "Not archived yet").font(.caption2).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.buttonStyle(.plain)
            if saved { Image(systemName: "checkmark.circle.fill").foregroundStyle(.cyan).accessibilityLabel("Saved offline") }
            else if let transfer = app.downloads.records[item.id], [.queued, .resolving, .downloading, .verifying].contains(transfer.state) {
                ProgressView(value: transfer.progress).frame(width: 30).accessibilityLabel("Downloading \(Int(transfer.progress * 100)) percent")
            }
        }
        .contextMenu {
            if saved { Button("Remove offline copy", systemImage: "trash", role: .destructive) { app.downloads.remove(item.id) } }
            else if item.asset != nil { Button("Save offline", systemImage: "arrow.down.circle") { app.downloads.enqueue([item]); if let message = app.downloads.message { app.alert = message } } }
        }
    }
}
