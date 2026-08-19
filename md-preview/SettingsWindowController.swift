//
//  SettingsWindowController.swift
//  md-preview
//
//  The Settings window. AppKit owns the window, toolbar, and split view; each
//  pane is a SwiftUI `Form(.grouped)` in a hosting controller, which is what
//  draws the inset grouped cards System Settings uses. Built to match the
//  Settings window in the Pluk app so both stay recognisably the same.
//

import Cocoa
import SwiftUI

// MARK: - Panes

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General"
    case privacy = "Privacy"
    case about = "About"

    var id: String { rawValue }

    var title: String { NSLocalizedString(rawValue, comment: "Settings pane") }

    /// Development-time exports of the icons rendered by each registered
    /// System Settings extension. They are bundled so the sandboxed app never
    /// needs to call private IconServices at runtime.
    var iconAssetName: String {
        switch self {
        case .general: "SettingsGeneral"
        case .privacy: "SettingsPrivacy"
        case .about: "SettingsAbout"
        }
    }
}

/// IconServices returns a 24-point image canvas around a 20-point tile so its
/// native shadow is not clipped. Keep the 20-point layout slot used by `Label`,
/// while allowing the transparent canvas to extend two points on each side.
struct SettingsPaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(pane.iconAssetName)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .frame(width: 24, height: 24)
            .frame(width: 20, height: 20)
    }
}

// MARK: - Window Controller

@MainActor
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {

    private var splitViewController: SettingsSplitViewController?
    private var navigationHistory = SettingsNavigationHistory()

    // Wide enough that the three appearance thumbnails and their labels fit
    // beside the "Appearance" label without clipping at the minimum size.
    private static let defaultWindowSize = NSSize(width: 800, height: 580)
    private static let minimumWindowSize = NSSize(width: 720, height: 500)
    private static let windowFrameAutosaveName = "MarkdownPreviewSettingsWindowFrame"
    private static let backForwardIdentifier = NSToolbarItem.Identifier("backForward")

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = SettingsPane.general.title
        window.titleVisibility = .visible
        window.toolbarStyle = .automatic
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .automatic
        window.contentMinSize = Self.minimumWindowSize
        window.isReleasedWhenClosed = false

        super.init(window: window)

        let toolbar = NSToolbar(identifier: "MarkdownPreviewSettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        restoreWindowFrame(window)

        let splitVC = SettingsSplitViewController { [weak self] pane, isUserSelection in
            guard let self else { return }
            self.window?.title = pane.title
            if isUserSelection {
                self.navigationHistory.push(pane)
            }
            self.updateToolbarButtons()
        }
        splitViewController = splitVC
        window.contentViewController = splitVC

        navigationHistory.push(.general)
        updateToolbarButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func restoreWindowFrame(_ window: NSWindow) {
        let restored = window.setFrameUsingName(Self.windowFrameAutosaveName)
        window.setFrameAutosaveName(Self.windowFrameAutosaveName)
        guard !restored else { return }
        window.setContentSize(Self.defaultWindowSize)
        window.center()
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func show(pane: SettingsPane) {
        splitViewController?.navigate(to: pane)
        show()
    }

    // MARK: - Back / forward

    private func updateToolbarButtons() {
        for item in window?.toolbar?.items ?? [] {
            guard item.itemIdentifier == Self.backForwardIdentifier,
                  let segmented = item.view as? NSSegmentedControl else { continue }
            segmented.setEnabled(navigationHistory.canGoBack, forSegment: 0)
            segmented.setEnabled(navigationHistory.canGoForward, forSegment: 1)
        }
    }

    @objc private func backForwardAction(_ sender: NSSegmentedControl) {
        let pane = sender.selectedSegment == 0
            ? navigationHistory.goBack()
            : navigationHistory.goForward()
        guard let pane else { return }
        splitViewController?.navigate(to: pane)
        window?.title = pane.title
        updateToolbarButtons()
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, Self.backForwardIdentifier, .flexibleSpace]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.backForwardIdentifier else { return nil }

        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.isNavigational = true

        let segmented = NSSegmentedControl()
        segmented.segmentStyle = .automatic
        segmented.trackingMode = .momentary
        segmented.segmentCount = 2
        segmented.controlSize = .small
        segmented.setImage(
            NSImage(systemSymbolName: "chevron.left",
                    accessibilityDescription: NSLocalizedString("Back", comment: "Settings navigation"))?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)),
            forSegment: 0
        )
        segmented.setImage(
            NSImage(systemSymbolName: "chevron.right",
                    accessibilityDescription: NSLocalizedString("Forward", comment: "Settings navigation"))?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .medium)),
            forSegment: 1
        )
        segmented.setWidth(24, forSegment: 0)
        segmented.setWidth(24, forSegment: 1)
        segmented.setEnabled(false, forSegment: 0)
        segmented.setEnabled(false, forSegment: 1)
        segmented.target = self
        segmented.action = #selector(backForwardAction(_:))

        item.view = segmented
        return item
    }
}

