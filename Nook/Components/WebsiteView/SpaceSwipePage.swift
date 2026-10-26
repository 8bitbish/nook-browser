// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSwipePage.swift
//  Nook
//
//  The web page across a sidebar swipe between spaces. The page stays put while the fingers
//  move (the sidebar and the window colour follow them); the moment the swipe commits, the
//  window shows the next space's page. While the swipe is under way that page draws out of
//  sight beside the container, so at release it is already drawn and only has to be shown;
//  a page that has not drawn yet is covered by its last picture until it has.
//

import AppKit
import WebKit
import OSLog
import NookDesign

/// A compositor container that readies the next space's page during a swipe.
@MainActor
protocol SpaceSwipeHost: NSView {
    var spaceSwipePage: SpaceSwipePage { get }
}

/// What a swipe step needs from the tab model, resolved by `BrowserManager`.
struct SpaceSwipeStep {
    /// The page the swipe heads for, nil when the space would show nothing or it is unknown.
    var itemID: UUID?
    /// Its live view when it has one free to show here.
    var webView: WKWebView?
    /// The page on screen now, so its picture is ready for the swipe back.
    var currentItemID: UUID?
    /// Set on release: true when the swipe commits to the space, false when it springs back.
    var release: Bool?
    /// False in private windows: no pictures of their pages are kept.
    var allowsSnapshots: Bool
}

@MainActor
final class SpaceSwipePage {
    private unowned let container: NSView

    private var isTracking = false
    private var committed = false
    private var itemID: UUID?
    /// The next space's page, drawing out of sight until the swipe commits or springs back.
    private var incoming: WKWebView?
    /// Whether the swipe put `incoming` in the container, so springing back takes it out again.
    private var addedIncoming = false
    private var incomingDrawn = false
    /// A picture of the incoming page, shown at release until the live page has drawn.
    private var cover: SnapshotLayerView?
    private var began: TimeInterval = 0
    private var allowsSnapshots = true

    /// Views drawing once off to the side so their picture can be taken (`prime`).
    private var primed: Set<ObjectIdentifier> = []

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SpaceSwipe")

    init(container: NSView) {
        self.container = container
    }

    // MARK: - Steps

    func apply(_ step: SpaceSwipeStep?) {
        guard let step else {
            // The sidebar's settle ended, or a new swipe cut it short.
            finish()
            return
        }
        if let release = step.release {
            if release { commit(step) } else { finish() }
            return
        }
        if !isTracking || step.itemID != itemID { begin(step) }
        if incoming == nil { park(step.webView) }
    }

    /// The swipe's space is now selected: the page it selected replaces the picture as soon as
    /// it has drawn, whichever page that turned out to be.
    func selected(_ webView: WKWebView?) {
        guard cover != nil else { return }
        guard let webView else { return dropCover(after: 0.5) }
        if webView === incoming, incomingDrawn { return dropCover() }
        afterNextPresentation(of: webView, timeout: 1) { [weak self] in self?.dropCover() }
    }

    private func begin(_ step: SpaceSwipeStep) {
        finish()
        isTracking = true
        itemID = step.itemID
        began = ProcessInfo.processInfo.systemUptime
        allowsSnapshots = step.allowsSnapshots

        // The page leaving: its picture covers the swipe back.
        if allowsSnapshots, let current = step.currentItemID, let view = shownWebView() {
            PageSnapshotCache.shared.capture(view, as: current)
        }
        park(step.webView)
        Self.log.notice("swipe page: incoming \(step.webView == nil ? "none" : "live", privacy: .public), picture \(self.picture == nil ? "none" : "cached", privacy: .public)")
    }

    /// Puts the next space's page beside the container, out of sight, so it draws while the
    /// fingers move.
    private func park(_ webView: WKWebView?) {
        guard let webView, webView.fullscreenState == .notInFullscreen else { return }
        if webView.superview == nil {
            container.addSubview(webView, positioned: .below, relativeTo: overlay)
            addedIncoming = true
        } else if webView.superview === container, primed.remove(ObjectIdentifier(webView)) != nil {
            // Drawing for its picture: the swipe takes it over.
            addedIncoming = true
        } else {
            return
        }
        incoming = webView
        incomingDrawn = false
        webView.isHidden = false
        webView.alphaValue = 1
        webView.autoresizingMask = []
        webView.frame = sideFrame
        let started = began
        afterNextPresentation(of: webView, timeout: 2) { [weak self, weak webView] in
            guard let self, let webView, self.incoming === webView else { return }
            self.incomingDrawn = true
            Self.log.notice("swipe page drew +\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000), privacy: .public)ms after swipe began")
        }
    }

    /// The fingers lifted past the threshold: the next page goes on screen now, before the
    /// selection and the compositor catch up. The compositor then finds it already in place.
    private func commit(_ step: SpaceSwipeStep) {
        if !isTracking { begin(step) }
        committed = true
        let shown: String
        if let incoming, incomingDrawn, incoming.superview === container {
            // Added after the page on screen, so already above it.
            incoming.frame = container.bounds
            incoming.autoresizingMask = [.width, .height]
            shown = "live page"
        } else if let picture {
            let cover = SnapshotLayerView(image: picture)
            cover.frame = container.bounds
            cover.autoresizingMask = [.width, .height]
            container.addSubview(cover, positioned: .below, relativeTo: overlay)
            self.cover = cover
            // Still drawing: the compositor waits for its first frame before showing it.
            incoming?.alphaValue = 0
            shown = "picture"
            dropCover(after: 1.5)
        } else {
            incoming?.alphaValue = 0
            shown = "nothing yet (waits for the page)"
        }
        Self.log.notice("swipe released: showing \(shown, privacy: .public) +\(Int((ProcessInfo.processInfo.systemUptime - self.began) * 1000), privacy: .public)ms after swipe began")
        // From here the compositor owns the page.
        incoming = nil
        addedIncoming = false
        isTracking = false
    }

