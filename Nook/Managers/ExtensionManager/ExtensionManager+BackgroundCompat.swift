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
    /// so nothing pretends to work that does not. Offscreen documents are emulated for real (a
    /// hidden extension window), since NordPass decrypts in one. APIs with other real
    /// behaviour (sidePanel, debugger, downloads) are left missing, since a stub would hide the
    /// failure.
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
            add(ns.runtime, 'ContextType', {
              BACKGROUND: 'BACKGROUND', POPUP: 'POPUP', TAB: 'TAB', SIDE_PANEL: 'SIDE_PANEL',
              OFFSCREEN_DOCUMENT: 'OFFSCREEN_DOCUMENT',
            });
          }

          // Offscreen documents: the page opens in an extension popup window Nook never shows
          // (the `#nook-offscreen` mark), and is found again after the worker restarts.
          const api = globalThis.chrome;
          if (api && api.windows && api.tabs) {
            const mark = '#nook-offscreen';
            const findOffscreen = async () => {
              for (const w of await api.windows.getAll({ populate: true })) {
                const tab = (w.tabs || []).find(t => (t.url || '').endsWith(mark));
                if (tab) return { windowId: w.id, url: tab.url.slice(0, -mark.length) };
              }
              return null;
            };
            const offscreen = {
              Reason: new Proxy({}, { get: (_, name) => String(name) }),
              async createDocument({ url }) {
                if (await findOffscreen()) throw new Error('Only a single offscreen document may be created.');
                await api.windows.create({ url: api.runtime.getURL(url) + mark, type: 'popup', focused: false });
              },
              async closeDocument() {
                const found = await findOffscreen();
                if (!found) throw new Error('No current offscreen document.');
                await api.windows.remove(found.windowId);
              },
              async hasDocument() { return !!(await findOffscreen()); },
            };
            const getContexts = async (filter = {}) => {
              const found = await findOffscreen();
              if (!found) return [];
              if (filter.contextTypes && !filter.contextTypes.includes('OFFSCREEN_DOCUMENT')) return [];
              if (filter.documentUrls && !filter.documentUrls.includes(found.url)) return [];
              return [{ contextType: 'OFFSCREEN_DOCUMENT', documentUrl: found.url, documentOrigin: found.url.split('/').slice(0, 3).join('/'),
                        windowId: found.windowId, tabId: -1, frameId: 0, incognito: false, contextId: 'nook-offscreen' }];
            };
            for (const ns of new Set([globalThis.browser, globalThis.chrome])) {
              if (!ns) continue;
              add(ns, 'offscreen', offscreen);
              add(ns.runtime, 'getContexts', getContexts);
            }
          }

          // Uncaught errors in the background, kept in the extension's own storage under
          // `__nookErrors` (last 20), where Nook can read them from disk: a background that
          // stops at startup otherwise fails without a trace.
          // Writes queue one behind the other, so errors arriving together all land.
          let pending = Promise.resolve();
          const report = (kind, message) => {
            const store = globalThis.chrome && globalThis.chrome.storage && globalThis.chrome.storage.local;
            if (!store) return;
            const entry = { at: new Date().toISOString(), kind, message: String(message).slice(0, 800) };
            pending = pending.then(() => store.get('__nookErrors')).then(r => {
              const list = (r.__nookErrors || []).slice(-19);
              list.push(entry);
              return store.set({ __nookErrors: list });
            }).catch(() => {});
          };
          self.addEventListener('error', e => report('error', (e.error && e.error.stack) || `${e.message} @ ${e.filename}:${e.lineno}`));
          self.addEventListener('unhandledrejection', e => report('rejection', (e.reason && (e.reason.stack || e.reason.message)) || e.reason));
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
