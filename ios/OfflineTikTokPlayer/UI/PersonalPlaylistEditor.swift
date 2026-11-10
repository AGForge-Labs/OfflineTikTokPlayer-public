import SwiftUI

struct PersonalPlaylistEditor: View {
    let mediaID: String?
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editingName: Bool
    @State private var creating = false
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                if let mediaID {
                    Section("My playlists") {
                        if app.personal.playlists.isEmpty {
                            Text("Create a playlist to bookmark this video.").foregroundStyle(.secondary)
                        }
                        ForEach(app.personal.playlists) { playlist in
                            let contains = playlist.itemIDs.contains(mediaID)
                            Button {
                                do { try app.personal.toggleMembership(mediaID, in: playlist.id); errorMessage = nil }
                                catch { errorMessage = error.localizedDescription }
                            } label: {
                                HStack {
                                    Text(playlist.name).foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: contains ? "checkmark.circle.fill" : "circle")
                                }
                            }.accessibilityAddTraits(contains ? .isSelected : [])
                        }
                    }
                }
                Section {
                    if mediaID == nil || creating {
                        TextField("Playlist name", text: $name)
                            .focused($editingName)
                            .submitLabel(.done)
                            .onSubmit { create() }
                        Button("Create playlist", action: create)
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button("New playlist", systemImage: "plus") { creating = true }
                    }
                    if let errorMessage { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(mediaID == nil ? "New playlist" : "Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func create() {
        do {
            try app.personal.createPlaylist(named: name, adding: mediaID)
            if mediaID == nil { dismiss() }
            else {
                editingName = false
                creating = false
                name = ""
                errorMessage = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
