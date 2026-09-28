//
//  WhatsNewWindow.swift
//  md-preview
//
//  The What's New window: shown once over the first document window after
//  an update (see `WhatsNewPolicy`), and on request from
//  Help › What's New in Markdown Preview.
//

import SwiftUI

struct WhatsNewFeature: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let detail: String

    /// The features of `WhatsNewPolicy.featuresVersion`. Features
    /// the running system cannot show are left out rather than announced.
    static var current: [WhatsNewFeature] {
        var features = [
            WhatsNewFeature(
                id: "search-for-document",
                symbol: "doc.text.magnifyingglass",
                title: L("Find any document fast"),
                detail: L("Press ⇧⌘O and type part of a file name to open it from the current project.")
            ),
        ]
        if #available(macOS 26.0, *) {
            features.append(WhatsNewFeature(
                id: "floating-formatting-controls",
                symbol: "textformat",
                title: L("Redesigned formatting bar"),
                detail: L("On macOS 26 and later, the formatting bar uses Liquid Glass, with headings, links, lists, and styles in compact groups.")
            ))
        }
        features.append(WhatsNewFeature(
            id: "code-block-controls",
            symbol: "curlybraces.square",
            title: L("Redesigned code blocks"),
            detail: L("Wrap long lines with one click. Code blocks now use rounded cards that show their language.")
        ))
        return features
    }
}

struct WhatsNewView: View {
    static let width: CGFloat = 460
    /// Keeps a short feature list from turning the window square; the
    /// extra space opens above the buttons.
    static let minHeight: CGFloat = 520
    /// The GitHub release page for the announced version; release tags are
    /// `v` followed by `MARKETING_VERSION`.
    static let releaseNotesURL = URL(
        string: "https://github.com/pluk-inc/markdown-preview/releases/tag/v\(WhatsNewPolicy.featuresVersion)"
    )!

    let features: [WhatsNewFeature]
    var dismiss: () -> Void = {}

    @Environment(\.openURL) private var openURL

