//
//  SettingsSupport.swift
//  md-preview
//
//  Shared helpers for the Settings pane files.
//

import AppKit

func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

var appDelegate: AppDelegate? {
    NSApp.delegate as? AppDelegate
}
