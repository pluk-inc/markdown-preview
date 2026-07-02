//
//  ContentAreaViewController.swift
//  md-preview
//

import Cocoa

/// Hosts the rendered preview and the inline source editor in the same
/// content pane, one visible at a time. The Edit toolbar button / ⇧⌘E flips
/// `isEditing`; the split-view geometry never changes, so reading and
/// editing swap in place like a mode switch rather than a side-by-side
/// split.
final class ContentAreaViewController: NSViewController {

    let previewViewController = ContentViewController()
    let editorViewController = EditorViewController()

    /// Fired whenever `isEditing` changes, from any caller.
    var onEditingChange: ((Bool) -> Void)?

    var isEditing = false {
        didSet {
            guard isEditing != oldValue, isViewLoaded else { return }
            if !isEditing {
                // Deliver any keystrokes still in the debounce window so
                // the preview that's about to appear shows the full text.
                editorViewController.flushPendingChanges()
            }
            editorViewController.view.isHidden = !isEditing
            previewViewController.view.isHidden = isEditing
            if isEditing {
                editorViewController.focus()
            }
            onEditingChange?(isEditing)
        }
    }

    override func loadView() {
        view = NSView()

        addChild(previewViewController)
        addChild(editorViewController)

        for childView in [previewViewController.view, editorViewController.view] {
            childView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(childView)
            NSLayoutConstraint.activate([
                childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                childView.topAnchor.constraint(equalTo: view.topAnchor),
                childView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
        }

        editorViewController.view.isHidden = true
    }
}
