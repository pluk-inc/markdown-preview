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
    // Wraps each table of the document in .md-table-wrap: not one in the
    // frontmatter, inside another table, or already wrapped. Returns the
    // new wraps, for the app to add its Expand button to.
    function wrapTables(root, tableParentSelector) {
        const wraps = [];
        root.querySelectorAll('table').forEach(table => {
            if (table.closest('.md-frontmatter') || table.parentElement.closest('table')
                || table.parentElement.matches(tableParentSelector)) return;
            const wrap = document.createElement('div');
            wrap.className = 'md-table-wrap';
            table.before(wrap);
            wrap.append(table);
            wraps.push(wrap);
        });
        return wraps;
    }

    // Drag the edge between two header cells to resize a column, in the
    // document and in the table window; double-click an edge to fit that
    // column to its header text. The first drag fixes each column at its
    // current width, so the others keep theirs. Widths are not saved: a
    // new render, export, or print uses the natural widths.
    function enableTableColumnResize(tableParentSelector) {
        const edgeSlop = 5;
        const minimumWidth = 40;
        let drag = null;
        let activeCell = null;

        function headerCells(table) {
            const row = table.tHead?.rows[0] ?? table.rows[0];
            return row ? Array.from(row.cells) : [];
        }

        // A cell's start edge is the previous column's end edge, so the
        // pointer can grab an edge from either side of it.
        function edgeAt(event) {
            const cell = event.target.closest?.('th');
            if (!cell) return null;
            // Runs on every pointer move over a header: bail out before
            // the table checks unless the pointer is near a cell side.
            const rect = cell.getBoundingClientRect();
            if (Math.abs(event.clientX - rect.left) > edgeSlop
                && Math.abs(event.clientX - rect.right) > edgeSlop) return null;
            const table = cell.closest('table');
            if (!table?.parentElement.matches(tableParentSelector)) return null;
            const cells = headerCells(table);
            const index = cells.indexOf(cell);
            if (index < 0 || cells.some(c => c.colSpan > 1)
                || table.querySelector(':scope > colgroup:not([data-mdp-resize])')) return null;
            const rtl = getComputedStyle(table).direction === 'rtl';
            const end = rtl ? rect.left : rect.right;
            const start = rtl ? rect.right : rect.left;
            if (Math.abs(event.clientX - end) <= edgeSlop) return { table, cells, index, rtl };
            if (index > 0 && Math.abs(event.clientX - start) <= edgeSlop)
                return { table, cells, index: index - 1, rtl };
            return null;
        }

        function fixColumns(table, cells) {
            const existing = table.querySelector(':scope > colgroup[data-mdp-resize]');
            if (existing) return Array.from(existing.children);
            const widths = cells.map(cell => cell.getBoundingClientRect().width);
            const group = document.createElement('colgroup');
            group.dataset.mdpResize = '';
            const cols = widths.map(width => {
                const col = document.createElement('col');
                col.style.width = `${width}px`;
                return group.appendChild(col);
            });
            table.prepend(group);
            // Fixed widths need a real table box, which cannot scroll, so
            // an inner box scrolls it. The wrapper stays put, and with it
            // the Expand button.
            // Keep the reader's place: before this, the table itself
            // scrolled horizontally.
            const scrollLeft = table.scrollLeft;
            const scroller = document.createElement('div');
            scroller.className = 'md-table-scroll';
            table.before(scroller);
            scroller.append(table);
            table.classList.add('mdp-columns-resized');
            table.style.width = `${widths.reduce((sum, width) => sum + width, 0)}px`;
            // Only after the width is set: until then the table fits the box.
            scroller.scrollLeft = scrollLeft;
            return cols;
        }

        // Measures the header text on one line, so the column is just
        // wide enough for its name. Body cells keep wrapping in it.
        function fitColumn(table, cells, index) {
            const col = fixColumns(table, cells)[index];
            const cell = cells[index];
            const range = document.createRange();
            range.selectNodeContents(cell);
            cell.style.whiteSpace = 'nowrap';
            const textWidth = range.getBoundingClientRect().width;
            cell.style.removeProperty('white-space');
            const style = getComputedStyle(cell);
            const padding = parseFloat(style.paddingLeft) + parseFloat(style.paddingRight);
            const width = Math.max(minimumWidth, Math.ceil(textWidth + padding) + 1);
            const tableWidth = parseFloat(table.style.width) - parseFloat(col.style.width) + width;
            col.style.width = `${width}px`;
            table.style.width = `${tableWidth}px`;
        }

        function showEdge(cell) {
            if (cell === activeCell) return;
            activeCell?.classList.remove('mdp-column-edge-active');
            activeCell = cell;
            cell?.classList.add('mdp-column-edge-active');
        }

        function endDrag() {
            drag = null;
            showEdge(null);
            document.documentElement.classList.remove('mdp-column-resizing');
        }

        document.addEventListener('pointermove', event => {
            // The release can go to a context menu instead of the page.
            if (drag && !(event.buttons & 1)) endDrag();
            if (!drag) {
                const edge = edgeAt(event);
                showEdge(edge ? edge.cells[edge.index] : null);
                return;
            }
            const delta = (event.clientX - drag.x) * (drag.rtl ? -1 : 1);
            const width = Math.max(minimumWidth, drag.width + delta);
            drag.col.style.width = `${width}px`;
            drag.table.style.width = `${drag.tableWidth - drag.width + width}px`;
        });
        document.addEventListener('pointerdown', event => {
            // Control-click opens the context menu on macOS. A finger
            // can't aim at a 5 px edge, and the browser takes its drag
            // to scroll the table, so touch only scrolls.
            if (event.button !== 0 || event.ctrlKey || event.pointerType === 'touch') return;
            const edge = edgeAt(event);
            if (!edge) return;
            // Without this the drag selects the header text.
            event.preventDefault();
            const col = fixColumns(edge.table, edge.cells)[edge.index];
            drag = {
                table: edge.table, col, rtl: edge.rtl, x: event.clientX,
                width: parseFloat(col.style.width),
                tableWidth: parseFloat(edge.table.style.width),
            };
            document.documentElement.classList.add('mdp-column-resizing');
            event.target.setPointerCapture?.(event.pointerId);
        });
        // A double-click starts its word selection on mousedown, which
        // the pointerdown handler alone does not stop.
        document.addEventListener('mousedown', event => {
            if (edgeAt(event)) event.preventDefault();
        });
        document.addEventListener('pointerup', endDrag);
        document.addEventListener('pointercancel', endDrag);
        document.addEventListener('dblclick', event => {
            const edge = edgeAt(event);
            if (!edge) return;
            event.preventDefault();
            fitColumn(edge.table, edge.cells, edge.index);
        });
    }
    function enableCodeBlocks(labels, copyText) {
        const codeIconShapes = { check: "<path d=\"m5 12 4 4L19 6\"\/>", copy: "<rect x=\"4\" y=\"8\" width=\"12\" height=\"13\" rx=\"3\"\/><path d=\"M8 8V6a3 3 0 0 1 3-3h6a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3h-1\"\/>", unwrap: "<path d=\"M4 6h16M4 12h16m-4-4 4 4-4 4M4 18h7\"\/>", wrap: "<path d=\"M4 6h16M4 11h12a4 4 0 0 1 0 8h-5m3-3-3 3 3 3M4 16h3\"\/>" };
        const codeIcon = (kind) => "<svg xmlns=\"http:\/\/www.w3.org\/2000\/svg\" viewBox=\"0 0 24 24\" width=\"16\" height=\"16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">" + codeIconShapes[kind] + '</svg>';

        function makeNativeHUDReporter(kind, describe) {
    if (!document.documentElement.hasAttribute('data-mdp-native-hud')) return null;
    let target = null;
    // The host's clicks act on the last block reported: the page may see
    // the pointer leave it for the glass drawn over it.
    let last = null;
    let frame = 0;
    const ids = new WeakMap();
    let nextID = 0;
    function post(el = target) {
        const extras = el?.isConnected ? describe(el) : null;
        const message = { kind, visible: !!extras };
        if (extras) {
            if (!ids.has(el)) ids.set(el, nextID++);
            const r = el.getBoundingClientRect();
            Object.assign(message, { id: ids.get(el), x: r.left, y: r.top, width: r.width, height: r.height }, extras);
        }
        try { window.webkit?.messageHandlers?.mdPreviewHost?.postMessage(message); } catch (_) {}
    }
    window.addEventListener('scroll', () => {
        if (!target || frame) return;
        frame = requestAnimationFrame(() => { frame = 0; post(); });
    }, { passive: true });
    window.addEventListener('resize', () => { if (target) post(); });
    const reporter = {
        get target() { return target?.isConnected ? target : last?.isConnected ? last : null; },
        set(el) {
            if (el === target) return;
            target = el;
            if (el) last = el;
            post();
        },
        // The block the host's controls act on, so an action's new state
        // (a zoom level, Wrap) reaches the glass the pointer is on.
        refresh() {
            const el = reporter.target;
            if (el) post(el);
        },
    };
    const refreshAll = window.mdpRefreshNativeHUD;
    window.mdpRefreshNativeHUD = () => { refreshAll?.(); reporter.refresh(); };
    return reporter;
}
        // The host's clicks run the hidden HTML buttons.
        const codeHUD = makeNativeHUDReporter('codeHUD', (wrap) => ({
            wrapped: wrap.classList.contains('is-wrapped')
        }));
        if (codeHUD) {
            document.addEventListener('pointerover', (event) => {
                codeHUD.set(event.target.closest?.('.md-code-wrap') || null);
            });
            document.addEventListener('pointerout', (event) => {
                if (!event.relatedTarget) codeHUD.set(null);
            });
            window.mdpCodeHUDAction = (act) => {
                const selector = act === 'wrap' ? '.md-code-toggle-wrap' : act === 'copy' ? '.md-code-copy' : null;
                if (selector && codeHUD.target?.isConnected) codeHUD.target.querySelector(selector)?.click();
            };
        }

        function decorateCodeBlocks(root = document) {
            root.querySelectorAll('pre > code').forEach((code) => {
                const pre = code.parentElement;
                if (!pre || pre.dataset.copyButtonReady === '1') return;
                pre.dataset.copyButtonReady = '1';

                // Wrap pre in a positioned container so the copy button
                // stays pinned regardless of horizontal scroll inside pre.
                const wrap = document.createElement('div');
                wrap.className = 'md-code-wrap';
                pre.parentNode.insertBefore(wrap, pre);
                wrap.appendChild(pre);

                const header = document.createElement('div');
                header.className = 'md-code-header';
                const language = document.createElement('span');
                language.className = 'md-code-language';
                language.textContent = pre.dataset.codeLanguage || 'text';
                header.appendChild(language);
                const actions = document.createElement('span');
                actions.className = 'md-code-actions';
                header.appendChild(actions);
                const toggle = document.createElement('button');
                toggle.type = 'button';
                toggle.className = 'md-code-action md-code-toggle-wrap';
                toggle.innerHTML = codeIcon('wrap');
                toggle.title = labels.wrapCode;
                toggle.setAttribute('aria-label', toggle.title);
                toggle.setAttribute('aria-pressed', 'false');
                actions.appendChild(toggle);
                const button = document.createElement('button');
                button.type = 'button';
                button.className = 'md-code-action md-code-copy';
                button.innerHTML = codeIcon('copy');
                button.title = labels.copyCode;
                button.setAttribute('aria-label', labels.copyCode);
                actions.appendChild(button);
                wrap.insertBefore(header, pre);
            });
        }

        async function copyCodeBlock(button) {
            const code = button.closest('.md-code-wrap')?.querySelector('pre > code');
            if (!code || !(await copyText(code.textContent || '', code))) return;
            button.innerHTML = codeIcon('check');
            button.title = labels.codeCopied;
            button.setAttribute('aria-label', labels.codeCopied);
            button.classList.add('is-copied');
            clearTimeout(button.__mdCopyTimer);
            button.__mdCopyTimer = setTimeout(() => {
                button.innerHTML = codeIcon('copy');
                button.title = labels.copyCode;
                button.setAttribute('aria-label', labels.copyCode);
                button.classList.remove('is-copied');
            }, 1100);
        }

        document.addEventListener('click', (event) => {
            const toggle = event.target.closest('.md-code-toggle-wrap');
            if (toggle) {
                event.preventDefault();
                event.stopPropagation();
                // A toggle keeps one name ("Wrap code") and reports its
                // state with aria-pressed; the tooltip names the next action.
                const wrapped = toggle.closest('.md-code-wrap').classList.toggle('is-wrapped');
                toggle.setAttribute('aria-pressed', String(wrapped));
                toggle.title = wrapped ? labels.unwrapCode : labels.wrapCode;
                toggle.innerHTML = codeIcon(wrapped ? 'unwrap' : 'wrap');
                if (codeHUD && toggle.closest('.md-code-wrap') === codeHUD.target) codeHUD.refresh();
                return;
            }
            const button = event.target.closest('.md-code-copy');
            if (!button) return;
            event.preventDefault();
            event.stopPropagation();
            copyCodeBlock(button);
        });

        return decorateCodeBlocks;
    }
