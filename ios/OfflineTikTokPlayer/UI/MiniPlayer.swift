import SwiftUI

struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if let item = app.playback.current {
            HStack(spacing: 12) {
                Button { app.playback.setAudioOnly(false); app.tab = .player } label: {
                    HStack {
                        MediaThumbnail(item: item).frame(width: 45, height: 48).clipShape(.rect(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(1)
                            Text(item.creator).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityLabel("Open current video")
                Button { app.playback.toggle() } label: {
                    Image(systemName: app.playback.wantsToPlay ? "pause.fill" : "play.fill").frame(width: 44, height: 44)
                }.accessibilityLabel(app.playback.wantsToPlay ? "Pause" : "Play")
                Button { app.playback.next() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("Next video")
            }.padding(.horizontal, 12).padding(.vertical, 7).foregroundStyle(.white).background(Color(white: 0.10))
        }
    }
}
