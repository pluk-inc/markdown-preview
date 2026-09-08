//
//  QuickLookFirstResponderPolicy.swift
//  quick-look
//

import Foundation

/// Whether the Quick Look preview may pull keyboard focus to itself when its
/// content finishes loading.
///
/// It must not. A Quick Look preview is a guest inside its host (Finder,
/// QuickLookUIService). The host owns keyboard navigation: arrow keys move
/// the selection between files, space toggles the panel. When the preview
/// makes its web view first responder on load, those keys are swallowed by
/// the web view as scroll commands and never reach the host — so once the
/// selection lands on a Markdown file, arrow-key file navigation stops
/// (pluk-inc/markdown-preview#292). Apple's own text and PDF previews never
/// seize focus either; the user clicks into the preview to interact with it.
///
/// ⌘A / ⌘C still work without a click: `QuickLookWebView.performKeyEquivalent`
/// claims those chords through the key window's view hierarchy, which does
/// not depend on first-responder status.
nonisolated enum QuickLookFirstResponderPolicy {
    /// Reason string pinned by the tests so a future change that flips the
    /// value has to confront why it is `false`.
    static let rationale = """
    The Quick Look host owns keyboard navigation; claiming first responder \
    on load breaks arrow-key file navigation (pluk-inc/markdown-preview#292).
    """

    /// `false` — the preview waits for a user click to become first responder.
    static let claimsFirstResponderOnLoad = false
}
