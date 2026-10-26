#if canImport(AppKit)

import SwiftUI
import NookDesign

// Nook: a trackpad pager of its own instead of NSPageController. The system pager eases each
// swipe out with its own momentum after the fingers lift; here the lift hands off to a short
// spring. Progress goes out through `onPageTransition` so the window's colour can follow it.
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

        func report(_ target: SelectionValue?, _ fraction: CGFloat, animation: Animation? = nil) {
            onTransition?(PageTransition(target: target.map(AnyHashable.init), fraction: fraction, animation: animation))
        }

        func commit(_ value: SelectionValue) {
            show(value)
            parent.selection = value
        }
    }

    // MARK: - Views

    final class SwipePagerView: NSView {
        weak var coordinator: Coordinator?
        private var page: HostingView?
        private var incoming: HostingView?
        private var isTracking = false

        /// The settle after the fingers lift, and a programmatic page change.
        static var settle: Animation { NookDesign.Motion.spaceSettle }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
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
            if !isTracking { page?.frame = bounds }
        }

        /// A programmatic change: the new page slides in from its side.
        func animate(to view: HostingView, forward: Bool, completion: @escaping () -> Void) {
            guard let page, !isTracking else { return completion() }
            place(view)
            setOffset(0, page: page, incoming: view, forward: forward)
            run(to: forward ? -bounds.width : bounds.width, page: page, incoming: view, forward: forward, completion: completion)
        }

        override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
            axis == .horizontal
        }

        override func scrollWheel(with event: NSEvent) {
            guard !isTracking,
                  event.phase == .began,
                  event.hasPreciseScrollingDeltas,
                  NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                  let coordinator, let page
            else { return super.scrollWheel(with: event) }

            let previous = coordinator.neighbour(forward: false)
            let next = coordinator.neighbour(forward: true)
            guard previous != nil || next != nil else { return super.scrollWheel(with: event) }

            isTracking = true
            var target: (value: SelectionValue, view: HostingView, forward: Bool)?
            var samples: [(amount: CGFloat, time: TimeInterval)] = []
            var playedHaptic = false
            let width = bounds.width

            // Positive amounts drag the page right, toward the previous space.
            event.trackSwipeEvent(
                options: [.lockDirection, .clampGestureAmount],
                dampenAmountThresholdMin: next == nil ? 0 : -1,
                max: previous == nil ? 0 : 1
            ) { [weak self] amount, phase, _, stop in
                guard let self else { stop.pointee = true; return }
                let forward = amount < 0
                if amount != 0, target?.forward != forward, let value = forward ? next : previous {
                    let view = coordinator.view(for: value)
                    target = (value, view, forward)
                    self.place(view)
                }

                switch phase {
                case .began, .changed:
                    samples.append((amount, ProcessInfo.processInfo.systemUptime))
                    if samples.count > 4 { samples.removeFirst() }
                    self.setOffset(amount * width, page: page, incoming: target?.view, forward: target?.forward ?? forward)
                    coordinator.report(target?.value, target?.forward == forward ? abs(amount) : 0)
                    if !playedHaptic, abs(amount) > 0.15 {
                        playedHaptic = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                case .ended, .cancelled:
                    // Take over from the system's momentum with a short animation of our own.
                    stop.pointee = true
                    let velocity = Self.velocity(samples)
                    let commits = phase == .ended && target.map {
                        $0.forward == (amount < 0)
                            && (abs(amount) > 0.3 || ($0.forward ? velocity < -0.8 : velocity > 0.8))
                    } == true
                    if let target, commits {
                        coordinator.report(target.value, 1, animation: Self.settle)
                        self.run(to: target.forward ? -width : width, page: page, incoming: target.view, forward: target.forward) {
                            self.isTracking = false
                            coordinator.commit(target.value)
                        }
                    } else {
                        let incoming = target?.view
                        coordinator.report(target?.value, 0, animation: Self.settle)
                        self.run(to: 0, page: page, incoming: incoming, forward: target?.forward ?? true) {
                            incoming?.removeFromSuperview()
                            self.incoming = nil
                            self.isTracking = false
                            page.frame = self.bounds
                            coordinator.report(nil, 0)
                        }
                    }
                default:
                    break
                }
            }
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

        private func run(to offset: CGFloat, page: NSView, incoming: NSView?, forward: Bool,
                         completion: @escaping () -> Void) {
            let width = bounds.width
            NSAnimationContext.animate(Self.settle) {
                page.animator().frame = bounds.offsetBy(dx: offset, dy: 0)
                incoming?.animator().frame = bounds.offsetBy(dx: offset + (forward ? width : -width), dy: 0)
            } completion: {
                MainActor.assumeIsolated { completion() }
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
