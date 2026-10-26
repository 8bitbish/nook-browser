// Licensed under GPL-3.0. See LICENSE.
//
//  ExtensionManager+BackgroundCompat.swift
//  Nook
//
//  Chrome APIs WebKit does not implement, stood in for ahead of an extension's background.
//

import Foundation
import os

extension ExtensionManager {

    static let backgroundCompatFile = "nook_compat.js"
    static let backgroundWrapperFile = "nook_background.js"
    /// The extension's own service worker, recorded once the manifest points at the wrapper.
    static let originalServiceWorkerKey = "nook_original_service_worker"

    /// A Chrome extension's background that touches an API WebKit lacks throws there, and an
    /// async startup that throws registers nothing after that point: NordPass reads
    /// `chrome.privacy` first thing, so its toolbar click, autofill and sign-in never came up.
    /// Each stand-in below answers the way Chrome does when the browser declines the request,
    /// so nothing pretends to work that does not. APIs with real behaviour (sidePanel,
    /// offscreen, debugger, downloads) are left missing, since a stub would hide the failure.
    ///
    /// The members are added to WebKit's own namespace objects. Replacing `chrome` or
    /// `browser` with a Proxy stopped WebKit delivering any event to the worker.
    static let backgroundCompatJS = """
        // Nook: Chrome API stand-ins for WebKit
        (() => {
          const event = () => ({ addListener() {}, removeListener() {}, hasListener() { return false; }, hasListeners() { return false; } });
          // A browser setting the extension may read but not change.
          const setting = () => ({
            get: async () => ({ value: false, levelOfControl: 'not_controllable' }),
            set: async () => { throw new Error('This setting is not controllable in Nook'); },
            clear: async () => {},
            onChange: event(),
          });
          const add = (target, name, value) => {
            if (target && target[name] === undefined) {
              Object.defineProperty(target, name, { value, configurable: true, enumerable: true, writable: true });
            }
          };
          for (const ns of new Set([globalThis.browser, globalThis.chrome])) {
            if (!ns) continue;
            add(ns, 'privacy', {
              services: {
                passwordSavingEnabled: setting(),
                autofillEnabled: setting(),
                autofillAddressEnabled: setting(),
                autofillCreditCardEnabled: setting(),
              },
              network: {},
              websites: {},
            });
            add(ns, 'idle', {
              IdleState: { ACTIVE: 'active', IDLE: 'idle', LOCKED: 'locked' },
              setDetectionInterval() {},
              queryState: async () => 'active',
              getAutoLockDelay: async () => 0,
              onStateChanged: event(),
            });
            add(ns.runtime, 'onSuspend', event());
            add(ns.runtime, 'onSuspendCanceled', event());
          }
        })();
        """

    /// Points an MV3 service worker at a wrapper that loads the stand-ins first, or puts them
    /// first in an MV2 `background.scripts` list. Returns whether the manifest changed.
    static func installBackgroundCompat(in manifest: inout [String: Any], packageDir: URL) -> Bool {
        guard var background = manifest["background"] as? [String: Any] else { return false }
        writeIfChanged(backgroundCompatJS, to: packageDir.appendingPathComponent(backgroundCompatFile))

        if var scripts = background["scripts"] as? [String], background["service_worker"] == nil {
            guard !scripts.contains(backgroundCompatFile) else { return false }
            scripts.insert(backgroundCompatFile, at: 0)
            background["scripts"] = scripts
            manifest["background"] = background
            return true
        }

        guard let declared = background["service_worker"] as? String else { return false }
        // A store update brings a fresh manifest, so the recorded name only counts while the
        // manifest still points at the wrapper.
        let original = declared == backgroundWrapperFile
            ? (manifest[originalServiceWorkerKey] as? String ?? declared) : declared
        guard original != backgroundWrapperFile else { return false }
        let path = original.drop { $0 == "." || $0 == "/" }
        guard let literal = jsStringLiteral("/" + path) else { return false }

        let wrapper = (background["type"] as? String) == "module"
            ? "// Nook: background wrapper\nimport '/\(backgroundCompatFile)';\nimport \(literal);\n"
            : "// Nook: background wrapper\nimportScripts('/\(backgroundCompatFile)', \(literal));\n"
        writeIfChanged(wrapper, to: packageDir.appendingPathComponent(backgroundWrapperFile))

        guard declared != backgroundWrapperFile else { return false }
        background["service_worker"] = backgroundWrapperFile
        manifest["background"] = background
        manifest[originalServiceWorkerKey] = original
        logger.notice("Background compatibility wrapper installed for \(packageDir.lastPathComponent, privacy: .public)")
        return true
    }

    private static func jsStringLiteral(_ string: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [string]),
              let array = String(data: data, encoding: .utf8)
        else { return nil }
        return String(array.dropFirst().dropLast())
    }
}