window.MdpRenderers = {
    highlightAll: highlightAll,
    renderMathElement: renderMathElement,
    markdownForSelection: markdownForSelection,
    wrapTables: wrapTables,
    enableTableColumnResize: enableTableColumnResize,
    enableCodeBlocks: enableCodeBlocks,
    // The app's codeBlockMessagesJS in each of its languages.
    codeBlockMessages: {
        en: {
    wrapCode: "Wrap code",
    unwrapCode: "Unwrap code",
    copyCode: "Copy code",
    codeCopied: "Code copied"
},
        ja: {
    wrapCode: "コードを折り返す",
    unwrapCode: "コードの折り返しを解除",
    copyCode: "コードをコピー",
    codeCopied: "コードをコピーしました"
},
        "zh-Hans": {
    wrapCode: "代码换行",
    unwrapCode: "取消代码换行",
    copyCode: "拷贝代码",
    codeCopied: "代码已拷贝"
},
        pl: {
    wrapCode: "Zawijaj wiersze kodu",
    unwrapCode: "Nie zawijaj wierszy kodu",
    copyCode: "Kopiuj kod",
    codeCopied: "Kod skopiowany"
},
        fa: {
    wrapCode: "شکستن خطوط کد",
    unwrapCode: "لغو شکستن خطوط کد",
    copyCode: "کپی کد",
    codeCopied: "کد کپی شد"
},
    },
};
})();
