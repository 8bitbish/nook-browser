#if canImport(AppKit)

import SwiftUI
import OSLog
import NookDesign

// Nook: a trackpad pager of its own instead of NSPageController. The system pager eases each
// swipe out with its own momentum after the fingers lift; here the lift hands off to a short
// spring. Progress goes out through `onPageTransition` so the window's colour and the web page
// can follow it. The selection changes the moment the fingers lift, not when the spring settles,
// and a new swipe may start while the last one is still settling.
extension PlatformPageView: NSViewRepresentable {

    func makeNSView(context: Context) -> SwipePagerView {
        let view = SwipePagerView()
        view.coordinator = context.coordinator
        context.coordinator.pager = view
        context.coordinator.onTransition = context.environment.pageTransitionHandler
        context.coordinator.show(selection)
        return view
    }

    func updateNSView(_ view: SwipePagerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.onTransition = context.environment.pageTransitionHandler
        context.coordinator.refresh(to: selection, animated: context.transaction.animation != nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        var parent: PlatformPageView
        weak var pager: SwipePagerView?
        var onTransition: ((PageTransition) -> Void)?
        private(set) var current: SelectionValue?
        private var views: [SelectionValue: HostingView] = [:]

        init(_ parent: PlatformPageView) {
            self.parent = parent
        }

        func view(for value: SelectionValue) -> HostingView {
            if let view = views[value] {
                view.rootView = parent.content(value)
                return view
            }
            let view = HostingView(rootView: parent.content(value))
            views[value] = view
            return view
        }

        /// Shows `value` with no animation and drops pages that are no longer neighbours.
        func show(_ value: SelectionValue) {
            // A swipe still settling ends first, so its completion cannot land on top of this.
            pager?.finishSettle()
            current = value
            let keep = Set([value, parent.previous(value), parent.next(value)].compactMap { $0 })
            views = views.filter { keep.contains($0.key) }
            pager?.present(view(for: value))
        }

        func refresh(to value: SelectionValue, animated: Bool) {
            guard value != current else {
                if let current { _ = view(for: current) }
                return
            }
            guard animated, let pager, let from = current else { return show(value) }
            let forward = isAfter(value, from)
            pager.animate(to: view(for: value), forward: forward) { [weak self] in self?.show(value) }
        }

        /// Whether `value` comes after `from`, so a jump across several pages slides the right way.
        private func isAfter(_ value: SelectionValue, _ from: SelectionValue) -> Bool {
            var page = from
            while let next = parent.next(page) {
                if next == value { return true }
                page = next
            }
            return false
        }

        func neighbour(forward: Bool) -> SelectionValue? {
            guard let current else { return nil }
            return forward ? parent.next(current) : parent.previous(current)
        }

        func report(_ target: SelectionValue?, _ fraction: CGFloat, forward: Bool = true, animation: Animation? = nil) {
            // Pages are keyed by a type-erased value; followers get the caller's own (a space id).
            let value = target.map { target -> AnyHashable in
                if let erased = target as? PageViewStyleConfiguration.Value { return AnyHashable(erased.wrappedValue) }
                return AnyHashable(target)
            }
            onTransition?(PageTransition(target: value, fraction: fraction, forward: forward, animation: animation))
        }

        /// Makes `value` the selection while its page is still settling into place. `current`
        /// moves first, so the update the binding causes finds nothing to animate.
        func select(_ value: SelectionValue) {
            current = value
            parent.selection = value
        }
    }

    // MARK: - Views

    final class SwipePagerView: NSView {
        weak var coordinator: Coordinator?
        private var page: HostingView?
        private var incoming: HostingView?
        private var isTracking = false
        /// The spring after a swipe, still running: what to do when it ends, keyed by `settleID` so
        /// a settle cut short by the next swipe does nothing when its animation reports in.
        private var pendingSettle: (() -> Void)?
        private var settleID = 0

        /// The settle after the fingers lift, and a programmatic page change.
        static var settle: Animation { NookDesign.Motion.spaceSettle }

        private static var log: Logger { Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SpaceSwipe") }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            installTestDriver()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func present(_ view: HostingView) {
            if let incoming, incoming !== view { incoming.removeFromSuperview() }
            incoming = nil
            if let page, page !== view { page.removeFromSuperview() }
            page = view
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            if view.superview !== self { addSubview(view) }
        }

        override func layout() {
            super.layout()
            if !isTracking && pendingSettle == nil { page?.frame = bounds }
        }

        /// A programmatic change: the new page slides in from its side.
        func animate(to view: HostingView, forward: Bool, completion: @escaping () -> Void) {
            finishSettle()
            guard let page, !isTracking else { return completion() }
            place(view)
            setOffset(0, page: page, incoming: view, forward: forward)
            run(to: forward ? -bounds.width : bounds.width, page: page, incoming: view, forward: forward,
                animation: Self.settle, completion: completion)
        }

        /// Ends a settle still under way at once, so the next swipe starts from a page at rest.
        func finishSettle() {
            guard let pending = pendingSettle else { return }
            pendingSettle = nil
            settleID += 1
            for view in subviews { view.layer?.removeAllAnimations() }
            pending()
        }

        override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
            axis == .horizontal
        }

        override func scrollWheel(with event: NSEvent) {
            guard event.phase == .began, event.hasPreciseScrollingDeltas,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            else { return super.scrollWheel(with: event) }
            guard !isTracking, NSEvent.isSwipeTrackingFromScrollEventsEnabled else {
                Self.log.notice("swipe ignored: \(self.isTracking ? "still tracking" : "swipe tracking off in System Settings", privacy: .public)")
                return super.scrollWheel(with: event)
            }
            guard let swipe = beginSwipe() else { return super.scrollWheel(with: event) }

            // Positive amounts drag the page right, toward the previous space. Past the first or
            // last space the amount is damped toward 0, which reads as a rubber band.
            event.trackSwipeEvent(
                options: [.lockDirection, .clampGestureAmount],
                dampenAmountThresholdMin: swipe.hasNext ? -1 : 0,
                max: swipe.hasPrevious ? 1 : 0
            ) { amount, phase, _, stop in
                if swipe.step(amount, phase) { stop.pointee = true }
            }
        }

        /// One swipe's handler: `step` takes each gesture amount and returns true once the swipe
        /// is over. Nil when there is nowhere to go.
        private func beginSwipe() -> (hasPrevious: Bool, hasNext: Bool, step: (CGFloat, NSEvent.Phase) -> Bool)? {
            // A swipe never waits for the last one's spring, or for any page to load.
            if pendingSettle != nil {
                Self.log.notice("swipe began while settling: settle finished early")
                finishSettle()
            }
            guard let coordinator, let page else { return nil }

            let previous = coordinator.neighbour(forward: false)
            let next = coordinator.neighbour(forward: true)
            guard previous != nil || next != nil else { return nil }

            isTracking = true
            var target: (value: SelectionValue, view: HostingView, forward: Bool)?
            var samples: [(amount: CGFloat, time: TimeInterval)] = []
            var playedHaptic = false
            var steps = 0
            let width = bounds.width
            let began = ProcessInfo.processInfo.systemUptime
            Self.log.notice("swipe began")

            let step: (CGFloat, NSEvent.Phase) -> Bool = { [weak self] amount, phase in
                guard let self else { return true }
                let forward = amount < 0
                if amount != 0, target?.forward != forward, let value = forward ? next : previous {
                    let view = coordinator.view(for: value)
                    target = (value, view, forward)
                    self.place(view)
                }
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - began) * 1000)

                switch phase {
                case .began, .changed:
                    steps += 1
                    if steps == 2 { Self.log.notice("swipe moving +\(elapsed, privacy: .public)ms") }
                    samples.append((amount, ProcessInfo.processInfo.systemUptime))
                    if samples.count > 4 { samples.removeFirst() }
                    self.setOffset(amount * width, page: page, incoming: target?.view, forward: target?.forward ?? forward)
                    coordinator.report(target?.value, target?.forward == forward ? abs(amount) : 0,
                                       forward: target?.forward ?? forward)
                    if !playedHaptic, abs(amount) > 0.15 {
                        playedHaptic = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                case .ended, .cancelled:
                    // Take over from the system's momentum with a short spring of our own.
                    self.isTracking = false
                    let velocity = Self.velocity(samples)
                    // A flick commits however short it was; a slow drag needs to pass a third.
                    let commits = phase == .ended && target.map {
                        $0.forward == (amount < 0)
                            && (abs(amount) > 0.3 || ($0.forward ? velocity < -0.8 : velocity > 0.8))
                    } == true
                    Self.log.notice("swipe ended +\(elapsed, privacy: .public)ms amount \(String(format: "%.2f", amount), privacy: .public) velocity \(String(format: "%.1f", velocity), privacy: .public)/s steps \(steps, privacy: .public) \(commits ? "commit" : "cancel", privacy: .public)")
                    if let target, commits {
                        // Carries the finger's speed into the spring, so a flick keeps going.
                        let remaining = max(1 - abs(amount), 0.05)
                        let animation = Animation.interpolatingSpring(
                            duration: Self.settleDuration, bounce: 0,
                            initialVelocity: min(abs(velocity) / remaining, 30))
                        coordinator.report(target.value, 1, forward: target.forward, animation: animation)
                        // The space changes now: its page is on its way in, and nothing that
                        // follows the selection waits for the spring.
                        coordinator.select(target.value)
                        let released = ProcessInfo.processInfo.systemUptime
                        self.run(to: target.forward ? -width : width, page: page, incoming: target.view,
                                 forward: target.forward, animation: animation) {
                            Self.log.notice("swipe settled \(Int((ProcessInfo.processInfo.systemUptime - released) * 1000), privacy: .public)ms after release")
                            coordinator.show(target.value)
                            coordinator.report(nil, 0)
                        }
                    } else {
                        let incoming = target?.view
                        coordinator.report(target?.value, 0, forward: target?.forward ?? true, animation: Self.settle)
                        self.run(to: 0, page: page, incoming: incoming, forward: target?.forward ?? true,
                                 animation: Self.settle) {
                            incoming?.removeFromSuperview()
                            if self.incoming === incoming { self.incoming = nil }
                            page.frame = self.bounds
                            coordinator.report(nil, 0)
                        }
                    }
                default:
                    break
                }
                return phase == .ended || phase == .cancelled
            }
            return (previous != nil, next != nil, step)
        }

