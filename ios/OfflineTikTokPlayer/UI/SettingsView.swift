import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var connecting = false
    @State private var status: String?

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
                    Button("Refresh library") { Task { await app.library.refresh() } }.disabled(app.library.isRefreshing)
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
                    Text("Adds bass, clarity and controlled volume through the iPhone speakers. Turn off for Original sound. Headphones use the original audio.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Automatic Picture in Picture", isOn: $playback.automaticPiP)
                    Text("Audio keeps playing when you lock your phone. Your queue and position return paused when you reopen the app.")
                        .font(.caption).foregroundStyle(.secondary)
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
