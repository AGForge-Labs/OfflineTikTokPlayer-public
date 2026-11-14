import SwiftUI
import PlayerCore

private enum LibraryDestination: Hashable {
    case imported(String)
    case history
    case liked
    case personal(String)

    var importedID: String? {
        if case .imported(let id) = self { return id }
        return nil
    }
}

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
                    Section("Your activity") {
                        personalLink(.history, title: "History", icon: "clock.arrow.circlepath", count: app.personal.history.count)
                        personalLink(.liked, title: "Liked", icon: "heart.fill", count: app.personal.liked.count)
                    }
                    Section("My playlists") {
                        ForEach(app.personal.playlists) { playlist in
                            personalLink(.personal(playlist.id), title: playlist.name, icon: "bookmark", count: playlist.itemIDs.count)
                        }
                        Button("New playlist", systemImage: "plus") { app.sheet = .newPlaylist }
                    }
                    Section("Imported from TikTok") {
                        let imported = app.library.catalog.playlists.filter { !$0.id.hasPrefix("local:") }
                        if imported.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("No TikTok playlists yet").font(.headline)
                                Text("Connect your private library in Settings, or add videos from Files to try the player.")
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Button("Add local videos") { importing = true }.buttonStyle(.bordered)
                            }.padding(.vertical, 8)
                        }
                        ForEach(imported) { importedRow($0) }
                    }
                    let files = app.library.catalog.playlists.filter { $0.id.hasPrefix("local:") }
                    if !files.isEmpty {
                        Section("Imported from Files") {
                            ForEach(files) { importedRow($0) }
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
            .navigationDestination(for: LibraryDestination.self) { PlaylistView(destination: $0) }
        }
    }

    private func personalLink(_ destination: LibraryDestination, title: String, icon: String, count: Int) -> some View {
        NavigationLink(value: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(.cyan).frame(width: 24).accessibilityHidden(true)
                playlistLabel(title, count: count)
            }
        }
    }

    private func importedRow(_ playlist: PlaylistRecord) -> some View {
        HStack(spacing: 12) {
            Button {
                if selected.contains(playlist.id) { selected.remove(playlist.id) } else { selected.insert(playlist.id) }
            } label: {
                Image(systemName: selected.contains(playlist.id) ? "checkmark.circle.fill" : "circle").font(.title2).frame(width: 40, height: 44)
            }.buttonStyle(.borderless).accessibilityLabel("Select \(playlist.name)")
            NavigationLink(value: LibraryDestination.imported(playlist.id)) {
                playlistLabel(playlist.name, count: playlist.itemIDs.count)
            }
        }
    }

    private func playlistLabel(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline).lineLimit(2)
            Text("\(count.formatted()) videos").font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }

    private func updateMatches() { matches = app.library.catalog.search(query) }
    private func play(shuffle: Bool) {
        app.playback.start(playlistIDs: app.library.catalog.playlists.filter { selected.contains($0.id) }.map(\.id), shuffle: shuffle)
        if app.playback.current != nil, !app.playback.isAudioOnly { app.tab = .player }
    }
}

private struct PlaylistView: View {
    let destination: LibraryDestination
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var matches: [MediaRecord] = []

    private var playlist: PlaylistRecord? {
        switch destination {
        case .imported(let id): return app.library.catalog.playlists.first { $0.id == id }
        case .personal(let id): return app.personal.playlists.first { $0.id == id }
        case .history: return PlaylistRecord(id: "history", name: "History", itemIDs: app.personal.history)
        case .liked: return PlaylistRecord(id: "liked", name: "Liked", itemIDs: app.personal.liked)
        }
    }

    var body: some View {
        if let playlist { detail(playlist) }
        else { ContentUnavailableView("Playlist unavailable", systemImage: "rectangle.stack") }
    }

