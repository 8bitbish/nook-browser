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
        func select(_ value: SelectionValue, deferred: Bool = false) {
            current = value
            guard deferred else { parent.selection = value; return }
            // On the next turn, after the frame that starts the settle has been committed.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.current == value else { return }
                self.parent.selection = value
            }
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
                completion: completion)
        }

        /// Share of the width a drag must pass to commit without a flick.
        private static var dragThreshold: CGFloat { 0.3 }
        /// Peak speed, in widths per second, at which a release commits however short it was.
        private static var flickSpeed: CGFloat { 0.4 }
        /// Shortest flick that counts: below this the fingers barely moved.
        private static var flickDistance: CGFloat { 0.015 }

        /// How far the page goes for a gesture amount: 85% of the finger at the start, easing to
        /// 1:1 at a full width, so the swipe has weight without ever lagging behind at the end.
        private static func travel(_ amount: CGFloat) -> CGFloat {
            amount * (0.85 + 0.15 * min(abs(amount), 1))
        }

        /// Ends a settle still under way at once, so the next swipe starts from a page at rest.
        func finishSettle() {
            guard let pending = pendingSettle else { return }
            pendingSettle = nil
            settleID += 1
            for view in subviews { view.layer?.removeAnimation(forKey: Self.settleKey) }
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
            // Fastest the fingers moved each way: a flick slows as it lifts, so its end speed
            // undersold it and short quick flicks sprang back.
            var peakForward: CGFloat = 0
            var peakBack: CGFloat = 0
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
                    let speed = Self.velocity(samples)
                    peakForward = max(peakForward, -speed)
                    peakBack = max(peakBack, speed)
                    // The page trails the fingers a little, more at the start: the swipe has weight.
                    let travel = Self.travel(amount)
                    self.setOffset(travel * width, page: page, incoming: target?.view, forward: target?.forward ?? forward)
                    coordinator.report(target?.value, target?.forward == forward ? abs(travel) : 0,
                                       forward: target?.forward ?? forward)
                    if !playedHaptic, abs(amount) > 0.15 {
                        playedHaptic = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                case .ended, .cancelled:
                    // Take over from the system's momentum with a short spring of our own.
                    self.isTracking = false
                    let velocity = Self.velocity(samples)
                    // A flick commits however short it was, on its peak speed; a slow drag needs
                    // to pass a third of the way.
                    let commits = phase == .ended && target.map {
                        let peak = $0.forward ? peakForward : peakBack
                        return $0.forward == (amount < 0)
                            && (abs(amount) > Self.dragThreshold
                                || (peak >= Self.flickSpeed && abs(amount) >= Self.flickDistance))
                    } == true
                    Self.log.notice("swipe ended +\(elapsed, privacy: .public)ms amount \(String(format: "%.2f", amount), privacy: .public) velocity \(String(format: "%.1f", velocity), privacy: .public)/s peak \(String(format: "%.1f", max(peakForward, peakBack)), privacy: .public)/s steps \(steps, privacy: .public) \(commits ? "commit" : "cancel", privacy: .public)")
                    if let target, commits {
                        // Carries the finger's speed into the spring, so a flick keeps going.
                        let remaining = max(1 - abs(Self.travel(amount)), 0.05)
                        let speed = max(abs(velocity), target.forward ? peakForward : peakBack)
                        let springVelocity = min(speed / remaining, 30)
                        let animation = Animation.interpolatingSpring(
                            duration: NookDesign.Motion.spaceSettleDuration,
                            bounce: NookDesign.Motion.spaceSettleBounce, initialVelocity: springVelocity)
                        // The window's page and colour follow first, then the sidebar's spring.
                        coordinator.report(target.value, 1, forward: target.forward, animation: animation)
                        let released = ProcessInfo.processInfo.systemUptime
                        self.run(to: target.forward ? -width : width, page: page, incoming: target.view,
                                 forward: target.forward, velocity: springVelocity) {
                            Self.log.notice("swipe settled \(Int((ProcessInfo.processInfo.systemUptime - released) * 1000), privacy: .public)ms after release")
                            coordinator.show(target.value)
                            coordinator.report(nil, 0)
                        }
                        // Hands the spring and the page swap to Core Animation now: the selection
                        // below runs the space change on the main thread, and in the same turn it
                        // held the spring's first frame back until it was done.
                        CATransaction.flush()
                        coordinator.select(target.value, deferred: true)
                    } else {
                        let incoming = target?.view
                        coordinator.report(target?.value, 0, forward: target?.forward ?? true, animation: Self.settle)
                        self.run(to: 0, page: page, incoming: incoming, forward: target?.forward ?? true) {
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
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
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
            RunLoop.main.add(timer, forMode: .common)
        }

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

        /// Settles the pages with a Core Animation spring. The frames take their final values at
        /// once and the layers' positions animate in the render server, so nothing the main
        /// thread does meanwhile (the space change re-rendering the window) can stall the motion.
        /// `velocity` is the finger's speed as a share of the remaining distance per second.
        private func run(to offset: CGFloat, page: NSView, incoming: NSView?, forward: Bool,
                         velocity: CGFloat = 0, completion: @escaping () -> Void) {
            let width = bounds.width
            settleID += 1
            let id = settleID
            Self.measureHitches()
            pendingSettle = completion
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    guard self.settleID == id, let pending = self.pendingSettle else { return }
                    self.pendingSettle = nil
                    pending()
                }
            }
            let moves: [(NSView, NSRect)] = [(page, bounds.offsetBy(dx: offset, dy: 0))]
                + (incoming.map { [($0, bounds.offsetBy(dx: offset + (forward ? width : -width), dy: 0))] } ?? [])
            for (view, frame) in moves {
                guard let layer = view.layer else { view.frame = frame; continue }
                let from = layer.presentation()?.position ?? layer.position
                view.frame = frame
                let to = layer.position
                guard from != to else { continue }
                let spring = CASpringAnimation(perceptualDuration: NookDesign.Motion.spaceSettleDuration,
                                               bounce: NookDesign.Motion.spaceSettleBounce)
                spring.keyPath = "position"
                spring.fromValue = NSValue(point: from)
                spring.toValue = NSValue(point: to)
                spring.initialVelocity = velocity
                spring.duration = spring.settlingDuration
                layer.add(spring, forKey: Self.settleKey)
            }
            CATransaction.commit()
        }

        private static var settleKey: String { "nook.pageSettle" }

        /// Logs the longest main-thread gap over the first half second of a settle: the main
        /// thread draws the window's colour and the sidebar's SwiftUI content, so a gap there is a
        /// visible hitch. A timer only while the settle runs, nothing at rest.
        private static func measureHitches() {
            let start = ProcessInfo.processInfo.systemUptime
            var last = start
            var worst: TimeInterval = 0
            var worstAt: TimeInterval = 0
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
                let now = ProcessInfo.processInfo.systemUptime
                if now - last > worst { worst = now - last; worstAt = last - start }
                last = now
                guard now - start >= 0.5 else { return }
                timer.invalidate()
                log.notice("settle hitch: longest main-thread gap \(Int(worst * 1000), privacy: .public)ms at +\(Int(worstAt * 1000), privacy: .public)ms")
            }
            // Common modes, so time spent tracking a gesture does not read as a stall.
            RunLoop.main.add(timer, forMode: .common)
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
