//
//  RendererSetting.swift
//  md-preview
//

import Foundation

/// Which renderer draws a document in Read mode. The web view is the
/// default and has every feature. The native renderer is experimental: it
/// is faster to open, and it gets the web view's features one at a time.
enum RendererSetting: String {
    case web
    case native

    static let defaultsKey = "MarkdownPreview.renderer"

    static var current: RendererSetting {
        get {
            UserDefaults.standard.string(forKey: defaultsKey).flatMap(RendererSetting.init(rawValue:)) ?? .web
        }
        set {
            if newValue == .web {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            }
        }
    }
}
