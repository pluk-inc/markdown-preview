//
//  EditorViewController.swift
//  md-preview
//

import Cocoa

/// View controller wrapping an `NSScrollView` + `NSTextView` for editing Markdown source.
///
/// Text changes are debounced and reported via `onTextChange`. Syntax highlighting
/// is applied separately with a shorter debounce (50ms) to keep the editor responsive.
final class EditorViewController: NSViewController, NSTextViewDelegate {

    /// Called (debounced at 200ms) whenever the user edits text.
    /// The `String` parameter is the full document text.
    var onTextChange: ((String) -> Void)?

    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var highlighter: MarkdownSyntaxHighlighter!
    private var debounceWork: DispatchWorkItem?
    private var highlightDebounce: DispatchWorkItem?
    private static let debounceDelay: TimeInterval = 0.20
    private static let highlightDelay: TimeInterval = 0.05  // 50ms — fast enough to feel instant

    /// Defensive guard: `NSTextView.string =` typically does not fire `textDidChange`,
    /// but edge cases (undo coalescing, input methods) may. Costs nothing to keep.
    private var isSettingText = false

    /// The current text in the editor. Returns empty string if the view is not loaded.
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

    /// Sets the text view content programmatically without triggering `onTextChange`.
    ///
    /// Use this for file loads and external reloads. The method applies syntax
    /// highlighting after setting the text.
    ///
    /// - Parameter text: The Markdown source to display.
    func setMarkdown(_ text: String) {
        isSettingText = true
        textView.string = text
        isSettingText = false
        guard let storage = textView?.textStorage else { return }
        highlighter.applyHighlighting(to: storage)
    }

    func insertMarkdownSnippet(_ snippet: String) {
        textView.insertText(snippet, replacementRange: textView.selectedRange())
    }

    override func becomeFirstResponder() -> Bool {
        view.window?.makeFirstResponder(textView) ?? false
    }

    func textDidChange(_ notification: Notification) {
        guard !isSettingText else { return }

        // Debounce highlighting to avoid blocking main thread on every keystroke
        highlightDebounce?.cancel()
        let highlightWork = DispatchWorkItem { [weak self] in
            guard let self, let storage = self.textView?.textStorage else { return }
            self.highlighter.applyHighlighting(to: storage)
        }
        highlightDebounce = highlightWork
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightDelay, execute: highlightWork)

        // Debounce render pipeline (existing)
        debounceWork?.cancel()
        let capturedText = textView.string
        let work = DispatchWorkItem { [weak self] in
            self?.onTextChange?(capturedText)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceDelay, execute: work)
    }
}
