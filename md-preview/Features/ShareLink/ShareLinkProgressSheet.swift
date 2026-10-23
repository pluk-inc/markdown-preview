//
//  ShareLinkProgressSheet.swift
//  md-preview
//
//  "Uploading Document…" while a share link is created. Uses AppKit's own
//  progress sheet, the private NSProgressPanel (caption, bar, Cancel) that
//  Apple apps show for long saves and exports, loaded from AppKit's
//  NSProgressPanel.nib. Observed on macOS 26 and 27. When the class or nib
//  is missing, an alert sheet with a bar and Cancel takes its place. Either
//  appears only when the upload takes a moment.
//

import AppKit

@MainActor
final class ShareLinkProgressSheet: NSObject {

    private static let delay: Duration = .milliseconds(500)

    private let window: NSWindow
    private let message: String
    private let onCancel: () -> Void
    private var sheet: NSWindow?
    private var isFinished = false

    /// Shows the sheet on `window` after a short delay unless `finish()`
    /// comes first. `onCancel` runs when the user clicks Cancel.
    init(window: NSWindow, message: String, onCancel: @escaping () -> Void) {
        self.window = window
        self.message = message
        self.onCancel = onCancel
        super.init()
        Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            self?.showIfStillRunning()
        }
    }

    func finish() {
        isFinished = true
        guard let sheet else { return }
        window.endSheet(sheet, returnCode: .stop)
    }

    private func showIfStillRunning() {
        guard !isFinished, window.attachedSheet == nil else { return }
        let sheet = Self.systemProgressPanel(message: message, target: self) ?? fallbackAlert()
        self.sheet = sheet
        window.beginSheet(sheet)
    }

    @objc private func cancel(_ sender: Any?) {
        guard !isFinished else { return }
        finish()
        onCancel()
    }

    // MARK: - Sheets

    private static func systemProgressPanel(message: String, target: ShareLinkProgressSheet) -> NSWindow? {
        let make = NSSelectorFromString("progressPanelWithNibName:")
        guard let panelClass = NSClassFromString("NSProgressPanel") as? NSObject.Type,
              panelClass.responds(to: make),
              let panel = panelClass.perform(make, with: "NSProgressPanel")?
                .takeUnretainedValue() as? NSWindow,
              let caption = panel.value(forKey: "captionTextField") as? NSTextField,
              let bar = panel.value(forKey: "progressIndicator") as? NSProgressIndicator,
              let cancel = panel.value(forKey: "cancelButton") as? NSButton
        else { return nil }
        caption.stringValue = message
        caption.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        cancel.target = target
        cancel.action = #selector(ShareLinkProgressSheet.cancel(_:))
        useCloseSymbol(on: cancel, growing: bar)
        return panel
    }

    /// Turns the panel's text Cancel button into a round gray ✕, the way
    /// Pages' progress panel has it, and gives the freed width to the bar.
    private static func useCloseSymbol(on button: NSButton, growing bar: NSProgressIndicator) {
        let side: CGFloat = 18
        let old = button.frame
        button.title = ""
        button.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: L("Cancel"))
        button.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .tertiaryLabelColor
        button.setAccessibilityLabel(L("Cancel"))
        button.frame = NSRect(x: old.maxX - side, y: bar.frame.midY - side / 2, width: side, height: side)
        bar.frame.size.width = button.frame.minX - 12 - bar.frame.minX
    }

    private func fallbackAlert() -> NSWindow {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons[0].target = self
        alert.buttons[0].action = #selector(cancel(_:))
        let bar = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 220, height: 20))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        alert.accessoryView = bar
        alert.layout()
        return alert.window
    }
}
