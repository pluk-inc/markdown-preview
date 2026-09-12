//
//  MarkdownAccessPolicy.swift
//  md-preview
//

import Foundation

/// Which folder a document may read from, and what a click on a link
/// pointing outside it should do.
///
/// These are two questions, deliberately kept apart. An asset load happens
/// because a document was rendered — nobody asked for it, so it stays silent
/// and bounded. A link click happened because the reader asked, so it may
/// offer a way through, with the reader deciding and the target named.
///
/// Pure Foundation, so the helper test package covers it.
nonisolated enum MarkdownAccessPolicy {

    /// The folder that bounds a document's asset loads and link targets.
    ///
    /// A folder the reader explicitly opened wins for documents inside it, so
    /// a project keeps working: `docs/guide.md` reaches `../images/logo.png`.
    /// Everything else falls back to the document's own folder — that is what
    /// a standalone file gets, and what Quick Look always gets.
    ///
    /// The opened folder is never derived from where a document sits. See
    /// `MarkdownAssetResolution` for why a boundary that widens with the
    /// document's location is not a boundary at all.
    static func containmentRoot(documentFolder: URL?, openedFolder: URL?) -> URL? {
        guard let documentFolder else { return nil }
        guard let openedFolder,
              MarkdownAssetResolution.isContained(documentFolder, in: openedFolder)
        else { return documentFolder }
        return openedFolder
    }

    /// The opened folder that survives loading a document: kept while the
    /// document is inside it, dropped otherwise.
    ///
    /// Dropping it matters because the file navigator re-roots to the new
    /// file at that same moment. A boundary that stayed behind while the
    /// sidebar showed something else would be one nobody could see.
    static func openedFolder(_ openedFolder: URL?, afterLoading documentFolder: URL?) -> URL? {
        guard let openedFolder, let documentFolder,
              MarkdownAssetResolution.isContained(documentFolder, in: openedFolder)
        else { return nil }
        return openedFolder
    }

    /// What activating a link should do.
    enum LinkAction: Equatable {
        /// A Markdown file inside the boundary: open it in the viewer.
        case openInViewer(URL)
        /// Another file type inside the boundary: hand it to the system.
        case openWithSystem(URL)
        /// Not a filesystem target at all — http, https, mailto. No boundary
        /// applies, and the reader's click is the whole of the decision.
        case openExternally(URL)
        /// Inside the boundary, but something the system would run or install
        /// rather than open. Shown in Finder after confirming, never started.
        case confirmRevealExecutable(URL)
        /// A Markdown file outside the boundary: confirm, then open it in the
        /// viewer, where it is rendered under its own boundary.
        case confirmOpenOutside(URL)
        /// Another file type outside the boundary: confirm, then reveal it in
        /// Finder. Never launched — document content named this path, and
        /// launching it would run whatever it points at.
        case confirmRevealOutside(URL)
        /// The document has no folder yet, so a relative link cannot resolve
        /// to anything. Offer to save it rather than doing nothing.
        case saveDocumentFirst
        /// Vendor URLs, and anything naming no file at all.
        case ignore
    }

    /// Decides what a clicked `md-asset:` link should do.
    ///
    /// `isMarkdown` is supplied by the caller so this stays free of the
    /// document-type list, which lives with the view.
    static func linkAction(for url: URL,
                           documentFolder: URL?,
                           containmentRoot: URL?,
                           isMarkdown: (URL) -> Bool,
                           isExecutable: (URL) -> Bool) -> LinkAction {
        switch url.scheme?.lowercased() {
        case MarkdownAssetResolution.scheme:
            // A relative reference, resolved by the page against its <base>.
            guard !url.path.hasPrefix(MarkdownAssetResolution.vendorPathPrefix) else {
                return .ignore
            }
            // No folder: an unsaved document. Relative references have nothing
            // to resolve against, which is a reason to say so, not to ignore
            // the click.
            guard documentFolder != nil else { return .saveDocumentFirst }
            guard let target = MarkdownAssetResolution.candidateFileURL(for: url) else {
                return .ignore
            }
            return action(for: target,
                          containmentRoot: containmentRoot,
                          isMarkdown: isMarkdown,
                          isExecutable: isExecutable)

        case "file":
            // An absolute `file:` URL names a path outright, so it never goes
            // near the page's <base>. The boundary has to be applied here or
            // it does not apply at all — which is how such a link used to
            // reach NSWorkspace with no check, opening or launching anything
            // the document named.
            guard url.host?.isEmpty ?? true else { return .ignore }
            let target = url.standardizedFileURL
            guard target.path.count > 1 else { return .ignore }
            return action(for: target,
                          containmentRoot: containmentRoot,
                          isMarkdown: isMarkdown,
                          isExecutable: isExecutable)

        case .some:
            // http, https, mailto and the rest name no file, so no boundary
            // bears on them.
            return .openExternally(url)

        case .none:
            return .ignore
        }
    }

    /// The decision once a link has been reduced to a path, whichever scheme
    /// named it.
    private static func action(for target: URL,
                               containmentRoot: URL?,
                               isMarkdown: (URL) -> Bool,
                               isExecutable: (URL) -> Bool) -> LinkAction {
        if let containmentRoot,
           MarkdownAssetResolution.isContained(target, in: containmentRoot) {
            if isMarkdown(target) { return .openInViewer(target) }
            // Handing a document to the system is what a link to a PDF or an
            // image is for. Something the system would run or install is not a
            // document, and no Markdown file has reason to start one — for
            // those, "open" means execute — so it is shown instead.
            return isExecutable(target) ? .confirmRevealExecutable(target) : .openWithSystem(target)
        }
        return isMarkdown(target) ? .confirmOpenOutside(target) : .confirmRevealOutside(target)
    }
}