    private func detail(_ playlist: PlaylistRecord) -> some View {
        let catalogIDs = destination.importedID.map { [$0] } ?? []
        let personalIDs = destination.importedID == nil ? playlist.itemIDs : nil
        let available = app.library.catalog.queue(playlistIDs: catalogIDs, localIDs: app.downloads.readyIDs,
            offlineOnly: !app.network.isConnected, within: personalIDs).count
        return List {
            Section {
                HStack {
                    Button { play(catalogIDs, within: personalIDs, shuffle: false) } label: { Label("Play", systemImage: "play.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
                    Button { play(catalogIDs, within: personalIDs, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                }.disabled(available == 0).listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                if destination.importedID != nil {
                    Button {
                        app.downloads.enqueue(playlist.itemIDs.compactMap { app.library.catalog.mediaByID[$0] })
                        if let message = app.downloads.message { app.alert = message }
                    } label: {
                        Label("Save playlist offline · \(estimate(playlist))", systemImage: "arrow.down.circle")
                    }
                }
                Text("\(playlist.itemIDs.count.formatted()) entries · \(available.formatted()) available")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if matches.isEmpty {
                Text(query.isEmpty ? emptyMessage : "No matching videos.").foregroundStyle(.secondary)
            }
            ForEach(matches) { item in MediaRow(item: item, playlistIDs: catalogIDs, itemIDs: personalIDs) }
        }
        .navigationTitle(playlist.name).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search this playlist")
        .onAppear { updateMatches(playlist) }
        .onChange(of: query) { _, _ in updateMatches(playlist) }
        .onChange(of: playlist.itemIDs) { _, _ in updateMatches(playlist) }
        .onChange(of: app.library.catalog.updatedAt) { _, _ in updateMatches(playlist) }
    }

    private var emptyMessage: String {
        switch destination {
        case .history: return "Videos you watch will appear here."
        case .liked: return "Tap the heart on a video to save it here."
        case .personal: return "Tap the bookmark on a video to add it to this playlist."
        case .imported: return "No videos in this playlist yet."
        }
    }

    private func estimate(_ playlist: PlaylistRecord) -> String {
        let assets = playlist.itemIDs.compactMap { app.library.catalog.mediaByID[$0]?.asset }
        let bytes = DownloadRecord.estimatedBytes(assets, verifiedHashes: Set(app.downloads.records.values.filter(\.isReady).map(\.asset.sha256)))
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func updateMatches(_ playlist: PlaylistRecord) { matches = app.library.catalog.search(query, within: playlist.itemIDs) }
    private func play(_ catalogIDs: [String], within personalIDs: [String]?, shuffle: Bool) {
        app.playback.start(playlistIDs: catalogIDs, shuffle: shuffle, within: personalIDs)
        if app.playback.current != nil, !app.playback.isAudioOnly { app.tab = .player }
    }
}

struct MediaRow: View {
    let item: MediaRecord
    let playlistIDs: [String]
    var itemIDs: [String]? = nil
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    private var saved: Bool { app.downloads.records[item.id]?.isReady == true }
    private var playable: Bool { saved || (item.status == .ready && item.asset != nil) }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                guard playable else { app.alert = "This post does not have an archived video yet. Its place in your playlist is preserved."; return }
                if itemIDs != nil, !saved, !app.network.isConnected { app.alert = "Connect to the internet to play this video."; return }
                app.playback.start(playlistIDs: playlistIDs, at: item.id, shuffle: app.playback.queue.isShuffled, within: itemIDs)
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
            if let url = item.tiktokPostURL {
                Button("Open in TikTok", systemImage: "arrow.up.right.square") { openURL(url) }
            }
            if saved { Button("Remove offline copy", systemImage: "trash", role: .destructive) { app.downloads.remove(item.id) } }
            else if item.asset != nil { Button("Save offline", systemImage: "arrow.down.circle") { app.downloads.enqueue([item]); if let message = app.downloads.message { app.alert = message } } }
        }
    }
}