        // MARK: - Test driver

        /// Hands-off checks: launched with `-NookSwipeTestDriver YES`, the pager plays a scripted
        /// swipe through the same handler a trackpad drives when told to by the distributed
        /// notification `com.gstudios.nook.testSwipe` (object "forward|back,<seconds>[,<amount>]").
        /// Off unless that argument is passed, so an installed app never listens.
        private var testObserver: NSObjectProtocol?

        private func installTestDriver() {
            guard UserDefaults.standard.bool(forKey: "NookSwipeTestDriver") else { return }
            testObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.gstudios.nook.testSwipe"), object: nil, queue: .main
            ) { [weak self] note in
                let parts = (note.object as? String ?? "forward,0.4").split(separator: ",").map(String.init)
                let forward = parts.first != "back"
                let duration = parts.count > 1 ? Double(parts[1]) ?? 0.4 : 0.4
                let reach = parts.count > 2 ? Double(parts[2]) ?? 0.6 : 0.6
                MainActor.assumeIsolated { self?.playTestSwipe(forward: forward, duration: duration, reach: reach) }
            }
        }

        private func playTestSwipe(forward: Bool, duration: TimeInterval, reach: CGFloat) {
            guard !isTracking, let swipe = beginSwipe() else { return }
            let sign: CGFloat = forward ? -1 : 1
            let start = ProcessInfo.processInfo.systemUptime
            var first = true
            Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { timer in
                MainActor.assumeIsolated {
                    let t = min((ProcessInfo.processInfo.systemUptime - start) / duration, 1)
                    let amount = sign * reach * CGFloat(t)
                    _ = swipe.step(amount, first ? .began : .changed)
                    first = false
                    if t >= 1 {
                        timer.invalidate()
                        _ = swipe.step(amount, .ended)
                    }
                }
            }
        }

        /// `spaceSettle`'s response, for the velocity-carrying spring a release starts.
        private static var settleDuration: TimeInterval { 0.3 }

        private func place(_ view: HostingView) {
            if let incoming, incoming !== view { incoming.removeFromSuperview() }
            incoming = view
            view.autoresizingMask = []
            view.frame = bounds
            if view.superview !== self { addSubview(view) }
        }

        private func setOffset(_ offset: CGFloat, page: NSView, incoming: NSView?, forward: Bool) {
            page.frame = bounds.offsetBy(dx: offset, dy: 0)
            incoming?.frame = bounds.offsetBy(dx: offset + (forward ? bounds.width : -bounds.width), dy: 0)
        }

        private func run(to offset: CGFloat, page: NSView, incoming: NSView?, forward: Bool,
                         animation: Animation, completion: @escaping () -> Void) {
            let width = bounds.width
            settleID += 1
            let id = settleID
            pendingSettle = completion
            NSAnimationContext.animate(animation) {
                page.animator().frame = bounds.offsetBy(dx: offset, dy: 0)
                incoming?.animator().frame = bounds.offsetBy(dx: offset + (forward ? width : -width), dy: 0)
            } completion: {
                MainActor.assumeIsolated {
                    guard self.settleID == id, let pending = self.pendingSettle else { return }
                    self.pendingSettle = nil
                    pending()
                }
            }
        }

        /// Gesture amount per second over the last few samples, so a quick flick commits.
        private static func velocity(_ samples: [(amount: CGFloat, time: TimeInterval)]) -> CGFloat {
            guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
            return (last.amount - first.amount) / (last.time - first.time)
        }
    }

    final class HostingView: NSHostingView<Content> {
        // Scroll views inside forward horizontal swipes up to the pager.
        override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
            axis == .horizontal
        }
    }
}

struct PlatformPageView_Mac_Previews: PreviewProvider {

    static var previews: some View {
        PageViewBasicExample()
            .pageViewStyle(.scroll)
    }
}

#endif
