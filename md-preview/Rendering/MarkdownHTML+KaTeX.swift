//
//  MarkdownHTML+KaTeX.swift
//  md-preview
//
//  KaTeX, DOMPurify, and morphdom vendor emission.
//

import Foundation

// `nonisolated` matters: the targets default to MainActor isolation, and
// rendering runs off the main actor.
nonisolated extension MarkdownHTML {
    private static let katexFallbackScript = """
    <script>
    window.addEventListener('load', () => {
        document.querySelectorAll('.math').forEach((node) => {
            node.classList.add('math-error');
            node.textContent = \(javaScriptStringLiteral(
                NSLocalizedString(
                    "KaTeX renderer is unavailable.\n\n",
                    comment: "Math rendering error"
                )
            )) + node.textContent;
        });
    });
    </script>
    """

    /// JS body of `function renderMath()`. Shared between inline and lazy
    /// modes — only the surrounding wiring (immediate run vs. deferred-on-load)
    /// differs.
    private static let katexRenderMathBody = """
    function renderMath() {
        document.querySelectorAll('.math').forEach((el) => {
            if (el.dataset.mathDone === '1') return;
            const tex = el.textContent;
            const display = el.classList.contains('math-display');
            // Pre-render source, stashed so MdPreview.update can pair
            // unchanged math with its finished output during DOM diffs.
            el.__mdSrc = tex;
            try {
                katex.render(tex, el, {
                    displayMode: display,
                    throwOnError: false,
                    output: 'htmlAndMathml'
                });
                el.dataset.mathDone = '1';
            } catch (err) {
                el.classList.add('math-error');
                el.textContent = String((err && err.message) || err);
                el.dataset.mathDone = '1';
            }
        });
        window.dispatchEvent(new Event('md-preview-math-rendered'));
    }
    """

    /// Bundled vendor JS as an inline `<script>` block, or empty when the
    /// resource is missing so callers fail soft. The `</script` escape is the
    /// one correctness-sensitive step of inlining — keep it here, in one place.
    private static func bundledVendorScriptTag(_ name: String, subdir: String) -> String {
        guard let js = bundledVendorResource(name, ext: "js", subdir: subdir) else {
            return ""
        }
        let safeJS = js.replacingOccurrences(of: "</script", with: "<\\/script")
        return "<script>\(safeJS)</script>"
    }

    /// Inline DOMPurify so the bootstrap can call `DOMPurify.sanitize` before
    /// the first article ever reaches `innerHTML`. Emitted ahead of the host
    /// bridge so the sanitizer is defined by the time `MdPreview.update` runs.
    /// If the vendored file is missing (developer setup error), this is empty
    /// and the bootstrap's `sanitize()` fails closed — rendering an empty
    /// article rather than shipping unsanitized HTML.
    /// Cached: bundle contents are immutable for the process lifetime, and
    /// `render()` runs on every display, so the disk read happens once.
    static let dompurifyBlock = bundledVendorScriptTag("purify.min", subdir: "Vendor/DOMPurify")

    /// Inline morphdom so `MdPreview.update` can DOM-diff fast-path updates
    /// instead of replacing the whole article subtree — finished Mermaid
    /// SVGs, KaTeX output, and highlighted code survive updates untouched.
    /// If the vendored file is missing (SPM tests, Quick Look bundle), this
    /// is empty and `MdPreview.update` keeps its innerHTML fallback. Cached
    /// for the same reason as `dompurifyBlock`.
    static let morphdomBlock = bundledVendorScriptTag("morphdom.min", subdir: "Vendor/Morphdom")

    static func katexHead(mode: VendorLoading) -> VendorEmission {
        guard bundledVendorURL("katex.min", ext: "js", subdir: "Vendor/KaTeX") != nil else {
            return VendorEmission(head: katexFallbackScript)
        }
        let css = bundledVendorResource("katex.min", ext: "css", subdir: "Vendor/KaTeX") ?? ""

        let initScript = """
        <script>
        (function() {
            \(katexRenderMathBody)
            if (window.MdPreview && window.MdPreview.registerReapplier) {
                window.MdPreview.registerReapplier(renderMath);
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', renderMath, { once: true });
            } else {
                renderMath();
            }
        })();
        </script>
        """

        switch mode {
        case .inline:
            let js = bundledVendorResource("katex.min", ext: "js", subdir: "Vendor/KaTeX") ?? ""
            let copyTex = bundledVendorResource("copy-tex.min", ext: "js", subdir: "Vendor/KaTeX") ?? ""
            let safeJS = js.replacingOccurrences(of: "</script", with: "<\\/script")
            let safeCopyTex = copyTex.replacingOccurrences(of: "</script", with: "<\\/script")
            return VendorEmission(
                head: "<style>\(css)</style>",
                body: """
                <script>\(safeJS)</script>
                \(initScript)
                \(safeCopyTex.isEmpty ? "" : "<script>\(safeCopyTex)</script>")
                """
            )
        case .lazy:
            // CSS stays inline so layout is stable while KaTeX JS streams in.
            return VendorEmission(head: """
            <style>\(css)</style>
            <script>
            (function() {
                \(katexRenderMathBody)
                window.MdPreviewLazy.lazyRenderer({
                    src: '\(MarkdownAssetScheme.vendorURL("katex.min.js"))',
                    extras: ['\(MarkdownAssetScheme.vendorURL("copy-tex.min.js"))'],
                    run: renderMath,
                });
            })();
            </script>
            """)
        }
    }
}
