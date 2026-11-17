//
//  main.swift
//  quick-look-setup
//
//  A small app, embedded in Markdown Preview, that makes the Markdown
//  Preview extension the one Quick Look uses for Markdown files. It is a
//  separate app because it must run outside the sandbox (see PlugInKit.swift);
//  the main app only starts it. It asks before each change, makes the
//  change, and quits.
//

import AppKit

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.finishLaunching()
application.activate()
QuickLookSetup().run()