// MARK: - Navigation history

@MainActor
final class SettingsNavigationHistory {
    private var history: [SettingsPane] = []
    private var currentIndex = -1

    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex < history.count - 1 }

    func push(_ pane: SettingsPane) {
        if history.indices.contains(currentIndex), history[currentIndex] == pane { return }
        if currentIndex < history.count - 1 {
            history.removeLast(history.count - currentIndex - 1)
        }
        history.append(pane)
        currentIndex = history.count - 1
    }

    func goBack() -> SettingsPane? {
        guard canGoBack else { return nil }
        currentIndex -= 1
        return history[currentIndex]
    }

    func goForward() -> SettingsPane? {
        guard canGoForward else { return nil }
        currentIndex += 1
        return history[currentIndex]
    }
}

// MARK: - Split view

final class SettingsSplitViewController: NSSplitViewController {

    private let sidebarViewModel = SettingsSidebarViewModel()

    init(onPaneChange: @escaping (SettingsPane, Bool) -> Void) {
        super.init(nibName: nil, bundle: nil)
        sidebarViewModel.setOnPaneChange(onPaneChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: NSHostingController(
            rootView: SettingsSidebarView(viewModel: sidebarViewModel)
        ))
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 190
        addSplitViewItem(sidebarItem)

        let detailItem = NSSplitViewItem(viewController: NSHostingController(
            rootView: SettingsDetailView(viewModel: sidebarViewModel)
        ))
        detailItem.minimumThickness = 420
        addSplitViewItem(detailItem)
    }

    func navigate(to pane: SettingsPane) {
        sidebarViewModel.selectPane(pane, isUserSelection: false)
    }
}

// MARK: - Sidebar

@Observable
@MainActor
final class SettingsSidebarViewModel {
    var selectedPane: SettingsPane = .general

    private var onPaneChange: ((SettingsPane, Bool) -> Void)?

    func setOnPaneChange(_ handler: ((SettingsPane, Bool) -> Void)?) {
        onPaneChange = handler
    }

    func selectPane(_ pane: SettingsPane, isUserSelection: Bool) {
        selectedPane = pane
        onPaneChange?(pane, isUserSelection)
    }
}

struct SettingsSidebarView: View {
    @Bindable var viewModel: SettingsSidebarViewModel

    var body: some View {
        List(SettingsPane.allCases, selection: Binding(
            get: { viewModel.selectedPane },
            set: { newValue in
                guard let newValue else { return }
                viewModel.selectPane(newValue, isUserSelection: true)
            }
        )) { pane in
            Label {
                Text(pane.title)
            } icon: {
                SettingsPaneIcon(pane: pane)
                    .offset(x: -2)
            }
            .tag(pane)
        }
        .listStyle(.sidebar)
    }
}

struct SettingsDetailView: View {
    var viewModel: SettingsSidebarViewModel

    var body: some View {
        switch viewModel.selectedPane {
        case .general: GeneralSettingsView()
        case .privacy: PrivacySettingsView()
        case .about: AboutSettingsView()
        }
    }
}
