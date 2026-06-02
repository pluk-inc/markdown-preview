//
//  ExportContentRules.swift
//  md-preview
//

import os
import WebKit

/// Compiles and caches a content-rule list that blocks every sub-resource load
/// during PDF export except requests served via the app's custom asset scheme.
enum ExportContentRules {

    private static let identifier = "md-preview-export-local-assets"
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "doc.md-preview",
                                    category: "export")

    /// JSON rules: block sub-resources, then exempt `md-asset://` via
    /// `ignore-previous-rules` (same syntax as Safari content blockers).
    private static var encodedRules: String {
        let scheme = MarkdownAssetScheme.scheme
        return """
        [
            {
                "trigger": {
                    "url-filter": ".*",
                    "resource-type": [
                        "image", "script", "style-sheet", "font", "raw",
                        "media", "svg-document", "fetch", "websocket", "other"
                    ]
                },
                "action": {
                    "type": "block"
                }
            },
            {
                "trigger": {
                    "url-filter": "^\(scheme)://.*"
                },
                "action": {
                    "type": "ignore-previous-rules"
                }
            }
        ]
        """
    }

    /// Adds the cached or freshly compiled rule list to `controller`, then
    /// calls `completion` on the main actor. If compilation fails, `completion`
    /// still runs so export can proceed without network blocking (logged).
    static func install(on controller: WKUserContentController,
                        completion: @escaping @MainActor () -> Void) {
        guard let store = WKContentRuleListStore.default() else {
            log.error("Export content-rule store unavailable")
            DispatchQueue.main.async { completion() }
            return
        }
        store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
            DispatchQueue.main.async {
                if let list {
                    controller.add(list)
                    completion()
                    return
                }
                store.compileContentRuleList(
                    forIdentifier: identifier,
                    encodedContentRuleList: encodedRules
                ) { list, error in
                    DispatchQueue.main.async {
                        if let list {
                            controller.add(list)
                        } else if let error {
                            log.error("Export content-rule compile failed: \(error.localizedDescription, privacy: .public)")
                        }
                        completion()
                    }
                }
            }
        }
    }
}