    /// Ends a swipe. One that sprang back takes its parked page out again.
    private func finish() {
        if !committed, let incoming, addedIncoming, incoming.superview === container {
            incoming.removeFromSuperview()
            incoming.alphaValue = 1
        }
        incoming = nil
        addedIncoming = false
        incomingDrawn = false
        isTracking = false
        committed = false
        itemID = nil
    }

    private func dropCover(after delay: TimeInterval = 0) {
        guard delay > 0 else {
            cover?.removeFromSuperview()
            cover = nil
            return
        }
        let target = cover
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let target, self.cover === target else { return }
            self.dropCover()
        }
    }

    private var picture: CGImage? {
        allowsSnapshots ? itemID.flatMap { PageSnapshotCache.shared.image(for: $0) } : nil
    }

    // MARK: - Pictures

    /// Draws `webView` once beside the container's page, out of sight, and keeps its picture, so
    /// a quick flick to its space shows it at once. Only for a page in no window; it leaves as
    /// soon as the picture is taken.
    func prime(_ webView: WKWebView, as itemID: UUID) {
        guard !isTracking, webView.superview == nil, webView.fullscreenState == .notInFullscreen,
              PageSnapshotCache.shared.image(for: itemID) == nil, container.bounds.width > 0 else { return }
        let key = ObjectIdentifier(webView)
        primed.insert(key)
        container.addSubview(webView, positioned: .below, relativeTo: overlay)
        webView.autoresizingMask = []
        webView.frame = sideFrame
        var done = false
        let release = { [weak self, weak webView] in
            guard let self, let webView, !done else { return }
            done = true
            guard self.primed.remove(key) != nil, webView.superview === self.container else { return }
            webView.removeFromSuperview()
        }
        afterNextPresentation(of: webView, timeout: 2) { [weak self, weak webView] in
            guard let self, let webView, self.primed.contains(key) else { return }
            PageSnapshotCache.shared.capture(webView, as: itemID) { release() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { release() }
    }

    /// Whether `view` is in the container only to draw out of sight (for its picture, or as a
    /// swipe's next page), so the compositor leaves it be.
    func isParked(_ view: NSView) -> Bool {
        primed.contains(ObjectIdentifier(view)) || view === incoming
    }

    /// The compositor is about to show `view`: it is no longer only drawing out of sight.
    func adopt(_ view: NSView) {
        primed.remove(ObjectIdentifier(view))
    }

    // MARK: - Geometry

    /// Two widths to the right: inside the window, so WebKit draws it, but clipped by the
    /// container and never on screen.
    private var sideFrame: NSRect {
        container.bounds.offsetBy(dx: container.bounds.width * 2, dy: 0)
    }

    private var overlay: NSView? {
        container.subviews.first { $0 is SplitDropCaptureView }
    }

    /// The page on screen: the newest web view the compositor shows.
    private func shownWebView() -> WKWebView? {
        container.subviews.last {
            $0 is WKWebView && $0.alphaValue > 0 && !isParked($0)
        } as? WKWebView
    }
}

/// Runs `body` once WebKit has put the page's next frame on screen, or after `timeout` for a page
/// that is not presenting (an occluded window, a stalled load).
@MainActor
func afterNextPresentation(of webView: WKWebView, timeout: TimeInterval = 0.25, _ body: @escaping () -> Void) {
    var done = false
    let once = { if !done { done = true; body() } }
    let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
    if webView.responds(to: selector) {
        typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(webView.method(for: selector), to: Call.self)(webView, selector) { once() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once() }
}

// MARK: - Snapshots

/// A picture of a page, drawn by its layer.
final class SnapshotLayerView: NSView {
    init(image: CGImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The last few pages' pictures, for a swipe to show before the live page has drawn. In memory
/// only, a handful at most (one full-window picture is about 20 MB at 2x), dropped on memory
/// pressure.
@MainActor
final class PageSnapshotCache {
    static let shared = PageSnapshotCache()

    private var images: [UUID: CGImage] = [:]
    private var order: [UUID] = []
    private static let limit = 4
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    private init() {
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.removeAll() }
        }
        pressure.activate()
    }

    func image(for itemID: UUID) -> CGImage? {
        images[itemID]
    }

    func capture(_ webView: WKWebView, as itemID: UUID, completion: @escaping () -> Void = {}) {
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { return completion() }
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = false
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            defer { completion() }
            guard let self, let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            self.store(cgImage, for: itemID)
        }
    }

    private func store(_ image: CGImage, for itemID: UUID) {
        images[itemID] = image
        order.removeAll { $0 == itemID }
        order.append(itemID)
        while order.count > Self.limit {
            images.removeValue(forKey: order.removeFirst())
        }
    }

    func removeAll() {
        images.removeAll()
        order.removeAll()
    }
}
