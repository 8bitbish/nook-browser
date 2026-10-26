// Licensed under GPL-3.0. See LICENSE.
//
//  ExtensionManager+ClickDriver.swift
//  Nook
//
//  Hands-off check of every extension's toolbar button: launched with
//  `-NookExtensionClickDriver YES`, clicks each enabled extension in turn through the same path
//  the toolbar and library use, and logs what WebKit asked the browser to do.
//

import AppKit
import Foundation
import os
import WebKit
import NookWeb

extension ExtensionManager {

    private static let clickLogger = Logger(subsystem: "com.nook.browser", category: "ExtensionClickDriver")

    func runClickDriverIfRequested() {
        guard UserDefaults.standard.bool(forKey: "NookExtensionClickDriver") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            let only = UserDefaults.standard.string(forKey: "NookExtensionClickDriverOnly")
            let contexts = extensionContexts
                .filter { only == nil || $0.key == only }
                .sorted { ($0.value.webExtension.displayName ?? "") < ($1.value.webExtension.displayName ?? "") }
            Self.clickLogger.notice("driver: \(contexts.count, privacy: .public) extensions")
            var testItem: UUID?
            if let page = UserDefaults.standard.string(forKey: "NookExtensionClickDriverURL").flatMap(URL.init(string:)),
               let window = browserManagerRef?.windowRegistry?.allWindows.first {
                testItem = browserManagerRef?.tabs.selectedItemID(in: window)
                browserManagerRef?.tabs.selectedSession(in: window)?.load(page)
                try? await Task.sleep(for: .seconds(5))
            }
            for (id, context) in contexts {
                guard let window = browserManagerRef?.windowRegistry?.activeWindow
                    ?? browserManagerRef?.windowRegistry?.allWindows.first
                else {
                    Self.clickLogger.error("driver: no window")
                    return
                }
                let name = context.webExtension.displayName ?? id
                // An extension that opened a tab moved the selection; click on the test page again.
                if let testItem, browserManagerRef?.tabs.selectedItemID(in: window) != testItem {
                    browserManagerRef?.tabs.select(testItem, in: window)
                    try? await Task.sleep(for: .seconds(1))
                }
                let action = context.action(for: actionAdapter(in: window))
                let before = await pageState(in: window)
                clickAction(extensionId: id, in: window, from: "Driver")
                try? await Task.sleep(for: .seconds(4))
                let after = await pageState(in: window)
                Self.clickLogger.notice("driver: page '\(name, privacy: .public)' before=\(before, privacy: .public) after=\(after, privacy: .public)")
                let shown = shownPopover?.isShown ?? false
                Self.clickLogger.notice("driver: after '\(name, privacy: .public)' popoverShown=\(shown, privacy: .public)")
                if shown {
                    // Window numbers so a `screencapture -l` from outside can photograph it.
                    let popupWindow = shownPopover?.contentViewController?.view.window?.windowNumber ?? 0
                    Self.clickLogger.notice("driver: hold '\(name, privacy: .public)' popupWindow=\(popupWindow, privacy: .public) browserWindow=\(window.window?.windowNumber ?? 0, privacy: .public)")
                    try? await Task.sleep(for: .seconds(4))
                    action?.closePopup(); shownPopover?.close()
                } else {
                    Self.clickLogger.notice("driver: hold '\(name, privacy: .public)' browserWindow=\(window.window?.windowNumber ?? 0, privacy: .public)")
                    try? await Task.sleep(for: .seconds(2))
                }
                try? await Task.sleep(for: .seconds(1))
            }
            Self.clickLogger.notice("driver: done")
        }
    }

    /// Element count and URL of the window's selected page, to see whether a click changed it.
    private func pageState(in window: BrowserWindowState) async -> String {
        guard let session = browserManagerRef?.tabs.selectedSession(in: window), let webView = session.webView else { return "no page" }
        let count = (try? await webView.evaluateJavaScript("document.querySelectorAll('*').length")) as? Int
        return "\(session.url.host ?? session.url.scheme ?? "?") elements=\(count.map(String.init) ?? "?")"
    }
}
