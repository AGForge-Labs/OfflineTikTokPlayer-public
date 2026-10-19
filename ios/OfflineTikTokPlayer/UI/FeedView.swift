import SwiftUI
import PlayerCore

struct FeedView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.playback.current == nil {
                ContentUnavailableView {
                    Label("Your music. Your order.", systemImage: "play.rectangle.on.rectangle")
                } description: {
                    Text("Choose a playlist in Library, then play or shuffle. Swipe up for the next video and down to go back.")
                } actions: {
                    Button("Open Library") { app.tab = .library }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                FeedPager(window: app.playback.queue.feedWindow,
                          didSettle: { window, landedID in
                              let direction = window.settledDirection(at: landedID, currentWindow: app.playback.queue.feedWindow)
                              app.playback.feedDidSettle(direction: direction)
                              return app.playback.queue.feedWindow
                          },
                          interactionChanged: { app.playback.isInteractingWithFeed = $0 }) { page in
                    if let item = app.library.catalog.mediaByID[page.mediaID] {
                        FeedPage(item: item, isActive: page == app.playback.queue.feedWindow.current)
                    }
                }
            }
        }
        .background(.black)
        .onDisappear { app.playback.isInteractingWithFeed = false }
    }

}

private struct FeedPage: View {
    let item: MediaRecord
    let isActive: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        ZStack {
            // Keep image state and UIKit host identity through forward/backward handoffs.
            FeedVideoSurface(surface: app.playback.surface, isActive: isActive, isReady: app.playback.isVideoReady) {
                MediaThumbnail(item: item, backdrop: .black)
            }
            Color.clear.contentShape(Rectangle()).onTapGesture { if isActive { app.playback.toggle() } }
            LinearGradient(colors: [.black.opacity(0.5), .clear, .clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
            if isActive, app.playback.isLoading { ProgressView().tint(.white).scaleEffect(1.3).allowsHitTesting(false) }
            else if isActive, !app.playback.wantsToPlay {
                Image(systemName: "play.fill").font(.system(size: 66)).foregroundStyle(.white.opacity(0.75)).allowsHitTesting(false)
            }
            VStack {
                HStack {
                    Button { app.tab = .library } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                        .accessibilityLabel("Open library")
                    Spacer()
                    Text("Your playlists").font(.headline)
                    Spacer()
                    Button { app.sheet = .settings } label: { Image(systemName: "gearshape").frame(width: 44, height: 44) }
                        .accessibilityLabel("Settings")
                }
                Spacer()
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        if !item.creator.isEmpty { Text("@" + item.creator.trimmingCharacters(in: CharacterSet(charactersIn: "@"))).font(.headline) }
                        Text(item.title).font(.subheadline).lineLimit(4)
                        HStack(spacing: 6) {
                            Image(systemName: isActive && app.playback.hasAudioTrack == false ? "speaker.slash" : "music.note")
                            Text(isActive && app.playback.hasAudioTrack == false ? "No audio in this archived post" :
                                (app.downloads.readyIDs.contains(item.id) ? "Saved on your iPhone" : "From your private library"))
                        }.font(.caption).foregroundStyle(.white.opacity(0.85))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 18) {
                        action("Shuffle", icon: "shuffle", active: app.playback.queue.isShuffled) { app.playback.setShuffle(!app.playback.queue.isShuffled) }
                        action(repeatLabel, icon: app.playback.queue.repeatMode == .one ? "repeat.1" : "repeat", active: app.playback.queue.repeatMode != .off) { app.playback.cycleRepeat() }
                        action(app.downloads.readyIDs.contains(item.id) ? "Saved" : "Save", icon: app.downloads.readyIDs.contains(item.id) ? "checkmark.circle.fill" : "arrow.down.circle") {
                            app.downloads.enqueue([item])
                            if let message = app.downloads.message { app.alert = message }
                        }
                        action("PiP", icon: "pip.enter") { app.playback.startPiP() }
                    }.disabled(!isActive)
                }.padding(.horizontal, 18).padding(.bottom, 12)
                if isActive { SeekBar(playback: app.playback, mediaID: item.id).id(item.id).padding(.horizontal, 12).padding(.bottom, 6) }
            }
        }.foregroundStyle(.white)
    }

    private var repeatLabel: String {
        switch app.playback.queue.repeatMode { case .off: return "Loop off"; case .all: return "Loop all"; case .one: return "Loop one" }
    }
    private func action(_ label: String, icon: String, active: Bool = false, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 27, weight: .semibold)).frame(width: 44, height: 36)
                Text(label).font(.caption2.weight(.semibold))
            }.foregroundStyle(active ? .cyan : .white).shadow(color: .black.opacity(0.7), radius: 3)
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(active ? .isSelected : [])
    }
}

struct SeekBar: View {
    let playback: PlaybackService
    let mediaID: String
    @State private var scrub = PlaybackScrub()
    private var displayedPosition: Double { min(max(0, scrub.position ?? playback.clock.position), max(1, playback.clock.duration)) }
    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(get: { displayedPosition }, set: { scrub.update($0, mediaID: mediaID) }),
                   in: 0...max(1, playback.clock.duration)) { editing in
                if editing { scrub.begin(mediaID: mediaID, position: playback.clock.position) }
                else if let value = scrub.finish(mediaID: playback.queue.currentID ?? ""), playback.queue.currentID == mediaID {
                    playback.seek(value)
                }
            }.tint(.white).disabled(playback.isLoading || playback.clock.duration <= 0).accessibilityLabel("Playback position")
                .accessibilityAdjustableAction { direction in
                    guard playback.queue.currentID == mediaID else { return }
                    switch direction {
                    case .increment: playback.seek(playback.clock.position + 5)
                    case .decrement: playback.seek(playback.clock.position - 5)
                    @unknown default: break
                    }
                }
            HStack {
                Text(time(displayedPosition))
                Spacer()
                Text(time(playback.clock.duration))
            }.font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
        }
        .onChange(of: playback.isLoading) { _, loading in if loading { scrub = PlaybackScrub() } }
        .onChange(of: playback.queue.currentID) { _, _ in scrub = PlaybackScrub() }
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
