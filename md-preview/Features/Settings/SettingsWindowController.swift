//
//  SettingsWindowController.swift
//  md-preview
//
//  The Settings window, laid out like Safari's and Xcode's: toolbar tabs with
//  a symbol and a name, and a window that changes height to fit each pane.
//  Each pane is a SwiftUI form in a hosting controller.
//

import Cocoa
import SwiftUI

// MARK: - Panes

enum SettingsPane: String, CaseIterable {
    case general = "General"
    case reading = "Reading"
    case theme = "Appearance"
    case privacy = "Privacy"
    case advanced = "Advanced"
    case about = "About"

    var title: String { NSLocalizedString(rawValue, comment: "Settings pane") }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .reading: "book"
        case .theme: "paintpalette"
        case .privacy: "hand.raised"
        case .advanced: "gearshape.2"
        case .about: "info.circle"
        }
    }

    @MainActor @ViewBuilder
    var content: some View {
        switch self {
        case .general: GeneralSettingsView()
        case .reading: ReadingSettingsView()
        case .theme: ThemeSettingsView()
        case .privacy: PrivacySettingsView()
        case .advanced: AdvancedSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

// MARK: - Window Controller

@MainActor
final class SettingsWindowController: NSWindowController {

    private let tabViewController = SettingsTabViewController()

    init() {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.contentViewController = tabViewController
        window.center()
        window.setFrameAutosaveName("MarkdownPreviewSettingsWindowFrame")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        // The controller is cached for the app's lifetime, so without this
        // a reopened window would resume on whatever pane was last visited.
        // Fresh opens always start on General.
        if window?.isVisible != true {
            tabViewController.select(.general)
        }
        applyWindowLevel()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Re-read on every show, and again whenever Always on Top changes while
    /// this window is open, so Settings is above the preview windows in both
    /// directions — rising with the pin and dropping back with it.
    func applyWindowLevel() {
        window?.level = NSWindow.Level(
            rawValue: AlwaysOnTopPolicy.settingsWindowLevel(isPinned: AlwaysOnTopPolicy.isEnabled)
        )
    }

    func show(pane: SettingsPane) {
        // After show(), which resets a fresh window to General.
        show()
        tabViewController.select(pane)
    }
}

// MARK: - Tabs

/// Toolbar tabs, sized the way Safari's are: NSTabViewController animates
/// the window to the selected pane's preferredContentSize on every switch.
/// Each pane's size is set here from its SwiftUI measurement, never by the
/// hosting controller itself, so it cannot change in the middle of a switch.
final class SettingsTabViewController: NSTabViewController {

    init() {
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.allowUserInteraction]
        for pane in SettingsPane.allCases {
            let host = NSHostingController(rootView: AnyView(EmptyView()))
            host.rootView = AnyView(pane.content
                .padding(.horizontal, 30)
                .padding(.vertical, 24)
                .frame(width: settingsPaneWidth)
                .fixedSize(horizontal: false, vertical: true)
                // Picked up on the next switch to this pane; resizing the
                // window under an open pane would make its content jump.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak host] size in
                    host?.preferredContentSize = size
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
            // The hosting controller and view must not size anything
            // themselves: the view's minimum-size constraint would hold it at
            // the new pane's full height while the window is still animating.
            host.sizingOptions = []
            (host.view as? NSHostingView<AnyView>)?.sizingOptions = []
            host.title = pane.title
            host.preferredContentSize = host.sizeThatFits(
                in: CGSize(width: settingsPaneWidth, height: .greatestFiniteMagnitude))
            let item = NSTabViewItem(viewController: host)
            item.label = pane.title
            item.image = NSImage(systemSymbolName: pane.symbolName, accessibilityDescription: nil)
            addTabViewItem(item)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        view.window?.title = tabViewItem?.label ?? ""
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.title = tabViewItems[selectedTabViewItemIndex].label
    }

    /// A pane's size changing while it is open waits for the next switch.
    override func preferredContentSizeDidChange(for viewController: NSViewController) {}

    func select(_ pane: SettingsPane) {
        selectedTabViewItemIndex = SettingsPane.allCases.firstIndex(of: pane) ?? 0
    }
}
