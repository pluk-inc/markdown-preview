//
//  MarkdownHTML+Highlight.swift
//  md-preview
//
//  Code highlighting via highlight.js.
//

import Foundation

// `nonisolated` matters: the targets default to MainActor isolation, and
// rendering runs off the main actor.
nonisolated extension MarkdownHTML {
    // MARK: - Code highlighting (highlight.js)

    // Excludes `language-mermaid` since renderMermaidBlocks already lifted
    // those into `<figure>` containers before this runs.
    private static let highlightableCodeRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            // Block elements now carry source-line attributes for scroll
            // handoff, so do not require <pre> and <code> to be bare tags.
            pattern: #"<pre\b[^>]*>\s*<code\b(?![^>]*\blanguage-mermaid\b)[^>]*>"#
        )
    }()

    static func detectHighlightableCode(in html: String) -> Bool {
        firstMatch(of: highlightableCodeRegex, in: html) != nil
    }

    /// Yields via rAF every ~8 ms so the main thread is never pinned for
    /// more than one frame on docs with many code blocks.
    /// Internal so the WebKit regression tests can exercise the exact script
    /// shipped by the app with the bundled highlight.js runtime.
    static let highlightAllBody = """
    function autoDetectCodeLanguage(source) {
        const text = (source || '').trim();
        if (!text) return '';
        if (/^#!.*\\b(?:ba)?sh\\b|^\\s*\\$\\s+/.test(text)) return 'bash';
        if (/\\b(?:resource|data|provider|variable|module)\\s+[\"'][\\w-]+[\"'](?:\\s+[\"'][\\w-]+[\"'])?\\s*\\{|\\bterraform\\s*\\{/.test(text)) return 'hcl';
        if ((text[0] === '{' && text[text.length - 1] === '}')
            || (text[0] === '[' && text[text.length - 1] === ']')) {
            try { JSON.parse(text); return 'json'; } catch (_) {}
        }
        if (/^\\s*(?:<!DOCTYPE\\s+html|<html\\b|<(?:div|span|section|article)\\b)/i.test(text)) return 'html';
        if (/^\\s*(?:async\\s+)?def\\s+\\w+\\s*\\(|^\\s*from\\s+\\w+[\\w.]*\\s+import\\b/m.test(text)) return 'python';
        if (/\\b(?:import\\s+Foundation|func\\s+\\w+\\s*\\(|@main)\\b|\\b(?:let|var)\\s+\\w+\\s*:\\s*(?:String|Int|Bool|Double|Float)\\b/.test(text)) return 'swift';
        if (/^\\s*(?:#\\s*include\\s*<iostream>|(?:using\\s+namespace\\s+std|std::\\w+|(?:cout|cin)\\s*(?:<<|>>))\\b)/m.test(text)) return 'cpp';
        if (/^\\s*(?:#\\s*include\\s*[<"](?:assert|ctype|errno|float|inttypes|limits|math|setjmp|signal|stdarg|stdbool|stddef|stdint|stdio|stdlib|string|time)\\.h[>"]|(?:int|void)\\s+main\\s*\\([^)]*\\)\\s*\\{)/m.test(text)) return 'c';
        if (/\\b(?:SELECT|INSERT|UPDATE|DELETE|CREATE\\s+(?:TABLE|VIEW|INDEX)|WITH)\\b[\\s\\S]*\\b(?:FROM|INTO|WHERE|AS)\\b/i.test(text)) return 'sql';
        if (/(?:^|\\n)\\s*(?:[#.]?[A-Za-z][\\w-]*)\\s*\\{[\\s\\S]*:[\\s\\S]*\\}/.test(text)
            || /@(?:media|keyframes|supports)\\b/.test(text)) return 'css';
        if (/^\\s*(?:const|let|var)\\s+[A-Za-z_$][\\w$]*\\s*(?::[^=\\n]+)?\\s*=/m.test(text)
            || /\\b(?:function\\s+\\w+\\s*\\(|console\\.(?:log|error|warn)|=>)/.test(text)) return 'javascript';
        if (/^\\s*(?:[-A-Za-z_][\\w-]*):\\s*(?:[^:#\\n]|$)/m.test(text)
            && !/[{};]/.test(text)) return 'yaml';

        // The vendored Terraform grammar has high auto-detection relevance,
        // so only use highlight.js fallback with a curated language set.
        const candidates = [
            'javascript', 'typescript', 'python', 'json', 'css', 'xml',
            'bash', 'swift', 'go', 'ruby', 'rust', 'c', 'cpp', 'java', 'kotlin',
            'csharp', 'sql', 'yaml', 'toml'
        ];
        const result = hljs.highlightAuto(text, candidates);
        return result && result.relevance >= 2 ? (result.language || '') : '';
    }

    function decorateShellOptions(block) {
        if (!block.classList.contains('language-bash')) return;
        const textNodes = [];
        const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
            const parent = walker.currentNode.parentElement;
            if (!parent || parent.closest('.hljs-comment, .hljs-string, .hljs-meta, .hljs-attr')) continue;
            textNodes.push(walker.currentNode);
        }
        const optionPattern = /(^|[\\s=])(-{1,2}[A-Za-z][A-Za-z0-9-]*)(?=$|[=\\s;&|)])/g;
        textNodes.forEach((node) => {
            const source = node.nodeValue || '';
            let match;
            let cursor = 0;
            let changed = false;
            const fragment = document.createDocumentFragment();
            optionPattern.lastIndex = 0;
            while ((match = optionPattern.exec(source)) !== null) {
                const optionStart = match.index + match[1].length;
                fragment.append(document.createTextNode(source.slice(cursor, optionStart)));
                const span = document.createElement('span');
                span.className = 'hljs-attr';
                span.textContent = match[2];
                fragment.append(span);
                cursor = optionStart + match[2].length;
                changed = true;
            }
            if (changed) {
                fragment.append(document.createTextNode(source.slice(cursor)));
                node.replaceWith(fragment);
            }
        });
    }

    function highlightAll() {
        if (typeof hljs === 'undefined') return;
        if (!document.querySelector('pre > code:not([data-hljs-done="1"])')) return;
        const blocks = Array.prototype.slice.call(
            document.querySelectorAll('pre > code:not([data-hljs-done="1"])')
        );
        MdPreviewPerf.log('hljs highlightAll start', blocks.length + ' blocks');
        let i = 0;
        function step() {
            const sliceStart = MdPreviewPerf.now();
            while (i < blocks.length) {
                const block = blocks[i++];
                // Pre-render source, stashed so MdPreview.update can pair
                // unchanged blocks with their highlights during DOM diffs.
                block.__mdSrc = block.textContent;
                try {
                    const explicit = Array.from(block.classList)
                        .find((name) => name.startsWith('language-'));
                    if (explicit === 'language-mermaid') {
                        block.dataset.hljsDone = '1';
                        continue;
                    }
                    if (!explicit) {
                        const detected = autoDetectCodeLanguage(block.__mdSrc);
                        if (detected) {
                            block.classList.add('language-' + detected);
                            block.dataset.mdDetectedLanguage = detected;
                        }
                    }
                    if (Array.from(block.classList).some((name) => name.startsWith('language-'))) {
                        hljs.highlightElement(block);
                        decorateShellOptions(block);
                    }
                } catch (e) {
                    MdPreviewPerf.log('hljs threw', String(e && e.message || e));
                }
                block.dataset.hljsDone = '1';
                if (MdPreviewPerf.now() - sliceStart > 8) break;
            }
            if (i < blocks.length) {
                requestAnimationFrame(step);
            } else {
                window.dispatchEvent(new Event('md-preview-hljs-rendered'));
                MdPreviewPerf.log('hljs all done');
            }
        }
        requestAnimationFrame(step);
    }
    """

    /// highlight.js ships light rules plus a system-dark media query. These
    /// higher-specificity rules let an explicit Quick Look mode override that
    /// media query without changing automatic mode in the document app.
    private static let highlightForcedColorSchemeStyles = """
    html[data-mdp-color-scheme="light"] .hljs { color: #24292e; }
    html[data-mdp-color-scheme="light"] .hljs-doctag,
    html[data-mdp-color-scheme="light"] .hljs-keyword,
    html[data-mdp-color-scheme="light"] .hljs-meta .hljs-keyword,
    html[data-mdp-color-scheme="light"] .hljs-template-tag,
    html[data-mdp-color-scheme="light"] .hljs-template-variable,
    html[data-mdp-color-scheme="light"] .hljs-type,
    html[data-mdp-color-scheme="light"] .hljs-variable.language_ { color: #d73a49; }
    html[data-mdp-color-scheme="light"] .hljs-title,
    html[data-mdp-color-scheme="light"] .hljs-title.class_,
    html[data-mdp-color-scheme="light"] .hljs-title.class_.inherited__,
    html[data-mdp-color-scheme="light"] .hljs-title.function { color: #6f42c1; }
    html[data-mdp-color-scheme="light"] .hljs-attr,
    html[data-mdp-color-scheme="light"] .hljs-attribute,
    html[data-mdp-color-scheme="light"] .hljs-literal,
    html[data-mdp-color-scheme="light"] .hljs-meta,
    html[data-mdp-color-scheme="light"] .hljs-number,
    html[data-mdp-color-scheme="light"] .hljs-operator,
    html[data-mdp-color-scheme="light"] .hljs-selector-attr,
    html[data-mdp-color-scheme="light"] .hljs-selector-class,
    html[data-mdp-color-scheme="light"] .hljs-selector-id,
    html[data-mdp-color-scheme="light"] .hljs-variable { color: #005cc5; }
    html[data-mdp-color-scheme="light"] .hljs-meta .hljs-string,
    html[data-mdp-color-scheme="light"] .hljs-regexp,
    html[data-mdp-color-scheme="light"] .hljs-string { color: #032f62; }
    html[data-mdp-color-scheme="light"] .hljs-built_in,
    html[data-mdp-color-scheme="light"] .hljs-symbol { color: #e36209; }
    html[data-mdp-color-scheme="light"] .hljs-code,
    html[data-mdp-color-scheme="light"] .hljs-comment,
    html[data-mdp-color-scheme="light"] .hljs-formula { color: #6a737d; }
    html[data-mdp-color-scheme="light"] .hljs-name,
    html[data-mdp-color-scheme="light"] .hljs-quote,
    html[data-mdp-color-scheme="light"] .hljs-selector-pseudo,
    html[data-mdp-color-scheme="light"] .hljs-selector-tag { color: #22863a; }
    html[data-mdp-color-scheme="light"] .hljs-subst,
    html[data-mdp-color-scheme="light"] .hljs-emphasis,
    html[data-mdp-color-scheme="light"] .hljs-strong { color: #24292e; }
    html[data-mdp-color-scheme="light"] .hljs-section { color: #005cc5; }
    html[data-mdp-color-scheme="light"] .hljs-bullet { color: #735c0f; }
    html[data-mdp-color-scheme="light"] .hljs-addition { color: #22863a; background-color: #f0fff4; }
    html[data-mdp-color-scheme="light"] .hljs-deletion { color: #b31d28; background-color: #ffeef0; }

    html[data-mdp-color-scheme="dark"] .hljs { color: #c9d1d9; }
    html[data-mdp-color-scheme="dark"] .hljs-doctag,
    html[data-mdp-color-scheme="dark"] .hljs-keyword,
    html[data-mdp-color-scheme="dark"] .hljs-meta .hljs-keyword,
    html[data-mdp-color-scheme="dark"] .hljs-template-tag,
    html[data-mdp-color-scheme="dark"] .hljs-template-variable,
    html[data-mdp-color-scheme="dark"] .hljs-type,
    html[data-mdp-color-scheme="dark"] .hljs-variable.language_ { color: #ff7b72; }
    html[data-mdp-color-scheme="dark"] .hljs-title,
    html[data-mdp-color-scheme="dark"] .hljs-title.class_,
    html[data-mdp-color-scheme="dark"] .hljs-title.class_.inherited__,
    html[data-mdp-color-scheme="dark"] .hljs-title.function { color: #d2a8ff; }
    html[data-mdp-color-scheme="dark"] .hljs-attr,
    html[data-mdp-color-scheme="dark"] .hljs-attribute,
    html[data-mdp-color-scheme="dark"] .hljs-literal,
    html[data-mdp-color-scheme="dark"] .hljs-meta,
    html[data-mdp-color-scheme="dark"] .hljs-number,
    html[data-mdp-color-scheme="dark"] .hljs-operator,
    html[data-mdp-color-scheme="dark"] .hljs-selector-attr,
    html[data-mdp-color-scheme="dark"] .hljs-selector-class,
    html[data-mdp-color-scheme="dark"] .hljs-selector-id,
    html[data-mdp-color-scheme="dark"] .hljs-variable { color: #79c0ff; }
    html[data-mdp-color-scheme="dark"] .hljs-meta .hljs-string,
    html[data-mdp-color-scheme="dark"] .hljs-regexp,
    html[data-mdp-color-scheme="dark"] .hljs-string { color: #a5d6ff; }
    html[data-mdp-color-scheme="dark"] .hljs-built_in,
    html[data-mdp-color-scheme="dark"] .hljs-symbol { color: #ffa657; }
    html[data-mdp-color-scheme="dark"] .hljs-code,
    html[data-mdp-color-scheme="dark"] .hljs-comment,
    html[data-mdp-color-scheme="dark"] .hljs-formula { color: #8b949e; }
    html[data-mdp-color-scheme="dark"] .hljs-name,
    html[data-mdp-color-scheme="dark"] .hljs-quote,
    html[data-mdp-color-scheme="dark"] .hljs-selector-pseudo,
    html[data-mdp-color-scheme="dark"] .hljs-selector-tag { color: #7ee787; }
    html[data-mdp-color-scheme="dark"] .hljs-subst,
    html[data-mdp-color-scheme="dark"] .hljs-emphasis,
    html[data-mdp-color-scheme="dark"] .hljs-strong { color: #c9d1d9; }
    html[data-mdp-color-scheme="dark"] .hljs-section { color: #1f6feb; }
    html[data-mdp-color-scheme="dark"] .hljs-bullet { color: #f2cc60; }
    html[data-mdp-color-scheme="dark"] .hljs-addition { color: #aff5b4; background-color: #033a16; }
    html[data-mdp-color-scheme="dark"] .hljs-deletion { color: #ffdcd7; background-color: #67060c; }
    """

    static func highlightHead(mode: VendorLoading) -> VendorEmission {
        guard bundledVendorURL("highlight.min", ext: "js", subdir: "Vendor/Highlight") != nil else {
            return VendorEmission()
        }
        let css = bundledVendorResource("highlight.min", ext: "css", subdir: "Vendor/Highlight") ?? ""
        let themedCSS = css + "\n" + highlightForcedColorSchemeStyles

        let initScript = """
        <script>
        (function() {
            \(highlightAllBody)
            if (window.MdPreview && window.MdPreview.registerReapplier) {
                window.MdPreview.registerReapplier(highlightAll);
            }
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', highlightAll, { once: true });
            } else {
                highlightAll();
            }
        })();
        </script>
        """

        switch mode {
        case .inline:
            let js = bundledVendorResource("highlight.min", ext: "js", subdir: "Vendor/Highlight") ?? ""
            let safeJS = js.replacingOccurrences(of: "</script", with: "<\\/script")
            return VendorEmission(
                head: "<style>\(themedCSS)</style>",
                body: """
                <script>\(safeJS)</script>
                \(initScript)
                """
            )
        case .lazy:
            // CSS stays inline so layout doesn't shift when the JS arrives.
            return VendorEmission(head: """
            <style>\(themedCSS)</style>
            <script>
            (function() {
                \(highlightAllBody)
                window.MdPreviewLazy.lazyRenderer({
                    src: '\(MarkdownAssetScheme.vendorURL("highlight.min.js"))',
                    run: highlightAll,
                });
            })();
            </script>
            """)
        }
    }
}
