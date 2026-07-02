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

    /// Whether the text view accepts edits. Disabled for files the sandbox
    /// only grants read access to, so autosave never attempts a write the
    /// system would deny.
    var isEditable: Bool = true {
        didSet {
            textView?.isEditable = isEditable
            readOnlyBadge?.isHidden = isEditable
        }
    }

    private var textView: NSTextView!
    private var scrollView: NSScrollView!
    private var readOnlyBadge: NSTextField?
    private var highlighter: MarkdownSyntaxHighlighter!
    private var debounceWork: DispatchWorkItem?
    private var highlightDebounce: DispatchWorkItem?
    private static let debounceDelay: TimeInterval = 0.20
    private static let highlightDelay: TimeInterval = 0.05  // 50ms — fast enough to feel instant

    /// Defensive guard: `NSTextView.string =` typically does not fire `textDidChange`,
    /// but edge cases (undo coalescing, input methods) may. Costs nothing to keep.
    private var isSettingText = false

    /// Markdown handed to `setMarkdown` before the view loaded. The editor
    /// pane starts collapsed, so its view loads lazily — during window
    /// restoration `display()` runs before `loadView` (touching `textView`
    /// then would trap). Applied in `viewDidLoad`, which also defers the
    /// initial full-document highlight until the pane is first shown.
    private var pendingMarkdown: String?

    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        textView = NSTextView()
        textView.isRichText = false
        textView.isEditable = isEditable
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

        installReadOnlyBadge()
        highlighter = MarkdownSyntaxHighlighter()
    }

    private func installReadOnlyBadge() {
        let badge = NSTextField(labelWithString: "Read-only")
        badge.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        badge.textColor = .secondaryLabelColor
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        badge.layer?.cornerRadius = 4
        badge.toolTip = "The sandbox grants read-only access to this file. Open it via File ▸ Open to edit."
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = isEditable
        scrollView.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 8),
            badge.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -12),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            badge.heightAnchor.constraint(equalToConstant: 18)
        ])
        readOnlyBadge = badge
    }

    /// Sets the text view content programmatically without triggering `onTextChange`.
    ///
    /// Use this for file loads and external reloads. Any pending debounced
    /// edit is cancelled — the new content supersedes it — and syntax
    /// highlighting is applied to the fresh text.
    ///
    /// - Parameter text: The Markdown source to display.
    func setMarkdown(_ text: String) {
        debounceWork?.cancel()
        debounceWork = nil
        highlightDebounce?.cancel()
        highlightDebounce = nil
        guard isViewLoaded else {
            pendingMarkdown = text
            return
        }
        pendingMarkdown = nil
        applyMarkdown(text)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let pending = pendingMarkdown {
            pendingMarkdown = nil
            applyMarkdown(pending)
        }
    }

    private func applyMarkdown(_ text: String) {
        isSettingText = true
        textView.string = text
        isSettingText = false
        guard let storage = textView.textStorage else { return }
        highlighter.applyHighlighting(to: storage)
    }

    /// Delivers any pending (debounced) edit to `onTextChange` immediately.
    ///
    /// Call before the surrounding controller switches files or closes, so
    /// the document model holds the full editor text rather than trailing
    /// it by up to the debounce interval.
    func flushPendingChanges() {
        guard let pending = debounceWork else { return }
        pending.cancel()
        debounceWork = nil
        onTextChange?(textView.string)
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

        // Debounce the render pipeline. The text is read when the work item
        // fires (not captured per keystroke) so fast typing doesn't copy the
        // full document once per character.
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.debounceWork = nil
            self.onTextChange?(self.textView.string)
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceDelay, execute: work)
    }
}
