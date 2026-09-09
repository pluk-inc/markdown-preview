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
    // those into `<figure>` containers before this runs, and blocks the
    // render-time highlighter already finished (`data-hljs-done`), so a page
    // whose code arrived highlighted never loads the in-page runtime.
    private static let highlightableCodeRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            // Block elements now carry source-line attributes for scroll
            // handoff, so do not require <pre> and <code> to be bare tags.
            pattern: #"<pre\b[^>]*>\s*<code\b(?![^>]*\blanguage-mermaid\b)(?![^>]*\bdata-hljs-done\b)[^>]*>"#
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

    /// Code highlighting class rules, appended to `MarkdownHTML.stylesheet`.
    /// Every color is a `--hl-*` variable declared there, so the light,
    /// forced-dark, and system-dark buckets switch the palette in one place
    /// and the editor page can share the same values.
    static let highlightThemeCSS = """
    .hljs { color: var(--hl-plain); background: transparent; }
    .hljs-keyword,
    .hljs-literal,
    .hljs-variable.language_,
    .hljs-template-tag,
    .hljs-name,
    .hljs-selector-tag,
    .hljs-section,
    .hljs-bullet { color: var(--hl-keyword); }
    .hljs-string,
    .hljs-regexp,
    .hljs-meta .hljs-string { color: var(--hl-string); }
    .hljs-number,
    .hljs-char,
    .hljs-symbol { color: var(--hl-number); }
    .hljs-comment,
    .hljs-quote,
    .hljs-formula { color: var(--hl-comment); }
    .hljs-doctag { color: var(--hl-doc-keyword); }
    .hljs-type { color: var(--hl-type); }
    .hljs-built_in { color: var(--hl-builtin); }
    .hljs-title.class_,
    .hljs-title.class_.inherited__ { color: var(--hl-declaration); }
    .hljs-title,
    .hljs-title.function_ { color: var(--hl-function); }
    .hljs-variable,
    .hljs-template-variable,
    .hljs-property,
    .hljs-selector-class,
    .hljs-selector-id,
    .hljs-selector-attr,
    .hljs-selector-pseudo { color: var(--hl-variable); }
    .hljs-meta,
    .hljs-meta .hljs-keyword { color: var(--hl-preprocessor); }
    .hljs-attr,
    .hljs-attribute { color: var(--hl-attribute); }
    .hljs-link { color: var(--hl-url); }
    .hljs-subst,
    .hljs-operator,
    .hljs-punctuation,
    .hljs-params { color: var(--hl-plain); }
    .hljs-emphasis { font-style: italic; }
    .hljs-strong { font-weight: 600; }
    .hljs-addition {
        color: var(--hl-variable);
        background-color: color-mix(in srgb, var(--hl-variable) 12%, transparent);
    }
    .hljs-deletion {
        color: var(--hl-string);
        background-color: color-mix(in srgb, var(--hl-string) 12%, transparent);
    }
    """

    static func highlightHead(mode: VendorLoading) -> VendorEmission {
        guard bundledVendorURL("highlight.min", ext: "js", subdir: "Vendor/Highlight") != nil else {
            return VendorEmission()
        }
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
                body: """
                <script>\(safeJS)</script>
                \(initScript)
                """
            )
        case .lazy:
            return VendorEmission(head: """
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
