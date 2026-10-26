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

        /// Share of the width a drag must pass to commit without a flick: Arc's quarter.
        private static var dragThreshold: CGFloat { 0.25 }
        /// Peak speed, in widths per second, at which a release commits however short it was.
        /// From Jake's flicks that sprang back: peaks of 0.7 to 3.9 over 2-24% of the width.
        private static var flickSpeed: CGFloat { 0.35 }
        /// Shortest flick that counts, about 5 pt: below this the fingers barely moved.
        private static var flickDistance: CGFloat { 0.02 }
        /// Longest gesture, in seconds, that counts as a flick on its peak speed alone.
        private static var flickDuration: TimeInterval { 0.3 }

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

        // MARK: - Trackpad

        /// The swipe under way, fed from raw scroll events. AppKit's `trackSwipeEvent` judged
        /// each gesture by its own thresholds first: short or quick swipes came back cancelled,
        /// and a swipe right after another often arrived with no movement at all, so tiny
        /// flicks and swipes in a row went nowhere whatever Nook's own rules said.
        private var gesture: (hasPrevious: Bool, hasNext: Bool, step: (CGFloat, NSEvent.Phase) -> Bool)?
        /// The fingers' travel to the right so far, in points.
        private var travelX: CGFloat = 0
        /// A gesture whose direction is not known yet, and the events it has sent so far, so a
        /// vertical one can still go to the tab list's scroll view whole.
        private var undecided: [NSEvent] = []
        private var undecidedX: CGFloat = 0
        private var undecidedY: CGFloat = 0

        /// Takes the rest of a gesture straight from the event stream once its first event has
        /// reached the pager, so the swipe sees every movement however AppKit routes the later
        /// events (over the tab list's scroll view, or after the pointer leaves the sidebar).
        private var gestureMonitor: Any?

        override func scrollWheel(with event: NSEvent) {
            guard event.phase == .began, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else {
                return super.scrollWheel(with: event)
            }
            endGesture()
            let (x, y) = Self.fingers(event)
            undecided = [event]
            undecidedX = x
            undecidedY = y
            stopMonitor()
            monitorToken += 1
            let token = monitorToken
            gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated {
                    // A monitor being retired lets everything through until it is removed.
                    guard let self, self.monitorToken == token else { return event }
                    return self.capture(event) ? nil : event
                }
            }
        }

        /// One event of the captured gesture. Returns true when the swipe took it.
        private func capture(_ event: NSEvent) -> Bool {
            guard event.momentumPhase.isEmpty else { return false }
            let (x, y) = Self.fingers(event)
            switch event.phase {
            case .changed where gesture != nil:
                travelX += x
                _ = gesture?.step(amount(for: travelX), .changed)
                return true
            case .changed where !undecided.isEmpty:
                undecided.append(event)
                undecidedX += x
                undecidedY += y
                // Decided after a few points of movement, by the axis that moved more.
                guard hypot(undecidedX, undecidedY) >= Self.axisDecision else { return true }
                let events = undecided
                undecided = []
                Self.log.notice("gesture axis: \(abs(self.undecidedX) > abs(self.undecidedY) ? "horizontal" : "vertical", privacy: .public) x \(Int(self.undecidedX), privacy: .public) y \(Int(self.undecidedY), privacy: .public) after \(events.count, privacy: .public) events")
                if abs(undecidedX) > abs(undecidedY), NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                   let swipe = beginSwipe() {
                    gesture = swipe
                    travelX = undecidedX
                    _ = swipe.step(amount(for: travelX), .began)
                    return true
                }
                // Not a swipe: the rest goes on as ordinary scrolling. The few points held back
                // are dropped rather than replayed from inside the monitor.
                stopMonitor()
                return false
            case .ended, .cancelled:
                stopMonitor()
                if let swipe = gesture {
                    // The amount first: it reads which sides are open from the gesture.
                    let final = amount(for: travelX)
                    gesture = nil
                    _ = swipe.step(final, .ended)
                    return true
                }
                // Barely moved: an accidental touch, not a swipe.
                undecided = []
                return false
            case .began:
                // A new gesture before this one ended: it starts over from the pager.
                endGesture()
                stopMonitor()
                undecided = []
                return false
            default:
                return gesture != nil || !undecided.isEmpty
            }
        }

        /// Retires the gesture monitor. It is switched off at once (its token goes stale) and
        /// removed on the next turn: this often runs inside the monitor's own handler, and
        /// removing a monitor while AppKit runs its monitors raised an exception that AppKit
        /// swallowed mid-way through a Swift frame, leaving the main actor's executor state
        /// corrupt until SwiftUI next checked it (a crash on scroll, 19:39 on 8cf339b7).
        private func stopMonitor() {
            monitorToken += 1
            guard let monitor = gestureMonitor else { return }
            gestureMonitor = nil
            DispatchQueue.main.async { NSEvent.removeMonitor(monitor) }
        }

        /// Identifies the live gesture monitor; a handler with an older token passes events on.
        private var monitorToken = 0

        /// The fingers' movement in points, x positive to the right, whichever way the
        /// scrolling direction setting points: right drags the page toward the previous space.
        private static func fingers(_ event: NSEvent) -> (CGFloat, CGFloat) {
            let x = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            return (x, event.scrollingDeltaY)
        }

        /// A swipe left hanging (a new gesture began without the last one ending) ends here.
        private func endGesture() {
            guard let swipe = gesture else { return }
            let final = amount(for: travelX)
            gesture = nil
            _ = swipe.step(final, .ended)
        }

        /// Points of movement before a gesture's axis is decided.
        private static var axisDecision: CGFloat { 3 }

        /// The gesture amount for the fingers' travel: a share of the width, positive toward the
        /// previous space, at most one page either way. Toward a side with no space it is damped
        /// to a short rubber band.
        private func amount(for travel: CGFloat) -> CGFloat {
            let raw = travel / max(bounds.width, 1)
            let open = raw > 0 ? (gesture?.hasPrevious ?? false) : (gesture?.hasNext ?? false)
            guard open else {
                let band = Self.rubberBand * (1 - exp(-abs(raw) * 4))
                return raw > 0 ? band : -band
            }
            return min(max(raw, -1), 1)
        }

        /// Furthest the page moves past the first or last space, as a share of the width.
        private static var rubberBand: CGFloat { 0.12 }

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
                    // A flick is quick: still moving fast as it lifts, or short and fast at its
                    // peak. A slow drag that stops short is not one, however it started.
                    let quick = Double(elapsed) / 1000 <= Self.flickDuration
                    let commits = phase == .ended && target.map {
                        let peak = $0.forward ? peakForward : peakBack
                        let release = $0.forward ? -velocity : velocity
                        let flick = abs(amount) >= Self.flickDistance
                            && (release >= Self.flickSpeed || (quick && peak >= Self.flickSpeed))
                        return $0.forward == (amount < 0) && (abs(amount) > Self.dragThreshold || flick)
                    } == true
                    Self.log.notice("swipe ended +\(elapsed, privacy: .public)ms amount \(String(format: "%.2f", amount), privacy: .public) velocity \(String(format: "%.1f", velocity), privacy: .public)/s peak \(String(format: "%.1f", max(peakForward, peakBack)), privacy: .public)/s fingers \(Int(self.travelX), privacy: .public)pt of \(Int(width), privacy: .public) steps \(steps, privacy: .public) \(commits ? "commit" : "cancel", privacy: .public)")
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
        private var scrollObserver: NSObjectProtocol?

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
            scrollObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.gstudios.nook.testScroll"), object: nil, queue: .main
            ) { [weak self] note in
                let parts = (note.object as? String ?? "-40,100").split(separator: ",").compactMap { Double($0) }
                MainActor.assumeIsolated {
                    self?.playTestScroll(dx: CGFloat(parts.first ?? -40), dy: CGFloat(parts.count > 2 ? parts[2] : 0),
                                         duration: (parts.count > 1 ? parts[1] : 100) / 1000)
                }
            }
        }

        /// Plays one trackpad gesture as real scroll events through the app's event queue, so the
        /// test covers dispatch, the gesture monitor and the handler: notification
        /// `com.gstudios.nook.testScroll`, object "<points right>,<ms>[,<points down>]".
        private func playTestScroll(dx: CGFloat, dy: CGFloat, duration: TimeInterval) {
            guard let window else { return }
            let point = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            let steps = max(Int(duration / 0.008), 1)
            var sent = 0
            func post(_ x: CGFloat, _ y: CGFloat, phase: Int64) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                       wheel1: Int32(y.rounded()), wheel2: Int32(x.rounded()), wheel3: 0) else { return }
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
                cg.location = CGPoint(x: window.frame.minX + point.x,
                                      y: (NSScreen.screens.first?.frame.height ?? 0) - (window.frame.minY + point.y))
                guard let event = NSEvent(cgEvent: cg) else { return }
                if phase == 1 {
                    Self.log.notice("test scroll: \(Int(dx), privacy: .public) pt right, \(Int(dy), privacy: .public) pt down over \(Int(duration * 1000), privacy: .public) ms")
                }
                if phase == 1 {
                    // A real gesture's first event reaches the pager by hit testing; the rest
                    // go through the app's queue, where only the gesture monitor can catch them.
                    scrollWheel(with: event)
                } else {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            // Scroll deltas point the way the content moves: -dx for fingers moving right. Deltas
            // are whole points, so each step carries the rounding left by the last.
            post(0, 0, phase: 1)
            var postedX: CGFloat = 0
            var postedY: CGFloat = 0
            Timer.scheduledTimer(withTimeInterval: 0.008, repeats: true) { timer in
                MainActor.assumeIsolated {
                    sent += 1
                    let share = CGFloat(sent) / CGFloat(steps)
                    let x = (-dx * share).rounded() - postedX
                    let y = (dy * share).rounded() - postedY
                    postedX += x
                    postedY += y
                    post(x, y, phase: 2)
                    if sent >= steps { timer.invalidate(); post(0, 0, phase: 4) }
                }
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
            // Events can arrive in pairs a fraction of a millisecond apart; a span shorter than
            // about a frame would read as an absurd speed.
            guard let first = samples.first, let last = samples.last, last.time - first.time >= 0.012 else { return 0 }
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
