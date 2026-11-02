import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PlayerCore

/// The landed visit and its bounded window move together, before another drag.
struct FeedPager<Content: View>: UIViewControllerRepresentable {
    let window: PlaybackPageWindow
    let didSettle: (PlaybackPageWindow, String?) -> PlaybackPageWindow
    let interactionChanged: (Bool) -> Void
    @ViewBuilder let content: (PlaybackPage) -> Content

    init(window: PlaybackPageWindow, didSettle: @escaping (PlaybackPageWindow, String?) -> PlaybackPageWindow,
         interactionChanged: @escaping (Bool) -> Void, @ViewBuilder content: @escaping (PlaybackPage) -> Content) {
        self.window = window; self.didSettle = didSettle
        self.interactionChanged = interactionChanged; self.content = content
    }

    func makeUIViewController(context: Context) -> FeedPagingController<Content> {
        FeedPagingController(window: window, environment: context.environment,
            didSettle: didSettle, interactionChanged: interactionChanged, content: content)
    }

    func updateUIViewController(_ controller: FeedPagingController<Content>, context: Context) {
        controller.update(window: window, environment: context.environment,
            didSettle: didSettle, interactionChanged: interactionChanged, content: content)
    }

    static func dismantleUIViewController(_ controller: FeedPagingController<Content>, coordinator: ()) {
        controller.stop()
    }
}

