// Licensed under GPL-3.0. See LICENSE.
//
//  ExtensionPageDiagnostics.swift
//  NookWeb
//
//  An extension's own page open in a tab (a password manager's sign-in page) can fail without a
//  trace: its console is only reachable through Web Inspector. This logs that page's uncaught
//  errors, rejected promises and console.error lines to the `ExtensionPage` category, masked:
//  email addresses become <email>, URLs lose their query and fragment, messages are capped.
//  Installed only on views made from an extension context's configuration.
//

import Foundation
import OSLog
import WebKit

@MainActor
final class ExtensionPageDiagnostics: NSObject, WKScriptMessageHandler {
    static let handlerName = "nookExtensionPageLog"

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "ExtensionPage")
    /// Most lines one page may log, so a page stuck in an error loop cannot flood the log.
    private static let limit = 100

    private let page: String
    private var count = 0

    private init(page: String) {
        self.page = page
    }

    /// Adds the error hooks to `controller`. The handler is replaced, not added twice, since an
    /// extension's pages may share a content controller.
    static func install(on controller: WKUserContentController, page url: URL) {
        controller.removeScriptMessageHandler(forName: handlerName, contentWorld: .page)
        controller.add(ExtensionPageDiagnostics(page: url.lastPathComponent), contentWorld: .page, name: handlerName)
        // There is no removing one user script, so it is added only once per controller.
        let present = controller.userScripts.contains { $0.source.hasPrefix("// Nook: extension page diagnostics") }
        if !present {
            controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard count < Self.limit, let body = message.body as? [String: Any],
              let kind = body["kind"] as? String, let text = body["message"] as? String else { return }
        count += 1
        let masked = Self.mask(String(text.prefix(600)))
        Self.log.notice("\(self.page, privacy: .public) \(kind, privacy: .public): \(masked, privacy: .public)")
    }

    /// Email addresses out; URLs keep scheme, host and path only.
    static func mask(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, with: "<email>", options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"([a-z][a-z0-9+.-]*://[^\s?#"'<>]*)[?#][^\s"'<>]*"#, with: "$1?<query>", options: .regularExpression)
        return result
    }

    private static let script = """
        // Nook: extension page diagnostics
        (() => {
          if (window.__nookExtensionPageLog) return;
          window.__nookExtensionPageLog = true;
          const post = (kind, message) => {
            try { webkit.messageHandlers.\(handlerName).postMessage({ kind, message: String(message).slice(0, 600) }); } catch (e) {}
          };
          const text = value => {
            try { return typeof value === 'string' ? value : (value && (value.stack || value.message)) || JSON.stringify(value); }
            catch (e) { return String(value); }
          };
          addEventListener('error', e => post('error', (e.error && e.error.stack) || `${e.message} @ ${e.filename}:${e.lineno}`));
          addEventListener('unhandledrejection', e => post('rejection', text(e.reason)));
          const consoleError = console.error;
          console.error = (...args) => { post('console.error', args.map(text).join(' ')); return consoleError.apply(console, args); };
        })();
        """
}