    /// Names the release that introduced the features, not the running
    /// build: a later update shows the same announcement.
    private var title: String {
        String(format: L("What’s New in Markdown Preview %@"), WhatsNewPolicy.featuresVersion)
    }

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 20) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.vertical, 8)

                ForEach(features) { feature in
                    row(feature)
                }
            }
            .padding(30)

            Spacer(minLength: 0)

            HStack {
                Button {
                    openURL(Self.releaseNotesURL)
                } label: {
                    Text(L("Release Notes"))
                        .frame(minWidth: 110)
                }
                .secondaryButtonStyle()

                Spacer()

                Button(action: dismiss) {
                    Text(L("Continue"))
                        .frame(minWidth: 110)
                }
                .continueButtonStyle()
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.extraLarge)
        }
        .scenePadding()
        .frame(width: Self.width)
        .frame(minHeight: Self.minHeight)
    }

    private func row(_ feature: WhatsNewFeature) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: feature.symbol)
                .font(.system(size: 28))
                .foregroundStyle(.tint)
                .frame(width: 40, alignment: .center)
                .padding(.top, 8)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(feature.title)
                    .font(.system(size: 14, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(feature.detail)
                    .font(.body)
                    .lineSpacing(1.2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    /// Liquid Glass where the system has it, the filled accent capsule on
    /// macOS 15.
    @ViewBuilder
    func continueButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func secondaryButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

// MARK: - Presentation

/// Return presses Continue through its default-action shortcut; Escape
/// arrives here because the window is key.
private final class WhatsNewHostingController: NSHostingController<WhatsNewView> {
    override func cancelOperation(_ sender: Any?) {
        view.window?.close()
    }
}

@MainActor
enum WhatsNewWindow {
    /// Waits for the document to settle before covering it, so the window
    /// never competes with the first paint of a launch.
    private static let automaticPresentationDelay: TimeInterval = 0.8
    private static var hadUsedAppBeforeLaunch = false
    private static var isAutomaticPresentationScheduled = false
    private static var didHandleAutomaticPresentation = false
    private static var window: NSPanel?
    private static var closeObserver: NSObjectProtocol?

    /// Keys every earlier release wrote once a reader used the app: the
    /// sidebar seed runs for the first window of any kind (file, folder or
    /// untitled), the default-handler offer for the first file.
    private static let priorUseKeys = [
        MainSplitViewController.didSeedKey,
        DocumentWindowController.didOfferDefaultHandlerKey,
    ]

    /// Call from `applicationWillFinishLaunching(_:)`, before any window —
    /// restored ones included — can write the prior-use keys for this launch.
    static func noteLaunch() {
        hadUsedAppBeforeLaunch = priorUseKeys.contains { UserDefaults.standard.bool(forKey: $0) }
    }

    /// Called each time a document window shows content. Only a reader
    /// updating from a build older than `WhatsNewPolicy.featuresBuild` sees
    /// the window, once, over a document window that is on screen without a
    /// sheet when the delay passes.
    static func presentIfNeeded(over documentWindow: NSWindow) {
        guard !didHandleAutomaticPresentation, !isAutomaticPresentationScheduled else { return }
        scheduleAutomaticPresentation(preferring: documentWindow)
    }

    private static func scheduleAutomaticPresentation(preferring documentWindow: NSWindow?) {
        isAutomaticPresentationScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + automaticPresentationDelay) { [weak documentWindow] in
            isAutomaticPresentationScheduled = false
            // The window that asked comes first, then the front document
            // window, then any other; one with a sheet (a save panel, an
            // alert) is busy.
            let documentWindows = ([documentWindow, NSApp.mainWindow] + NSApp.orderedWindows)
                .compactMap { $0 }
                .filter { $0.isVisible && $0.windowController is DocumentWindowController }
            guard let target = documentWindows.first(where: { $0.attachedSheet == nil }) else {
                // Every document window is busy: look again once the reader
                // may be done. With none left, the next one to open asks.
                if !documentWindows.isEmpty {
                    scheduleAutomaticPresentation(preferring: documentWindows.first)
                }
                return
            }

            // Claimed only now that the window can show, so a reader whose
            // documents closed during the delay is asked again next time.
            didHandleAutomaticPresentation = true
            let thisBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
                .flatMap(Int.init) ?? 0
            guard WhatsNewPolicy.claimPresentation(thisBuild: thisBuild,
                                                   hasUsedAppBefore: hadUsedAppBeforeLaunch)
            else { return }
            present(over: target)
        }
    }

    /// Shows the window centred over `documentWindow`, or over the screen
    /// when there is none, or brings the open one to the front.
    static func present(over documentWindow: NSWindow?) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Built first and its root view replaced after, so the closure can
        // capture the controller weakly instead of retaining it through its
        // own root view.
        let features = WhatsNewFeature.current
        let hosting = WhatsNewHostingController(rootView: WhatsNewView(features: features))
        hosting.rootView = WhatsNewView(
            features: features,
            dismiss: { [weak hosting] in hosting?.view.window?.close() }
        )

        // The view pads itself from the window's top edge, under the
        // transparent titlebar.
        hosting.safeAreaRegions = []

        let window = NSPanel(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = L("What’s New in Markdown Preview")
        // An empty toolbar gives the window the larger toolbar-window corner
        // radius and window-button inset.
        window.toolbar = NSToolbar()
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setContentSize(hosting.view.intrinsicContentSize)

        if let documentWindow {
            // Never below the document: an Always on Top window floats.
            if documentWindow.level.rawValue > window.level.rawValue {
                window.level = documentWindow.level
            }
            let frame = window.frame
            let parent = documentWindow.frame
            window.setFrameOrigin(NSPoint(x: parent.midX - frame.width / 2,
                                          y: parent.midY - frame.height / 2))
        } else {
            window.center()
        }

        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                closeObserver = nil
                Self.window = nil
            }
        }
        Self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
