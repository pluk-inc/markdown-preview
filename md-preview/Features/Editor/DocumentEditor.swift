//
//  DocumentEditor.swift
//  md-preview
//

import Foundation

/// What an edit session needs of the view that the reader types in. Two
/// views are one: the web editor, and the native renderer's view when the
/// native renderer is on.
@MainActor
protocol DocumentEditor: AnyObject {
    /// The reader changed the text.
    var contentDidChange: (() -> Void)? { get set }
    /// The reader asked to leave Edit mode (Escape).
    var cancelRequested: (() -> Void)? { get set }
    /// The Markdown text as it is now.
    func fetchMarkdown(_ completion: @escaping (String?) -> Void)
    /// Takes another text: the file changed on disk and the reader chose it.
    func load(markdown: String, assetBaseURL: URL?)
}

extension EditorViewController: DocumentEditor {}
