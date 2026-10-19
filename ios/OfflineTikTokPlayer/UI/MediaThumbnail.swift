import SwiftUI
import PlayerCore

struct MediaThumbnail: View {
    let item: MediaRecord
    var backdrop: Color = Color(white: 0.10)
    @Environment(AppModel.self) private var app
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            backdrop
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: item.kind == .slideshow ? "photo.on.rectangle" : "music.note").foregroundStyle(.gray).font(.title2) }
        }
        .task(id: item.artwork?.sha256) {
            let loaded = await app.artwork.image(for: item)
            if !Task.isCancelled { image = loaded }
        }
        .accessibilityHidden(true)
    }
}
