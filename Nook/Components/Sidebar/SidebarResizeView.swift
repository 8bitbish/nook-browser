// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarResizeView.swift
//  Nook
//
//  Created by Maciek Bagiński on 30/07/2025.
//
//  The sidebar's resize edge. An AppKit view owns the cursor and the drag: it sits inside the
//  sidebar's last few points (the empty margin beside the rows), so the web page next to it never
//  covers it or resets the cursor, and the drag runs on mouse events, not a SwiftUI gesture.
//  While dragging only the window's state changes; the width is saved when the drag ends.
//

import AppKit
import OSLog
import SwiftUI
import NookDesign
import NookWeb
import NookUI

struct SidebarResizeView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.nookSettings) var nookSettings
    @State private var isResizing = false
    @State private var isHovering = false
    @State private var startingWidth: CGFloat = 0
    @StateObject private var dragLockManager = DragLockManager.shared
    @State private var dragSessionID: String = UUID().uuidString

    private let minWidth = NookDesign.Size.sidebarMin
    private let maxWidth: CGFloat = 520
    private let defaultWidth: CGFloat = 250
    /// Width of the grab area, all of it inside the sidebar.
    private let handleWidth: CGFloat = 8

    private var sitsOnRight: Bool {
        nookSettings.sidebarPosition == .right
    }

    var body: some View {
        ZStack(alignment: sitsOnRight ? .leading : .trailing) {
            if isHovering || isResizing {
                Capsule()
                    .fill(Color.secondary)
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 30)
                    .transition(.opacity)
            }
            SidebarResizeHandle(
                onHover: { hovering in
                    guard windowState.isSidebarVisible else { return }
                    withAnimation(NookDesign.Motion.quick) { isHovering = hovering }
                },
                onBegin: {
                    guard windowState.isSidebarVisible, dragLockManager.startDrag(ownerID: dragSessionID) else { return false }
                    startingWidth = windowState.sidebarWidth
                    isResizing = true
                    return true
                },
                onDrag: { movement in
                    let width = startingWidth + (sitsOnRight ? -movement : movement)
                    browserManager.updateSidebarWidth(max(minWidth, min(maxWidth, width)), for: windowState, live: true)
                },
                onEnd: {
                    isResizing = false
                    dragLockManager.endDrag(ownerID: dragSessionID)
                    browserManager.updateSidebarWidth(windowState.sidebarWidth, for: windowState)
                },
                onDoubleClick: {
                    guard windowState.isSidebarVisible else { return }
                    withAnimation(NookDesign.Motion.spring) {
                        browserManager.updateSidebarWidth(defaultWidth, for: windowState)
                    }
                }
            )
            .frame(width: handleWidth)
            .padding(.vertical, 30)
        }
        .frame(width: handleWidth)
        .onReceive(DistributedNotificationCenter.default().publisher(for: Self.testNotification)) { note in
            playTestResize(points: CGFloat(Double(note.object as? String ?? "120") ?? 120))
        }
    }

    // MARK: - Test driver

    /// With `-NookSwipeTestDriver YES`, the distributed notification `com.gstudios.nook.testResize`
    /// (object: points) plays a one-second drag through the same calls the handle makes, and logs
    /// the longest main-thread gap and the width saved at the end.
    private static let testNotification = Notification.Name("com.gstudios.nook.testResize")
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "SidebarResize")

    private func playTestResize(points: CGFloat) {
        guard UserDefaults.standard.bool(forKey: "NookSwipeTestDriver"), windowState.isSidebarVisible,
              dragLockManager.startDrag(ownerID: dragSessionID) else { return }
        startingWidth = windowState.sidebarWidth
        isResizing = true
        let start = ProcessInfo.processInfo.systemUptime
        var last = start
        var worst: TimeInterval = 0
        var frames = 0
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { timer in
            MainActor.assumeIsolated {
                let now = ProcessInfo.processInfo.systemUptime
                worst = max(worst, now - last)
                last = now
                frames += 1
                let t = min((now - start) / 1.0, 1)
                // Out and back, so the drag ends where it started plus `points`.
                let movement = points * CGFloat(t < 0.5 ? t * 2 : 1)
                let width = startingWidth + (sitsOnRight ? -movement : movement)
                browserManager.updateSidebarWidth(max(minWidth, min(maxWidth, width)), for: windowState, live: true)
                guard t >= 1 else { return }
                timer.invalidate()
                isResizing = false
                dragLockManager.endDrag(ownerID: dragSessionID)
                browserManager.updateSidebarWidth(windowState.sidebarWidth, for: windowState)
                Self.log.notice("test resize: \(frames, privacy: .public) steps, longest main-thread gap \(Int(worst * 1000), privacy: .public)ms, width \(Int(windowState.sidebarWidth), privacy: .public), saved \(UserDefaults.standard.double(forKey: "sidebarWidth"), privacy: .public)")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// The grab area: resize cursor whenever the pointer is over it, and the drag from mouse events.
private struct SidebarResizeHandle: NSViewRepresentable {
    var onHover: (Bool) -> Void
    /// Returns false when the drag may not start (another drag holds the lock).
    var onBegin: () -> Bool
    /// The pointer's horizontal movement since the press, in points.
    var onDrag: (CGFloat) -> Void
    var onEnd: () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        update(view)
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        update(view)
    }

    private func update(_ view: HandleView) {
        view.onHover = onHover
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.onDoubleClick = onDoubleClick
    }

    final class HandleView: NSView {
        var onHover: (Bool) -> Void = { _ in }
        var onBegin: () -> Bool = { false }
        var onDrag: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onDoubleClick: () -> Void = {}
        private var startX: CGFloat?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeInActiveApp, .inVisibleRect],
                owner: self))
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func cursorUpdate(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseEntered(with event: NSEvent) {
            onHover(true)
        }

        override func mouseExited(with event: NSEvent) {
            if startX == nil { onHover(false) }
        }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick()
                return
            }
            guard onBegin() else { return }
            startX = NSEvent.mouseLocation.x
            NSCursor.resizeLeftRight.set()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            onDrag(NSEvent.mouseLocation.x - startX)
            // The pointer may run ahead of the edge over the page, which sets its own cursor.
            NSCursor.resizeLeftRight.set()
        }

        override func mouseUp(with event: NSEvent) {
            guard startX != nil else { return }
            startX = nil
            onEnd()
            let inside = bounds.contains(convert(event.locationInWindow, from: nil))
            if !inside { onHover(false); NSCursor.arrow.set() }
        }
    }
}
