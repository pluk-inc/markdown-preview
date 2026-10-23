/* Generated from the app's MarkdownHTML by ShareViewerKitTests.
   Do not edit; run MDP_WRITE_VIEWER_KIT=1 swift test --filter ShareViewerKitTests. */
(function () {
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
window.MdpRenderers = { highlightAll: highlightAll, renderMathElement: renderMathElement };
})();
