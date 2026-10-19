import UIKit
import AVFoundation
import SwiftUI

final class PlayerSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("Use init(player:)") }
}

/// SwiftUI owns each host, while the playback service owns the single video layer.
final class PlayerSurfaceHost: UIView {
    private var surface: PlayerSurface?

    func attach(_ surface: PlayerSurface) {
        if self.surface !== surface { detach(); self.surface = surface }
        guard surface.superview !== self else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        addSubview(surface)
        surface.frame = bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        CATransaction.commit()
    }

    func detach() {
        // An older page can be dismantled after a newer page has already attached the layer.
        if surface?.superview === self { surface?.removeFromSuperview() }
        surface = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let surface, surface.superview === self else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = bounds
        CATransaction.commit()
    }
}

struct PersistentPlayerSurface: UIViewRepresentable {
    let surface: PlayerSurface
    var isActive = true
    func makeUIView(context: Context) -> PlayerSurfaceHost {
        let host = PlayerSurfaceHost()
        host.isUserInteractionEnabled = false
        if isActive { host.attach(surface) }
        return host
    }
    func updateUIView(_ uiView: PlayerSurfaceHost, context: Context) {
        if isActive { uiView.attach(surface) } else { uiView.detach() }
    }
    static func dismantleUIView(_ uiView: PlayerSurfaceHost, coordinator: ()) { uiView.detach() }
}

/// Both branches keep their identity while a visit changes from preview to playing to history.
struct FeedVideoSurface<Poster: View>: View {
    let surface: PlayerSurface
    let isActive: Bool
    let isReady: Bool
    @ViewBuilder var poster: Poster
    var body: some View {
        ZStack {
            PersistentPlayerSurface(surface: surface, isActive: isActive)
            poster.opacity(isActive && isReady ? 0 : 1).allowsHitTesting(false)
        }.background(.black).transaction { $0.animation = nil }
    }
}
