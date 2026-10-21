import Cocoa
import WebKit

enum SaveConflictSheet {
    static func make(localMarkdown: String, externalMarkdown: String,
                     fileName: String, changedAgain: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = changedAgain
            ? NSLocalizedString("This document changed on disk again", comment: "Refreshed conflict title")
            : NSLocalizedString("This document changed on disk", comment: "External edit conflict alert title")
        let message = String(
            format: NSLocalizedString(
                "Another app changed %@. Cancel keeps your changes unsaved. Choose which version to keep.",
                comment: "External edit conflict alert message"
            ),
            fileName
        )
        alert.informativeText = [message, ConflictDiffHTML.lineEndingNote(disk: externalMarkdown, draft: localMarkdown)]
            .compactMap { $0 }.joined(separator: " ")
        alert.addButton(withTitle: NSLocalizedString("Keep My Changes", comment: "Conflict alert button"))
        alert.addButton(withTitle: NSLocalizedString("Reload from Disk", comment: "Conflict alert button"))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Alert button"))
        // Neither Return nor a not-yet-loaded comparison may discard a version.
        for button in alert.buttons.prefix(2) {
            button.keyEquivalent = ""
            button.isEnabled = false
            button.hasDestructiveAction = true
        }
        alert.buttons[2].keyEquivalent = "\u{1b}"
        let comparison = ConflictComparisonView(disk: externalMarkdown, draft: localMarkdown)
        comparison.finishedLoading = { [weak alert] success in
            guard let alert else { return }
            if success {
                alert.buttons.prefix(2).forEach { $0.isEnabled = true }
            } else {
                alert.informativeText = NSLocalizedString(
                    "The comparison could not be displayed. Cancel to return to your unsaved draft.",
                    comment: "Save conflict comparison failure")
            }
        }
        alert.accessoryView = comparison
        return alert
    }
}

/// Column headings and change navigation above the two sources. The
/// counter and chevrons match FindBar, so moving between changes looks and
/// works like moving between search matches.
private final class ConflictComparisonView: NSView, WKNavigationDelegate {
    var finishedLoading: ((Bool) -> Void)?

    private let webView: WKWebView
    private let countLabel = NSTextField(labelWithString: "")
    private let navigationControl = NSSegmentedControl()
    private let showWholeFileButton = NSButton()

    init(disk: String, draft: String) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: NSRect(x: 0, y: 0, width: 820, height: 420))
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .secondaryLabelColor
        configureNavigationControl()
        showWholeFileButton.title = NSLocalizedString("Show Whole File", comment: "Expand all unchanged source in the save conflict comparison")
        showWholeFileButton.bezelStyle = .rounded
        showWholeFileButton.controlSize = .small
        showWholeFileButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        showWholeFileButton.keyEquivalent = "e"
        showWholeFileButton.keyEquivalentModifierMask = [.command, .shift]
        showWholeFileButton.target = self
        showWholeFileButton.action = #selector(showWholeFile(_:))
        showWholeFileButton.isEnabled = false

        let diskHeader = NSStackView(views: [Self.columnLabel(
            NSLocalizedString("On Disk", comment: "Save conflict comparison heading"))])
        let draftHeader = NSStackView()
        draftHeader.addView(Self.columnLabel(
            NSLocalizedString("Your Draft", comment: "Save conflict comparison heading")), in: .leading)
        draftHeader.addView(countLabel, in: .trailing)
        draftHeader.addView(navigationControl, in: .trailing)
        draftHeader.addView(showWholeFileButton, in: .trailing)
        // Line the headings up with the text in each pane below.
        for header in [diskHeader, draftHeader] {
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 8
            header.edgeInsets = NSEdgeInsets(top: 0, left: 15, bottom: 0, right: 0)
        }
        let headers = NSStackView(views: [diskHeader, draftHeader])
        headers.distribution = .fillEqually
        headers.spacing = 0
        headers.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headers)
        addSubview(webView)
        NSLayoutConstraint.activate([
            headers.topAnchor.constraint(equalTo: topAnchor),
            headers.leadingAnchor.constraint(equalTo: leadingAnchor),
            headers.trailingAnchor.constraint(equalTo: trailingAnchor),
            headers.heightAnchor.constraint(equalToConstant: 24),
            webView.topAnchor.constraint(equalTo: headers.bottomAnchor, constant: 4),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let url = Bundle.main.url(forResource: "mdconflict.min", withExtension: "js",
                                  subdirectory: "Vendor/CodeMirror")
            ?? Bundle.main.url(forResource: "mdconflict.min", withExtension: "js")
        let script = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        webView.loadHTMLString(ConflictDiffHTML.render(disk: disk, draft: draft, javaScript: script), baseURL: nil)
    }

    required init?(coder: NSCoder) { nil }

    private static func columnLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func configureNavigationControl() {
        let previousChange = NSLocalizedString("Previous Change", comment: "Save conflict diff navigation")
        let nextChange = NSLocalizedString("Next Change", comment: "Save conflict diff navigation")
        let previous = NSImage(systemSymbolName: "chevron.left",
                               accessibilityDescription: previousChange) ?? NSImage()
        let next = NSImage(systemSymbolName: "chevron.right",
                           accessibilityDescription: nextChange) ?? NSImage()
        navigationControl.segmentStyle = .rounded
        navigationControl.trackingMode = .momentary
        navigationControl.controlSize = .small
        navigationControl.segmentCount = 2
        for (segment, image, label) in [(0, previous, previousChange), (1, next, nextChange)] {
            image.isTemplate = true
            navigationControl.setImage(image, forSegment: segment)
            navigationControl.setToolTip(label, forSegment: segment)
            navigationControl.setImageScaling(.scaleProportionallyDown, forSegment: segment)
        }
        navigationControl.isEnabled = false
        navigationControl.target = self
        navigationControl.action = #selector(navigate(_:))
    }

    @objc private func navigate(_ sender: NSSegmentedControl) {
        let direction = sender.selectedSegment == 0 ? -1 : 1
        webView.evaluateJavaScript("MDConflictNavigate(\(direction))") { [weak self] result, _ in
            self?.showPosition(result)
        }
    }

    @objc private func showWholeFile(_ sender: NSButton) {
        sender.isEnabled = false
        webView.evaluateJavaScript("MDConflictShowWholeFile()") { [weak sender] _, error in
            if error != nil { sender?.isEnabled = true }
        }
    }

    /// A line-ending-only conflict has no text change to step through; the
    /// alert's message explains it instead.
    private func showPosition(_ result: Any?) {
        guard let position = result as? [Int], position.count == 2, position[1] > 0 else {
            countLabel.isHidden = true
            navigationControl.isHidden = true
            return
        }
        countLabel.stringValue = String(
            format: NSLocalizedString("%d of %d", comment: "Find bar current and total match count"),
            position[0], position[1])
        navigationControl.isEnabled = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__conflictReady === true ? window.__conflictPosition : null") { [weak self] result, _ in
            guard let self else { return }
            let loaded = result is [Int]
            if loaded {
                self.showPosition(result)
                self.showWholeFileButton.isEnabled = true
            }
            self.finishedLoading?(loaded)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishedLoading?(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishedLoading?(false)
    }
}