@MainActor
final class FeedPagingController<Content: View>: UIViewController, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let contact = FeedContactObserver(target: nil, action: nil)
    private var contacting = false
    private var window: PlaybackPageWindow
    private var latestWindow: PlaybackPageWindow
    private var environment: EnvironmentValues
    private var didSettle: (PlaybackPageWindow, String?) -> PlaybackPageWindow
    private var interactionChanged: (Bool) -> Void
    private var content: (PlaybackPage) -> Content
    private var hosts: [String: UIHostingController<FeedHostedPage<Content>>] = [:]
    private var dragWindow: PlaybackPageWindow?
    private var interactionSerial: UInt64 = 0
    private var settling = false
    private var viewport = CGSize.zero

    init(window: PlaybackPageWindow, environment: EnvironmentValues,
         didSettle: @escaping (PlaybackPageWindow, String?) -> PlaybackPageWindow,
         interactionChanged: @escaping (Bool) -> Void, content: @escaping (PlaybackPage) -> Content) {
        self.window = window; latestWindow = window; self.environment = environment
        self.didSettle = didSettle; self.interactionChanged = interactionChanged; self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(window:environment:didSettle:interactionChanged:content:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black; view.clipsToBounds = true
        scroll.backgroundColor = .black; scroll.clipsToBounds = true
        scroll.isPagingEnabled = true; scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self
        contact.cancelsTouchesInView = false
        contact.delaysTouchesBegan = false; contact.delaysTouchesEnded = false
        contact.contactChanged = { [weak self] in self?.contactChanged($0) }
        scroll.addGestureRecognizer(contact)
        view.addSubview(scroll)
        apply(window)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if viewport != view.bounds.size { layoutPages(recenter: dragWindow == nil) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        apply(latestWindow)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        resetInteraction()
    }

    func update(window updated: PlaybackPageWindow, environment: EnvironmentValues,
                didSettle: @escaping (PlaybackPageWindow, String?) -> PlaybackPageWindow,
                interactionChanged: @escaping (Bool) -> Void, content: @escaping (PlaybackPage) -> Content) {
        latestWindow = updated; self.environment = environment
        self.didSettle = didSettle; self.interactionChanged = interactionChanged; self.content = content
        guard isViewLoaded else { window = updated; return }
        if dragWindow != nil || settling {
            // Keep membership/geometry stable, but update the owner and environment.
            refreshRoots()
        } else { apply(updated) }
    }

    private func root(for page: PlaybackPage) -> FeedHostedPage<Content> {
        FeedHostedPage(content: content(page), environment: environment)
    }

    private func refreshRoots() {
        for page in window.pages { hosts[page.id]?.rootView = root(for: page) }
    }

    private func apply(_ updated: PlaybackPageWindow) {
        window = updated
        guard isViewLoaded else { return }
        let kept = Set(window.pages.map(\.id))
        for id in Array(hosts.keys) where !kept.contains(id) {
            guard let host = hosts.removeValue(forKey: id) else { continue }
            host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
        }
        for page in window.pages {
            if let host = hosts[page.id] { host.rootView = root(for: page) }
            else {
                let host = UIHostingController(rootView: root(for: page))
                host.safeAreaRegions = []
                host.view.backgroundColor = .black; host.view.clipsToBounds = true
                addChild(host); scroll.addSubview(host.view); host.didMove(toParent: self)
                hosts[page.id] = host
            }
        }
        // Recenter even when a canceled/stale gesture returns the same window.
        layoutPages(recenter: true)
    }

    private func layoutPages(recenter: Bool) {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let fraction = viewport.height > 0 ? scroll.contentOffset.y / viewport.height : 0
        let pages = window.pages
        let current = pages.firstIndex { $0.id == window.current?.id } ?? 0
        UIView.performWithoutAnimation {
            scroll.frame = view.bounds
            for (index, page) in pages.enumerated() {
                hosts[page.id]?.view.frame = CGRect(x: 0, y: CGFloat(index) * size.height,
                    width: size.width, height: size.height)
            }
            scroll.contentSize = CGSize(width: size.width, height: CGFloat(pages.count) * size.height)
            let y = (recenter ? CGFloat(current) : fraction) * size.height
            scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            viewport = size
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        let wasInteracting = dragWindow != nil
        interactionSerial &+= 1; dragWindow = window
        if !wasInteracting { interactionChanged(true) }
    }

    private func contactChanged(_ down: Bool) {
        contacting = down
        if down {
            interactionSerial &+= 1
            if dragWindow == nil {
                dragWindow = window
                interactionChanged(true)
            }
        } else {
            // UIKit may deliver the passive touch-end before its pan/deceleration
            // state is final. A newer contact invalidates this one event-tail task.
            let serial = interactionSerial
            DispatchQueue.main.async { [weak self] in
                guard let self, self.interactionSerial == serial, !self.contacting else { return }
                self.settle()
            }
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settle() }

    private func settle() {
        // A canceled-deceleration callback cannot settle a newer tracking gesture.
        guard let captured = dragWindow, !contacting, !scroll.isTracking, !scroll.isDragging,
              !scroll.isDecelerating, scroll.bounds.height > 0 else { return }
        let pages = captured.pages
        let index = Int((scroll.contentOffset.y / scroll.bounds.height).rounded())
        let landed = pages.indices.contains(index) ? pages[index].id : nil
        let serial = interactionSerial
        dragWindow = nil; settling = true
        let updated = didSettle(captured, landed)
        guard serial == interactionSerial else { settling = false; return }
        latestWindow = updated
        apply(updated)
        settling = false
        interactionChanged(false)
    }

    private func resetInteraction() {
        let wasInteracting = dragWindow != nil
        interactionSerial &+= 1; dragWindow = nil; contacting = false
        if wasInteracting { interactionChanged(false) }
    }

    func stop() { scroll.delegate = nil; contact.contactChanged = nil; resetInteraction() }
}

/// Observes finger contact before the pan threshold without recognizing or
/// preventing taps, scrolling, or the page's playback controls.
@MainActor
final class FeedContactObserver: UIGestureRecognizer {
    var contactChanged: ((Bool) -> Void)?
    private var contacts = Set<UITouch>()
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let wasEmpty = contacts.isEmpty
        contacts.formUnion(touches)
        if wasEmpty { contactChanged?(true) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    private func finish(_ touches: Set<UITouch>) {
        contacts.subtract(touches)
        if contacts.isEmpty { contactChanged?(false); state = .failed }
    }
    override func reset() {
        super.reset()
        if !contacts.isEmpty { contacts.removeAll(); contactChanged?(false) }
    }
}

private struct FeedHostedPage<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues
    var body: some View { content.environment(\.self, environment) }
}
