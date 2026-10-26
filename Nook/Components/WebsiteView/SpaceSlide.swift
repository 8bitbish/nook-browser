// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSlide.swift
//  Nook
//
//  The web page following a sidebar swipe between spaces, as in Arc: the page on screen slides
//  out and the next space's page slides in with the fingers, then settles with the sidebar's
//  spring. The whole compositor content moves through its layer's `sublayerTransform`, so no
//  web view changes frame (and WebKit lays nothing out) until the swipe is over.
//

import AppKit
import WebKit
import OSLog
import NookDesign

/// A compositor container that can slide its page aside for a space swipe.
@MainActor
protocol SpaceSlideHost: NSView {
    var spaceSlide: SpaceSlide { get }
}

/// What a swipe step needs from the tab model, resolved by `BrowserManager`.
struct SpaceSlideStep {
    /// The page the swipe heads for, nil when the space would show nothing or it is unknown.
    var itemID: UUID?
    /// Its live view when it has one free to show here.
    var webView: WKWebView?
    /// The page on screen now, so its picture is ready for the swipe back.
    var currentItemID: UUID?
    var fraction: CGFloat
    var forward: Bool
    /// Set on release: the settle to 1 (commit) or back to 0 (cancel).
    var settles: Bool
    /// False in private windows: no pictures of their pages are kept.
    var allowsSnapshots: Bool
}

@MainActor
final class SpaceSlide {
    private unowned let container: NSView
    /// Runs the compositor pass a slide held back.
    var recomposite: () -> Void = {}

    /// True from the first step of a swipe until its settle ends. The compositor leaves the
    /// container alone meanwhile and asks again afterwards (`needsRecomposite`).
    private(set) var isActive = false
    var needsRecomposite = false

    private var itemID: UUID?
    private var forward = true
    private var fraction: CGFloat = 0
    private var samples: [(fraction: CGFloat, time: TimeInterval)] = []
    private var incoming: WKWebView?
    /// Whether this slide put `incoming` in the container, so a cancel takes it out again.
    private var addedIncoming = false
    /// A picture of the incoming page, over it until the live page has drawn.
    private var cover: SnapshotLayerView?
    private var began: TimeInterval = 0
    private var released: TimeInterval = 0
    private var settleID = 0
    private var pendingSettle: (() -> Void)?
    private var allowsSnapshots = true

    /// Views drawing once off to the side so their picture can be taken (`prime`).
    private var primed: Set<ObjectIdentifier> = []

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SpaceSwipe")
    private static let animationKey = "nook.spaceSlide"
    /// The pages' gap while they slide side by side.
    private static let gap = NookDesign.Spacing.md
    /// `spaceSettle`'s response; the sidebar pager settles with the same spring.
    private static let settleDuration: TimeInterval = 0.3

    init(container: NSView) {
        self.container = container
    }

    // MARK: - Steps

    func apply(_ step: SpaceSlideStep?) {
        guard let step else {
            // The sidebar's settle ended, or a new swipe cut it short: end ours with it.
            finishSettle()
            if isActive { end(committed: false) }
            return
        }
        if !isActive || step.itemID != itemID || step.forward != forward {
            if isActive { finishSettle(); end(committed: false) }
            begin(step)
        }
        if step.webView != nil, incoming == nil { attach(step.webView) }

        let now = ProcessInfo.processInfo.systemUptime
        if step.settles {
            settle(to: step.fraction)
        } else {
            samples.append((step.fraction, now))
            if samples.count > 4 { samples.removeFirst() }
            fraction = step.fraction
            setTranslation(for: fraction)
        }
    }

    /// The swipe's space is now selected: its page, created by the selection if it had none,
    /// joins the slide.
    func selected(_ webView: WKWebView?, itemID: UUID?) {
        guard isActive, let webView, webView !== incoming else { return }
        if webView.superview != nil && webView.superview !== container { return }
        if let incoming, addedIncoming, incoming.superview === container { incoming.removeFromSuperview() }
        incoming = nil
        if itemID != self.itemID { cover?.removeFromSuperview(); cover = nil }
        self.itemID = itemID
        attach(webView)
    }

