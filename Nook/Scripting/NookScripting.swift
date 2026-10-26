// Licensed under GPL-3.0. See LICENSE.
//
//  NookScripting.swift
//  Nook
//
//  Personal build: the Cocoa Scripting side of Nook.sdef. Read-only windows and tabs, so
//  `tell application "Nook" to get {title, URL} of active tab of front window` works.
//

import AppKit
import NookTabsCore
import NookWeb

enum NookScripting {
    /// Set once at launch (NookApp.setupApplicationLifecycle). Apple events arrive on the main thread.
    static weak var browserManager: BrowserManager?

    @MainActor
    static func windowState(for window: NSWindow) -> BrowserWindowState? {
        browserManager?.windowRegistry?.allWindows.first { $0.window === window }
    }
}

/// A snapshot of one tab, taken when the script asks. Holds no live references.
@objc(NookScriptTab)
final class NookScriptTab: NSObject {
    @objc let uniqueID: String
    @objc let title: String
    @objc let urlString: String
    @objc let isLoading: Bool
    private weak var container: NSWindow?

    init(id: UUID, title: String, url: URL?, isLoading: Bool, container: NSWindow) {
        self.uniqueID = id.uuidString
        self.title = title
        self.urlString = url?.absoluteString ?? ""
        self.isLoading = isLoading
        self.container = container
    }

    @MainActor
    static func make(itemID: UUID, in window: NSWindow, manager: BrowserManager) -> NookScriptTab? {
        let session = manager.tabs.session(for: itemID)
        let item = manager.tabs.item(itemID)
        guard session != nil || item != nil else { return nil }
        let title = session?.title.isEmpty == false ? session!.title : (item?.displayTitle ?? "")
        return NookScriptTab(
            id: itemID, title: title, url: session?.url ?? item?.url,
            isLoading: session?.isLoading ?? false, container: window)
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let container,
              let containerSpecifier = container.objectSpecifier,
              let containerDescription = containerSpecifier.keyClassDescription
        else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: containerDescription, containerSpecifier: containerSpecifier,
            key: "nookScriptTabs", uniqueID: uniqueID)
    }
}

extension NSWindow {
    /// The window's space in sidebar order: favorites, then pinned and regular tabs. Empty for
    /// windows that are not browser windows (settings, panels).
    @objc var nookScriptTabs: [NookScriptTab] {
        MainActor.assumeIsolated {
            guard let manager = NookScripting.browserManager,
                  let state = NookScripting.windowState(for: self) else { return [] }
            return manager.tabs.displayOrder(in: state).compactMap {
                NookScriptTab.make(itemID: $0, in: self, manager: manager)
            }
        }
    }

    @objc var nookScriptActiveTab: NookScriptTab? {
        MainActor.assumeIsolated {
            guard let manager = NookScripting.browserManager,
                  let state = NookScripting.windowState(for: self),
                  let itemID = state.selectedItemID else { return nil }
            return NookScriptTab.make(itemID: itemID, in: self, manager: manager)
        }
    }

    @objc func valueInNookScriptTabsWithUniqueID(_ uniqueID: String) -> NookScriptTab? {
        nookScriptTabs.first { $0.uniqueID == uniqueID } ?? nookScriptActiveTab.flatMap { $0.uniqueID == uniqueID ? $0 : nil }
    }
}
