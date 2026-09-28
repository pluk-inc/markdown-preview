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
            id: "faster-opening",
            symbol: "hare",
            title: L("Faster document opening"),
            detail: L("Improved rendering shows documents sooner, and files you reopen appear right away.")
        ))
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
    private static var didClaimAutomaticPresentation = false
    private static var window: NSPanel?

    /// Called each time a document window shows a file. At most one window
    /// per launch asks, and only a reader updating from a build older than
    /// `WhatsNewPolicy.featuresBuild` sees it. Call before anything marks
    /// the install as used.
    static func presentIfNeeded(over documentWindow: NSWindow, hasUsedAppBefore: Bool) {
        guard !didClaimAutomaticPresentation else { return }
        didClaimAutomaticPresentation = true
        let thisBuild = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            .flatMap(Int.init) ?? 0
        guard WhatsNewPolicy.claimPresentation(thisBuild: thisBuild,
                                               hasUsedAppBefore: hasUsedAppBefore) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + automaticPresentationDelay) { [weak documentWindow] in
            // A sheet (a save panel, an alert) means the reader is busy, and
            // a closed window falls back to the frontmost document window.
            let target = [documentWindow, NSApp.mainWindow].compactMap { $0 }.first {
                $0.isVisible && $0.attachedSheet == nil
                    && $0.windowController is DocumentWindowController
            }
            if let target { present(over: target) }
        }
    }

    /// Shows the window centred over `documentWindow`, or brings the open
    /// one to the front.
    static func present(over documentWindow: NSWindow) {
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

        let frame = window.frame
        let parent = documentWindow.frame
        window.setFrameOrigin(NSPoint(x: parent.midX - frame.width / 2,
                                      y: parent.midY - frame.height / 2))
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Self.window = nil }
        }
        Self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
