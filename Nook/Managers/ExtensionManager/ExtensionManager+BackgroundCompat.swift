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
    /// The members are added to WebKit's own namespace objects, by assignment: WebKit ignores
    /// Object.defineProperty there. Replacing `chrome` or `browser` (with a Proxy, or with a
    /// forwarding object) stops WebKit delivering any event to the worker.
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
          // `chrome.runtime`, `chrome.tabs` and the like are JS wrappers around WebKit objects. A
          // wrapper nothing holds can be collected and handed out fresh on the next read, without
          // what was added to it, so every object touched here is kept alive for the worker's life.
          const kept = globalThis.__nookCompatKept || (globalThis.__nookCompatKept = new Set());
          const put = (target, name, value) => {
            if (!target) return;
            kept.add(target);
            try { target[name] = value; } catch (e) {}
            if (target[name] !== value) {
              try { Object.defineProperty(target, name, { value, configurable: true, enumerable: true, writable: true }); } catch (e) {}
            }
          };
          const add = (target, name, value) => {
            if (target && target[name] === undefined) put(target, name, value);
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
          }
          for (const ns of new Set([globalThis.browser, globalThis.chrome])) {
            if (!ns || !ns.runtime) continue;
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
          // The extension's real page addresses; `runtime.getURL` may hand out its Chrome form below.
          const realGetURL = api && api.runtime && api.runtime.getURL ? api.runtime.getURL.bind(api.runtime) : (p => p);
          const pathOf = url => { try { return new URL(url).pathname; } catch (e) { return String(url); } };
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
                await api.windows.create({ url: realGetURL(pathOf(realGetURL(url))) + mark, type: 'popup', focused: false });
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
              // By path: the extension may ask with the Chrome form of its own address.
              if (filter.documentUrls && !filter.documentUrls.some(u => pathOf(u) === pathOf(found.url))) return [];
              return [{ contextType: 'OFFSCREEN_DOCUMENT', documentUrl: found.url, documentOrigin: found.url.split('/').slice(0, 3).join('/'),
                        windowId: found.windowId, tabId: -1, frameId: 0, incognito: false, contextId: 'nook-offscreen' }];
            };
            for (const ns of new Set([globalThis.browser, globalThis.chrome])) {
              if (!ns) continue;
              add(ns, 'offscreen', offscreen);
              add(ns.runtime, 'getContexts', getContexts);
            }
          }

          // A message for a tab showing one of the extension's own pages. Chrome delivers
          // tabs.sendMessage to such a page; WebKit only to content scripts, which extension pages
          // never have, so the message went nowhere. NordPass sends its Nord Account sign-in URL
          // to its own login tab this way, and the sign-in stopped after the email. Such a tab
          // gets it through runtime.sendMessage, which reaches the extension's pages.
          // A trace of the background's messages to tabs and pages, its sign-in messages and its
          // network requests, kept beside `__nookErrors` as `__nookTrace` (last 300): types,
          // routes, hosts and paths, status codes and error names; never contents, queries or
          // bodies, and email addresses masked.
          let tracing = Promise.resolve();
          const trace = entry => {
            const store = api && api.storage && api.storage.local;
            if (!store) return;
            const item = { at: new Date().toISOString(), ...entry };
            tracing = tracing.then(() => store.get('__nookTrace')).then(r => {
              const list = (r.__nookTrace || []).slice(-299);
              list.push(item);
              return store.set({ __nookTrace: list });
            }).catch(() => {});
          };
          const typeOf = message => (message && typeof message === 'object' && typeof message.type === 'string') ? message.type.slice(0, 60) : typeof message;
          const maskText = value => String(value).replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}/g, '<email>').slice(0, 200);
          const signIn = type => /^OAUTH\\//.test(type) || type === 'OPEN_NORD_ACCOUNT';

          // Network requests: method, host and path, status or error, duration.
          if (typeof globalThis.fetch === 'function') {
            const realFetch = globalThis.fetch.bind(globalThis);
            globalThis.fetch = async (input, init) => {
              const raw = typeof input === 'string' ? input : (input && input.url) || String(input);
              const where = String(raw).split(/[?#]/)[0].slice(0, 120);
              const method = (init && init.method) || (input && input.method) || 'GET';
              const started = Date.now();
              try {
                const response = await realFetch(input, init);
                trace({ call: 'fetch', method, url: where, status: response.status, ms: Date.now() - started });
                return response;
              } catch (e) {
                trace({ call: 'fetch', method, url: where, error: maskText(e && (e.name + ': ' + e.message)), ms: Date.now() - started });
                throw e;
              }
            };
          }

          // Sign-in messages the background receives, and how its handler finishes.
          if (api && api.runtime && api.runtime.onMessage) {
            const onMessage = api.runtime.onMessage;
            const realAdd = onMessage.addListener.bind(onMessage);
            const realRemove = onMessage.removeListener.bind(onMessage);
            const wrappers = new Map();
            put(onMessage, 'addListener', listener => {
              const wrapped = (message, sender, reply) => {
                const type = typeOf(message);
                if (!signIn(type)) return listener(message, sender, reply);
                const started = Date.now();
                trace({ call: 'received', type });
                const replyTraced = value => {
                  trace({ call: 'replied', type, ms: Date.now() - started,
                          keys: value && typeof value === 'object' ? Object.keys(value).slice(0, 12) : typeof value,
                          error: value && value.error ? maskText(value.error.message || value.error) : undefined });
                  return reply(value);
                };
                const result = listener(message, sender, replyTraced);
                if (result && typeof result.then === 'function') {
                  result.then(
                    value => trace({ call: 'resolved', type, ms: Date.now() - started,
                                     keys: value && typeof value === 'object' ? Object.keys(value).slice(0, 12) : typeof value }),
                    e => trace({ call: 'rejected', type, ms: Date.now() - started, error: maskText(e && (e.stack || e.message || e)) }));
                }
                return result;
              };
              wrappers.set(listener, wrapped);
              return realAdd(wrapped);
            });
            put(onMessage, 'removeListener', listener => realRemove(wrappers.get(listener) || listener));
            put(onMessage, 'hasListener', listener => wrappers.has(listener));
          }
          if (api && api.tabs && api.tabs.sendMessage && api.runtime && api.runtime.sendMessage) {
            const tabsSend = api.tabs.sendMessage.bind(api.tabs);
            const runtimeSend = api.runtime.sendMessage.bind(api.runtime);
            const ownPrefix = realGetURL('');
            put(api.tabs, 'sendMessage', async (tabId, message, options) => {
              let tab = null;
              try { tab = await api.tabs.get(tabId); } catch (e) {}
              const own = !!(tab && typeof tab.url === 'string' && tab.url.startsWith(ownPrefix));
              trace({ call: 'tabs.sendMessage', type: typeOf(message), tabUrlKnown: !!(tab && tab.url), ownPage: own,
                      tabHost: tab && typeof tab.url === 'string' ? tab.url.split('/').slice(0, 3).join('/').slice(0, 60) : null });
              if (own) return runtimeSend(message);
              return tabsSend(tabId, message, options);
            });
            put(api.runtime, 'sendMessage', (...args) => {
              const message = args.find(a => a && typeof a === 'object' && !Array.isArray(a));
              const type = typeOf(message);
              if (type === 'OPEN_URL_IN_TAB' || /^OPEN|LOGIN|OAUTH/.test(type)) trace({ call: 'runtime.sendMessage', type });
              return runtimeSend(...args);
            });
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
