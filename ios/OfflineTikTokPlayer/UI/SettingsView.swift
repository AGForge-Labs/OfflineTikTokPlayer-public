import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var status: String?
    @State private var diagnosticsURL: URL?

    var body: some View {
        @Bindable var account = app.account
        @Bindable var downloads = app.downloads
        @Bindable var playback = app.playback
        NavigationStack {
            Form {
                Section("Private OneDrive library") {
                    DisclosureGroup("Advanced connection") {
                        TextField("Microsoft application ID", text: $account.clientID)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.footnote.monospaced())
                    }
                    if let username = account.username { Label(username, systemImage: "person.crop.circle.badge.checkmark") }
                    Button {
                        connecting = true
                        Task {
                            defer { connecting = false }
                            do {
                                try await app.account.connect()
                                status = try await app.cloud.quota()
                                await app.library.refresh()
                            } catch { status = error.localizedDescription }
                        }
                    } label: {
                        HStack { Text("Connect Microsoft account"); if connecting { Spacer(); ProgressView() } }
                    }.disabled(connecting)
                    Button { Task { await app.library.refresh(checkTikTok: true) } } label: {
                        HStack {
                            Text("Refresh library")
                            if app.library.isRefreshing { Spacer(); ProgressView() }
                        }
                    }.disabled(app.library.isRefreshing)
                    Text("Refresh checks your watched TikTok playlists using your PC. Keep the Windows helper running and your PC awake.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let progress = app.library.refreshStatus { Text(progress).font(.footnote) }
                    if let message = app.library.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    Text("The app requests access to its own OneDrive folder. Your downloaded videos keep playing without signing in.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                }
                Section("Downloads") {
                    Toggle("Wi-Fi only", isOn: $downloads.wifiOnly)
                    Text("Removing a download only removes its iPhone copy. Your cloud original stays in your library.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Playback") {
                    Toggle("Speaker sound", isOn: $playback.speakerSound)
                    Text("Boosts quieter music and adds fuller bass through the iPhone speakers, with peak protection. Turn off for Original sound. Headphones and Bluetooth use the original audio. Your iPhone volume stays under your control.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Automatic Picture in Picture", isOn: $playback.automaticPiP)
                    Toggle("Audio only", isOn: $playback.audioOnly)
                    Text("Keeps the current audio position while video is hidden. Turn off to restore video. A camera or call can still interrupt audio when iOS requires it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Audio keeps playing when you lock your phone. Your queue and position return paused when you reopen the app.")
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("Playback diagnostics") {
                        Button("Prepare local report") { diagnosticsURL = playback.exportPlaybackDiagnostics() }
                        if let diagnosticsURL { ShareLink("Share playback report", item: diagnosticsURL) }
                        Text("Contains recent playback, PiP and audio-session events. No video names, links, account details or recordings are included.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("About") {
                    Text("Private offline player · iOS 26+")
                    Text("Your library refreshes when you open the app. Enable 15-minute checks in the Windows helper to import new additions while your PC is awake and the helper is running.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
