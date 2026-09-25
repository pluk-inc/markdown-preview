//
//  MarkdownAccessPolicy.swift
//  md-preview
//

import Foundation

/// Which folder a document's *automatic* asset loads may read from.
///
/// A folder the reader explicitly opened wins for documents inside it, so a
/// project keeps working: `docs/guide.md` reaches `../images/logo.png`.
/// Everything else falls back to the document's own folder — that is what a
/// standalone file gets, and what Quick Look always gets.
///
/// This governs only loads that happen because a document was rendered —
/// nobody asked for them, so they stay silent and bounded. A link the reader
/// clicks is a different question: the click is the decision, and the
/// destination gets this same boundary applied fresh, for its own assets.
///
/// Pure Foundation, so the helper test package covers it.
nonisolated enum MarkdownAccessPolicy {

    /// The folder that bounds a document's asset loads.
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
}
