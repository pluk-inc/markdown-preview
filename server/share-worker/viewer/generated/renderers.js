/* Generated from the app's MarkdownHTML by ShareViewerKitTests.
   Do not edit; run MDP_WRITE_VIEWER_KIT=1 swift test --filter ShareViewerKitTests. */
(function () {
// The app's renderers log timings through this; the page has no use for them.
window.MdPreviewPerf = window.MdPreviewPerf || { log() {}, now: () => performance.now() };
function autoDetectCodeLanguage(source) {
    const text = (source || '').trim();
    if (!text) return '';
    if (/^#!.*\b(?:ba)?sh\b|^\s*\$\s+/.test(text)) return 'bash';
    if (/\b(?:resource|data|provider|variable|module)\s+["'][\w-]+["'](?:\s+["'][\w-]+["'])?\s*\{|\bterraform\s*\{/.test(text)) return 'hcl';
    if ((text[0] === '{' && text[text.length - 1] === '}')
        || (text[0] === '[' && text[text.length - 1] === ']')) {
        try { JSON.parse(text); return 'json'; } catch (_) {}
    }
    if (/^\s*(?:<!DOCTYPE\s+html|<html\b|<(?:div|span|section|article)\b)/i.test(text)) return 'html';
    if (/^\s*(?:async\s+)?def\s+\w+\s*\(|^\s*from\s+\w+[\w.]*\s+import\b/m.test(text)) return 'python';
    if (/\b(?:import\s+Foundation|func\s+\w+\s*\(|@main)\b|\b(?:let|var)\s+\w+\s*:\s*(?:String|Int|Bool|Double|Float)\b/.test(text)) return 'swift';
    if (/^\s*(?:#\s*include\s*<iostream>|(?:using\s+namespace\s+std|std::\w+|(?:cout|cin)\s*(?:<<|>>))\b)/m.test(text)) return 'cpp';
    if (/^\s*(?:#\s*include\s*[<"](?:assert|ctype|errno|float|inttypes|limits|math|setjmp|signal|stdarg|stdbool|stddef|stdint|stdio|stdlib|string|time)\.h[>"]|(?:int|void)\s+main\s*\([^)]*\)\s*\{)/m.test(text)) return 'c';
    if (/\b(?:SELECT|INSERT|UPDATE|DELETE|CREATE\s+(?:TABLE|VIEW|INDEX)|WITH)\b[\s\S]*\b(?:FROM|INTO|WHERE|AS)\b/i.test(text)) return 'sql';
    if (/(?:^|\n)\s*(?:[#.]?[A-Za-z][\w-]*)\s*\{[\s\S]*:[\s\S]*\}/.test(text)
        || /@(?:media|keyframes|supports)\b/.test(text)) return 'css';
    if (/^\s*(?:const|let|var)\s+[A-Za-z_$][\w$]*\s*(?::[^=\n]+)?\s*=/m.test(text)
        || /\b(?:function\s+\w+\s*\(|console\.(?:log|error|warn)|=>)/.test(text)) return 'javascript';
    if (/^\s*(?:[-A-Za-z_][\w-]*):\s*(?:[^:#\n]|$)/m.test(text)
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
    const optionPattern = /(^|[\s=])(-{1,2}[A-Za-z][A-Za-z0-9-]*)(?=$|[=\s;&|)])/g;
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
function renderMathElement(el, tex, display) {
    try {
        katex.render(tex, el, {
            displayMode: display,
            throwOnError: false,
            output: 'htmlAndMathml'
        });
    } catch (err) {
        el.classList.add('math-error');
        el.textContent = String((err && err.message) || err);
    }
    el.dataset.mathDone = '1';
}
    // Copy as Markdown. The host keeps `window.MdPreview.source` (the
    // document's Markdown) current, and block elements carry their
    // source line range. A selection that covers whole blocks copies
    // those source lines, so lists keep their bullets, links their
    // targets, and code its fences. Partial first or last blocks
    // contribute their selected text; a selection inside one block
    // returns null and copies as text.
    let sourceLineCache = null;
    function sourceLines() {
        const source = window.MdPreview.source;
        if (typeof source !== 'string') return null;
        if (!sourceLineCache || sourceLineCache.source !== source) {
            sourceLineCache = { source, lines: source.split('\n') };
        }
        return sourceLineCache.lines;
    }
    function sourceSpan(block) {
        const start = Number(block.dataset.sourceStart || block.dataset.sourceLine);
        const end = Number(block.dataset.sourceEnd || block.dataset.sourceLine);
        return Number.isInteger(start) && Number.isInteger(end) && start > 0 && end >= start
            ? { start, end } : null;
    }
    function coversBlockEdge(range, block, edge) {
        const probe = document.createRange();
        probe.selectNodeContents(block);
        if (edge === 'start') probe.setEnd(range.startContainer, range.startOffset);
        else probe.setStart(range.endContainer, range.endOffset);
        return probe.toString().trim() === '';
    }
    function selectedTextWithin(range, block) {
        const clipped = document.createRange();
        clipped.selectNodeContents(block);
        if (clipped.compareBoundaryPoints(Range.START_TO_START, range) < 0) {
            clipped.setStart(range.startContainer, range.startOffset);
        }
        if (clipped.compareBoundaryPoints(Range.END_TO_END, range) > 0) {
            clipped.setEnd(range.endContainer, range.endOffset);
        }
        return clipped.toString();
    }
    function markdownForSelection(selection) {
        selection = selection || window.getSelection();
        const lines = sourceLines();
        if (!lines || !selection || selection.rangeCount !== 1) return null;
        const range = selection.getRangeAt(0);
        if (range.collapsed) return null;
        // Select All ranges over the whole body, so ask for overlap, not
        // containment; the block lookups below stay inside the article.
        const article = document.querySelector('.markdown-body');
        if (!article || !range.intersectsNode(article)) return null;
        // DOM order is not source order: footnote definitions render at
        // the end of the article. Take the earliest source start and the
        // latest source end over every block the selection touches,
        // preferring the innermost block on ties so a partial list item
        // contributes its text while the rest of the list copies as source.
        let startBlock = null, endBlock = null, first = null, last = null;
        for (const block of article.querySelectorAll('[data-source-line]')) {
            if (!range.intersectsNode(block)) continue;
            const span = sourceSpan(block);
            if (!span) continue;
            if (!first || span.start <= first.start) { first = span; startBlock = block; }
            if (!last || span.end >= last.end) { last = span; endBlock = block; }
        }
        if (!startBlock || !endBlock) return null;
        if (last.end < first.start) return null;
        const slice = (from, to) => lines.slice(from - 1, to).join('\n');
        const startWhole = coversBlockEdge(range, startBlock, 'start');
        const endWhole = coversBlockEdge(range, endBlock, 'end');
        // Nothing rendered lies outside the selection at an edge: extend
        // that edge to the document boundary, so a whole-document copy
        // also carries what renders nothing, such as link reference
        // definitions at the end.
        if (startWhole && coversBlockEdge(range, article, 'start')) first = { start: 1, end: first.end };
        if (endWhole && coversBlockEdge(range, article, 'end')) last = { start: last.start, end: lines.length };
        if (startBlock === endBlock || startBlock.contains(endBlock) || endBlock.contains(startBlock)) {
            if (!startWhole || !endWhole) return null;
            return slice(Math.min(first.start, last.start), Math.max(first.end, last.end));
        }
        if (last.start <= first.end) return null;
        const parts = [];
        parts.push(startWhole ? slice(first.start, first.end) : selectedTextWithin(range, startBlock));
        if (last.start > first.end + 1) parts.push(slice(first.end + 1, last.start - 1));
        parts.push(endWhole ? slice(last.start, last.end) : selectedTextWithin(range, endBlock));
        return parts.join('\n');
    }
window.MdpRenderers = {
    highlightAll: highlightAll,
    renderMathElement: renderMathElement,
    markdownForSelection: markdownForSelection,
};
})();
