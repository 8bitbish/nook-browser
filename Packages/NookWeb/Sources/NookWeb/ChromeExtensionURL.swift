// Licensed under GPL-3.0. See LICENSE.
//
//  ChromeExtensionURL.swift
//  NookWeb
//
//  An extension's pages live at webkit-extension://ext-<store ID in hex>/ in Nook, but Chrome
//  extensions expect chrome-extension://<store ID>/ and hand that address to their own servers
//  (NordPass's OAuth redirect). The background stand-ins give pages their Chrome address; this maps
//  one back to the installed extension's real address when it comes into Nook.
//

import Foundation
import WebKit

extension WKWebExtensionController {
    /// The real address for `url` when it is chrome-extension://<store ID>/… of an installed
    /// extension, keeping path, query and fragment; nil for anything else.
    public func nookMappedChromeExtensionURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "chrome-extension",
              let id = url.host?.lowercased(), id.count == 32, id.allSatisfy({ ("a"..."p").contains($0) })
        else { return nil }
        let host = "ext-" + id.utf8.map { String(format: "%02x", $0) }.joined()
        guard let context = extensionContexts.first(where: { $0.baseURL.host?.lowercased() == host }),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = context.baseURL.scheme
        components.host = context.baseURL.host
        return components.url
    }
}
