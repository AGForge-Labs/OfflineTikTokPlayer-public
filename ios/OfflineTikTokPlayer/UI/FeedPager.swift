import SwiftUI
import PlayerCore

/// Three real visits, with identities that survive an incoming page becoming current.
struct FeedPager<Content: View>: View {
    let liveWindow: PlaybackPageWindow
    let didSettle: (PlaybackPageWindow, String?) -> PlaybackPageWindow
    let interactionChanged: (Bool) -> Void
    @ViewBuilder let content: (PlaybackPage) -> Content
    @State private var window: PlaybackPageWindow
    @State private var position: String?
    @State private var interacting = false

    init(window: PlaybackPageWindow, didSettle: @escaping (PlaybackPageWindow, String?) -> PlaybackPageWindow,
         interactionChanged: @escaping (Bool) -> Void,
         @ViewBuilder content: @escaping (PlaybackPage) -> Content) {
        liveWindow = window
        self.didSettle = didSettle
        self.interactionChanged = interactionChanged
        self.content = content
        _window = State(initialValue: window)
        _position = State(initialValue: window.current?.id)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(window.pages) { page in
                    content(page)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .clipped()
                        .id(page.id)
                }
            }.scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $position, anchor: .center)
        .scrollBounceBehavior(.basedOnSize)
        .clipped()
        .onScrollPhaseChange { _, phase in
            if phase == .idle {
                guard interacting else { return }
                interacting = false
                interactionChanged(false)
                // The owner reads its queue now, even if a remote command just preceded this
                // callback and SwiftUI has not rendered the corresponding liveWindow yet.
                follow(didSettle(window, position))
                // The owner publishes the new current visit. Keep the arriving page in place;
                // moving it to a synthetic "current" slot destroys its view and flashes a frame.
            } else if phase == .tracking || phase == .interacting || phase == .decelerating {
                interacting = true
                interactionChanged(true)
            }
        }
        .onChange(of: liveWindow) { _, updated in if !interacting { follow(updated) } }
        .onDisappear { interactionChanged(false) }
    }

    private func follow(_ updated: PlaybackPageWindow) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            window = updated
            position = updated.current?.id
        }
    }
}
