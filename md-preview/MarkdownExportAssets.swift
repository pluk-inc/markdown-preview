//
//  MarkdownExportAssets.swift
//  md-preview
//

import Foundation

/// HTML/CSS/JS fragments injected into the document only when rendering for
/// PDF export. Pure string builders (Foundation only) so they are unit-tested
/// in the SwiftPM helper package without WebKit. `MarkdownHTML.render` calls
/// `headInjection(...)` when `forExport` is true.
nonisolated enum MarkdownExportAssets {

    /// Print-oriented CSS overrides. Light color scheme is enforced by the
    /// export web view's NSAppearance (so KaTeX/Mermaid/CSS media queries all
    /// resolve light); this stylesheet only removes interactive chrome, keeps
    /// background colors when printing, sets page margins, and avoids ugly
    /// breaks inside code/tables/diagrams.
    static let stylesheet = """
    @page { margin: 18mm; }
    :root { color-scheme: light; }
    body {
        -webkit-print-color-adjust: exact;
        print-color-adjust: exact;
    }
    .md-code-copy { display: none !important; }
    .mermaid-hud { display: none !important; }
    mark.md-search-highlight {
        background: transparent !important;
        color: inherit !important;
        box-shadow: none !important;
    }
    pre, .md-code-wrap, table, .mermaid-figure {
        break-inside: avoid;
    }
    """

    /// `<script>` that waits until the document has fully loaded and every
    /// expected renderer has marked its elements done, then posts
    /// `{kind:"renderComplete"}` to the host. Polls (rather than relying on
    /// one-shot events) so it is robust to renderers that finish before this
    /// script attaches. The Swift side also applies a hard timeout.
    static func readinessScript(containsMath: Bool,
                                containsMermaid: Bool,
                                containsCode: Bool) -> String {
        """
        <script>
        (() => {
            const expectMath = \(containsMath ? "true" : "false");
            const expectMermaid = \(containsMermaid ? "true" : "false");
            const expectCode = \(containsCode ? "true" : "false");

            function ready() {
                if (document.readyState !== 'complete') return false;
                if (expectMath &&
                    document.querySelector('.math:not([data-math-done="1"])')) {
                    return false;
                }
                if (expectCode &&
                    document.querySelector('pre code[class*="language-"]:not([data-hljs-done="1"])')) {
                    return false;
                }
                if (expectMermaid) {
                    const nodes = document.querySelectorAll('.mermaid');
                    for (const node of nodes) {
                        const figure = node.closest('.mermaid-figure');
                        const errored = figure && figure.classList.contains('mermaid-error');
                        if (node.dataset.mmDone !== '1' && !errored) return false;
                    }
                }
                return true;
            }

            function post() {
                try {
                    const h = window.webkit && window.webkit.messageHandlers
                        && window.webkit.messageHandlers.mdPreviewHost;
                    if (h) h.postMessage({ kind: 'renderComplete' });
                } catch (e) {}
            }

            let done = false;
            function check() {
                if (done) return;
                if (ready()) { done = true; post(); return; }
                setTimeout(check, 50);
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', check, { once: true });
            } else {
                check();
            }
        })();
        </script>
        """
    }

    /// Everything injected into `<head>` for an export render: the eager-render
    /// flag (so Mermaid renders all figures instead of waiting for the
    /// IntersectionObserver), the print stylesheet, and the readiness script.
    /// The flag script must precede the renderer scripts in the head, which is
    /// where `MarkdownHTML.render` places this injection.
    static func headInjection(containsMath: Bool,
                              containsMermaid: Bool,
                              containsCode: Bool) -> String {
        """
        <script>window.__mdPreviewRenderAll = true;</script>
        <style>\(stylesheet)</style>
        \(readinessScript(containsMath: containsMath,
                          containsMermaid: containsMermaid,
                          containsCode: containsCode))
        """
    }
}
