//
//  SettingsSupport.swift
//  md-preview
//
//  Shared helpers for the Settings pane files.
//

import AppKit

func L(_ key: String, default value: String? = nil) -> String {
    let localized = NSLocalizedString(key, comment: "")
    if let value, localized == key {
        return value
    }
    return localized
}

var appDelegate: AppDelegate? {
    NSApp.delegate as? AppDelegate
}