    private func begin(_ step: SpaceSlideStep) {
        isActive = true
        needsRecomposite = false
        itemID = step.itemID
        forward = step.forward
        fraction = 0
        samples = []
        began = ProcessInfo.processInfo.systemUptime
        allowsSnapshots = step.allowsSnapshots

        // The page leaving: its picture covers the swipe back.
        if allowsSnapshots, let current = step.currentItemID, let view = shownWebView() {
            PageSnapshotCache.shared.capture(view, as: current)
        }

        let picture = allowsSnapshots ? step.itemID.flatMap { PageSnapshotCache.shared.image(for: $0) } : nil
        if let picture {
            let cover = SnapshotLayerView(image: picture)
            cover.frame = incomingFrame
            container.addSubview(cover, positioned: .below, relativeTo: overlay)
            self.cover = cover
        }
        attach(step.webView)
        Self.log.notice("slide began: incoming \(step.webView == nil ? "none" : "live", privacy: .public), picture \(picture == nil ? "none" : "cached", privacy: .public)")
    }

    /// Puts the incoming page beside the one on screen, under its picture if it has one, or
    /// invisible until it has drawn so a page repainting after time out of the window never
    /// shows blank.
    private func attach(_ webView: WKWebView?) {
        guard let webView, webView.fullscreenState == .notInFullscreen else { return }
        if webView.superview == nil {
            container.addSubview(webView, positioned: .below, relativeTo: cover ?? overlay)
            addedIncoming = true
        } else if webView.superview === container {
            // Drawing to the side for its picture: the slide takes it over.
            addedIncoming = primed.remove(ObjectIdentifier(webView)) != nil
        } else {
            return
        }
        incoming = webView
        webView.isHidden = false
        webView.autoresizingMask = []
        webView.frame = incomingFrame
        if cover == nil { webView.alphaValue = 0 }
        let started = began
        afterNextPresentation(of: webView) { [weak self, weak webView] in
            guard let self, let webView, webView.superview === self.container else { return }
            webView.alphaValue = 1
            if self.incoming === webView { self.dropCover() }
            Self.log.notice("slide incoming page drew +\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000), privacy: .public)ms after swipe began")
        }
    }

    // MARK: - Settle

