import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var importing = false

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            Group {
                switch app.tab {
                case .player: FeedView()
                case .library: LibraryView(importing: $importing)
                case .downloads: DownloadsView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if app.tab != .player, app.playback.current != nil { MiniPlayer() }
            HStack {
                tab(.player, icon: "play.rectangle.fill")
                tab(.library, icon: "rectangle.stack.fill")
                tab(.downloads, icon: "arrow.down.circle.fill")
            }
            .padding(.top, 9).padding(.horizontal, 12).padding(.bottom, 3)
            .background(Color.black)
        }
        .background(.black)
        .sheet(item: $app.sheet) { destination in
            switch destination { case .settings: SettingsView() }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .json], allowsMultipleSelection: true) { result in
            Task { @MainActor in
                do {
                    for url in try result.get() {
                        if url.pathExtension.lowercased() == "json" { try app.library.importCatalog(url) }
                        else { try await app.library.importVideo(url, downloads: app.downloads) }
                    }
                    app.tab = .library
                } catch { app.alert = error.localizedDescription }
            }
        }
        .alert("Offline Player", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
            Button("OK", role: .cancel) { app.alert = nil }
        } message: { Text(app.alert ?? "") }
        .onChange(of: app.playback.message) { _, message in if let message { app.alert = message; app.playback.message = nil } }
    }

    private func tab(_ tab: AppTab, icon: String) -> some View {
        Button {
            if tab == .player { app.playback.setAudioOnly(false) }
            app.tab = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 21, weight: .semibold))
                Text(tab.rawValue).font(.caption2.weight(.semibold))
            }
            .foregroundStyle(app.tab == tab ? .white : .gray)
            .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).accessibilityIdentifier("tab.\(tab.rawValue.lowercased())")
    }
}
