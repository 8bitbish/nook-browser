// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceBackdropView.swift
//  Nook
//
//  The window's colour, drawn by Core Animation. A sidebar swipe blends in the colour of the
//  space it heads for as far as it has gone and settles with a spring that carries the finger's
//  speed; any other space change cross-fades. Swipe steps arrive straight from `BrowserManager`
//  and animations run in the render server, so the colour never waits on SwiftUI or on the main
//  thread (a SwiftUI animation here froze, then jumped, while a space change re-rendered the
//  window).
//

import AppKit
import SwiftUI
import NookDesign
import NookWeb

/// SwiftUI host: hands the view the window's space and active state, and registers it for
/// swipe steps.
struct SpaceBackdropLayer: NSViewRepresentable {
    let browserManager: BrowserManager
    let window: BrowserWindowState
    let isActive: Bool
    let accent: (UUID?) -> Color

    func makeNSView(context: Context) -> SpaceBackdropView {
        let view = SpaceBackdropView()
        view.accent = { NSColor(accent($0)) }
        view.show(spaceID: window.spaceID, isActive: isActive)
        browserManager.registerSpaceBackdrop(view, for: window.id)
        return view
    }

    func updateNSView(_ view: SpaceBackdropView, context: Context) {
        view.accent = { NSColor(accent($0)) }
        view.show(spaceID: window.spaceID, isActive: isActive)
    }
}

@MainActor
final class SpaceBackdropView: NSView {
    /// A space's accent in this window.
    var accent: (UUID?) -> NSColor = { _ in .windowBackgroundColor }

    private let base = CAGradientLayer()
    /// The colour being blended in: a swipe's target, or the new space of a cross-fade.
    private let top = CAGradientLayer()

    /// The space `base` shows.
    private var baseSpace: UUID?
    /// The space the window shows; differs from `baseSpace` until a blend has finished.
    private var spaceID: UUID?
    private var topSpace: UUID?
    private var isActive = true

    private var swipeTarget: UUID?
    private var committedTarget: UUID?
    private var samples: [(fraction: CGFloat, time: TimeInterval)] = []
    private var fraction: CGFloat = 0
    private var blendID = 0

    private static let blendKey = "nook.spaceBlend"
    /// `spaceSettle`'s response; the sidebar pager settles with the same spring.
    private static let settleDuration: TimeInterval = 0.3

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for gradient in [base, top] {
            // Top of the window to its bottom; a backing layer's unit space starts at the bottom.
            gradient.startPoint = CGPoint(x: 0.5, y: 1)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            layer?.addSublayer(gradient)
        }
        top.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        withoutActions {
            base.frame = bounds
            top.frame = bounds
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        withoutActions { recolour() }
    }

    // MARK: - From SwiftUI

    func show(spaceID: UUID?, isActive: Bool) {
        if isActive != self.isActive {
            self.isActive = isActive
            CATransaction.begin()
            CATransaction.setAnimationDuration(NookDesign.Motion.standardDuration)
            recolour()
            CATransaction.commit()
        }
        guard spaceID != self.spaceID else { return }
        let previous = self.spaceID
        self.spaceID = spaceID
        // First show, or a swipe already blending toward it: nothing to fade.
        guard previous != nil else {
            baseSpace = spaceID
            withoutActions { recolour() }
            return
        }
        if committedTarget == spaceID || swipeTarget == spaceID { return }
        crossFade(to: spaceID)
    }

    // MARK: - From the swipe

    /// One swipe step: `release` is nil while the fingers move, true when the swipe commits to
    /// `target`, false when it springs back.
    func swipe(to target: UUID, fraction: CGFloat, release: Bool?) {
        if swipeTarget != target {
            settleBlend()
            swipeTarget = target
            committedTarget = nil
            samples = []
            topSpace = target
            withoutActions {
                top.colors = colours(for: target)
                top.opacity = 0
            }
        }
        switch release {
        case nil:
            samples.append((fraction, ProcessInfo.processInfo.systemUptime))
            if samples.count > 4 { samples.removeFirst() }
            self.fraction = fraction
            top.removeAnimation(forKey: Self.blendKey)
            withoutActions { top.opacity = Float(fraction) }
        case true?:
            committedTarget = target
            animateTop(to: 1, velocity: velocity(toward: 1)) { [weak self] in self?.settleBlend() }
        case false?:
            animateTop(to: 0, velocity: velocity(toward: 0)) { [weak self] in self?.settleBlend() }
        }
    }

    /// The swipe is over (its settle ended, or the next swipe cut it short).
    func endSwipe() {
        settleBlend()
    }

    // MARK: - Blending

    private func crossFade(to spaceID: UUID?) {
        settleBlend()
        topSpace = spaceID
        withoutActions {
            top.colors = colours(for: spaceID)
            top.opacity = 0
        }
        animateTop(to: 1, velocity: 0) { [weak self] in self?.settleBlend() }
    }

    private func animateTop(to opacity: Float, velocity: CGFloat, completion: @escaping () -> Void) {
        blendID += 1
        let id = blendID
        let from = top.presentation()?.opacity ?? top.opacity
        let spring = CASpringAnimation(perceptualDuration: Self.settleDuration, bounce: 0)
        spring.keyPath = "opacity"
        spring.fromValue = from
        spring.toValue = opacity
        spring.initialVelocity = velocity
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.blendID == id else { return }
                completion()
            }
        }
        top.opacity = opacity
        top.add(spring, forKey: Self.blendKey)
        CATransaction.commit()
    }

    /// Ends any blend in one step: `base` takes the colour on screen, `top` goes clear.
    private func settleBlend() {
        blendID += 1
        let shown: UUID?
        if top.opacity >= 1 || committedTarget != nil {
            shown = topSpace
        } else {
            shown = baseSpace
        }
        withoutActions {
            top.removeAnimation(forKey: Self.blendKey)
            baseSpace = shown
            base.colors = colours(for: shown)
            top.opacity = 0
        }
        swipeTarget = nil
        committedTarget = nil
        samples = []
        // The window moved on while the blend ran (a click during a swipe): catch up.
        if spaceID != baseSpace, spaceID != nil { crossFade(to: spaceID) }
    }

    private func recolour() {
        base.colors = colours(for: baseSpace)
        top.colors = colours(for: topSpace)
    }

    /// `NookDesign.Surface.containerGradient` in Core Animation: the accent blended toward the
    /// window background at the top, the window background at the bottom.
    private func colours(for spaceID: UUID?) -> [CGColor] {
        let accent = self.accent(spaceID)
        let topBlend = isActive ? 0.55 : 0.8
        var result: [CGColor] = []
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let topColour = accent.blended(withFraction: topBlend, of: .windowBackgroundColor) ?? accent
            result = [topColour.cgColor, NSColor.windowBackgroundColor.cgColor]
        }
        return result
    }

    /// The fingers' speed as a share of the distance left, per second.
    private func velocity(toward target: CGFloat) -> CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        let speed = (last.fraction - first.fraction) / (last.time - first.time)
        let remaining = max(abs(target - fraction), 0.05)
        // Only speed toward the target carries over.
        let toward = (target - fraction) >= 0 ? speed : -speed
        return min(max(toward, 0) / remaining, 30)
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