    private func settle(to target: CGFloat) {
        let committing = target >= 1
        released = ProcessInfo.processInfo.systemUptime
        let velocity = Self.velocity(samples)
        let remaining = max(abs(target - fraction), 0.05)

        let animation = CASpringAnimation(perceptualDuration: Self.settleDuration, bounce: 0)
        animation.keyPath = "sublayerTransform"
        animation.fromValue = NSValue(caTransform3D: presentedTransform)
        animation.toValue = NSValue(caTransform3D: transform(for: target))
        // Carries the finger's speed into the spring, as the sidebar's does.
        animation.initialVelocity = min(abs(velocity) / remaining, 30)
        animation.duration = animation.settlingDuration

        settleID += 1
        let id = settleID
        pendingSettle = { [weak self] in self?.end(committed: committing) }
        fraction = target
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.settleID == id else { return }
                self.finishSettle()
            }
        }
        setTranslation(for: target)
        container.layer?.add(animation, forKey: Self.animationKey)
        CATransaction.commit()
    }

    /// Ends a settle under way now, from its own completion or because the sidebar's ended.
    private func finishSettle() {
        guard let pending = pendingSettle else { return }
        pendingSettle = nil
        settleID += 1
        pending()
    }

    /// Puts everything back in place in one transaction: on a commit the incoming page fills the
    /// container and the page that slid out leaves, then the compositor pass that waited runs.
    private func end(committed: Bool) {
        guard isActive else { return }
        let window = container.window
        let pageHadFocus = (window?.firstResponder as? NSView)?.isDescendant(of: container) ?? false

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer?.removeAnimation(forKey: Self.animationKey)
        container.layer?.sublayerTransform = CATransform3DIdentity
        if committed {
            for view in contentViews where view !== incoming {
                view.removeFromSuperview()
                view.alphaValue = 1
            }
            incoming?.frame = container.bounds
            incoming?.autoresizingMask = [.width, .height]
            cover?.frame = container.bounds
        } else {
            if let incoming, addedIncoming, incoming.superview === container {
                incoming.removeFromSuperview()
                incoming.alphaValue = 1
            }
            dropCover()
        }
        isActive = false
        if committed || needsRecomposite { recomposite() }
        needsRecomposite = false
        CATransaction.commit()

        if committed {
            // The page now on screen draws before its picture goes, whichever page it turned out to be.
            if let shown = shownWebView() {
                if cover != nil {
                    afterNextPresentation(of: shown) { [weak self] in self?.dropCover() }
                }
                if pageHadFocus || window?.firstResponder === window { window?.makeFirstResponder(shown) }
            } else {
                dropCover()
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        Self.log.notice("slide \(committed ? "committed" : "cancelled", privacy: .public): settled \(Int((now - self.released) * 1000), privacy: .public)ms after release, \(Int((now - self.began) * 1000), privacy: .public)ms after swipe began")
        incoming = nil
        addedIncoming = false
        itemID = nil
    }

    private func dropCover() {
        cover?.removeFromSuperview()
        cover = nil
    }

    // MARK: - Pictures

    /// Draws `webView` once beside the container's page, out of sight, and keeps its picture, so
    /// a quick flick to its space shows it at once. Only for a page in no window; it leaves as
    /// soon as the picture is taken.
    func prime(_ webView: WKWebView, as itemID: UUID) {
        guard !isActive, webView.superview == nil, webView.fullscreenState == .notInFullscreen,
              PageSnapshotCache.shared.image(for: itemID) == nil, container.bounds.width > 0 else { return }
        let key = ObjectIdentifier(webView)
        primed.insert(key)
        container.addSubview(webView, positioned: .below, relativeTo: overlay)
        webView.autoresizingMask = []
        // Two widths over: the pages slide only one width, so this never comes into sight.
        webView.frame = container.bounds.offsetBy(dx: (container.bounds.width + Self.gap) * 2, dy: 0)
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

    /// Whether `view` is in the container only for `prime`, so the compositor leaves it be.
    func isPrimed(_ view: NSView) -> Bool {
        primed.contains(ObjectIdentifier(view))
    }

    /// The compositor is about to show `view`: it is no longer only drawing for its picture.
    func adopt(_ view: NSView) {
        primed.remove(ObjectIdentifier(view))
    }

    // MARK: - Geometry

    private var distance: CGFloat { container.bounds.width + Self.gap }

    private var incomingFrame: NSRect {
        container.bounds.offsetBy(dx: forward ? distance : -distance, dy: 0)
    }

    private func transform(for fraction: CGFloat) -> CATransform3D {
        CATransform3DMakeTranslation((forward ? -1 : 1) * fraction * distance, 0, 0)
    }

    private func setTranslation(for fraction: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.layer?.sublayerTransform = transform(for: fraction)
        CATransaction.commit()
    }

    private var presentedTransform: CATransform3D {
        container.layer?.presentation()?.sublayerTransform ?? container.layer?.sublayerTransform ?? CATransform3DIdentity
    }

    private var overlay: NSView? {
        container.subviews.first { $0 is SplitDropCaptureView }
    }

    /// Pages and panes, leaving out the drop overlay, the picture and pages drawing only for theirs.
    private var contentViews: [NSView] {
        container.subviews.filter { !($0 is SplitDropCaptureView) && $0 !== cover && !isPrimed($0) }
    }

    /// The page on screen: the newest web view not waiting to appear or sliding in.
    private func shownWebView() -> WKWebView? {
        contentViews.last { $0 is WKWebView && $0.alphaValue > 0 && $0 !== incoming } as? WKWebView
            ?? (contentViews.last { $0 is WKWebView } as? WKWebView)
    }

    /// Fraction per second over the last few steps.
    private static func velocity(_ samples: [(fraction: CGFloat, time: TimeInterval)]) -> CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return (last.fraction - first.fraction) / (last.time - first.time)
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
