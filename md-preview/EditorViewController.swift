//
//  EditorViewController.swift
//  md-preview
//

import Cocoa

final class EditorViewController: NSViewController, NSTextViewDelegate {

    /// Called (debounced) whenever the user edits text. The String is the full document text.
    var onTextChange: ((String) -> Void)?

    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var highlighter: MarkdownSyntaxHighlighter!
    private var debounceWork: DispatchWorkItem?
    private static let debounceDelay: TimeInterval = 0.20

    /// Whether we're programmatically setting text (suppresses onTextChange callback)
    private var isSettingText = false

    var currentText: String {
        textView?.string ?? ""
    }

    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.delegate = self

        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainerInset = NSSize(width: 16, height: 16)

        scrollView.documentView = textView
        view = scrollView

        highlighter = MarkdownSyntaxHighlighter()
    }

    func setMarkdown(_ text: String) {
        isSettingText = true
        textView.string = text
        isSettingText = false
        highlighter.applyHighlighting(to: textView.textStorage!)
    }

    func insertMarkdownSnippet(_ snippet: String) {
        textView.insertText(snippet, replacementRange: textView.selectedRange())
    }

    override func becomeFirstResponder() -> Bool {
        view.window?.makeFirstResponder(textView)
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isSettingText else { return }

        highlighter.applyHighlighting(to: textView.textStorage!)

        debounceWork?.cancel()
        let capturedText = textView.string
        let work = DispatchWorkItem { [weak self] in
            self?.onTextChange?(capturedText)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceDelay, execute: work)
    }
}
