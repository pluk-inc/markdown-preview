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
// The app's diagram wiring (drawing, zoom, the HUD), started once
// pele.global.js has loaded with the reader's language's texts
// (diagramStrings); it returns { bootstrap, renderAll }.
const mermaidWiring = (t) => (() => {
        const fillWidthLabel = t.fillWidth;
        const fitDiagramLabel = t.fitDiagram;
        const states = new WeakMap();
        const renderOptions = { autoDirection: false,
  get fontFamily() { return getComputedStyle(document.body).fontFamily; },
  get fontSize() { return parseFloat(getComputedStyle(document.body).fontSize); } };
        const messages = {
    errors: { 'unsupported-diagram': t.unsupported, syntax: t.syntax, semantic: t.semantic, limit: t.limit },
    generic: t.generic, position: t.position, empty: t.empty, emptyHint: '', unavailable: ''
};
        const errorMessage = (err) => {
    const summary = (err && messages.errors[err.code]) || messages.generic;
    if (!(err && err.line > 0)) return summary;
    return summary + ' ' + messages.position
        .replace(/%(1\$)?d/, String(err.line))
        .replace(/%(2\$)?d/, String(err.column));
};
        const genericError = messages.generic;
        const emptyDiagram = messages.empty;
        let renderCount = 0;
        const peleColorVariables = ["--pele-bg", "--pele-fg", "--pele-muted", "--pele-line", "--pele-surface", "--pele-surface-alt", "--pele-border", "--pele-accent", "--pele-critical", "--pele-series-1", "--pele-series-2", "--pele-series-3", "--pele-series-4", "--pele-series-5", "--pele-series-6", "--pele-series-7", "--pele-series-8"];
        const peleStyleVariables = {"--pele-radius": "6px", "--pele-title-weight": "600", "--pele-heading-weight": "600", "--pele-font-mono": "ui-monospace, \"SF Mono\", Menlo, monospace"};

        // pele.render is synchronous, so a batch draws in one pass and
        // announces itself once for the host's height and scroll sync.
        // The options are copied once per batch: copying reads the body's
        // style, which would otherwise flush per figure after each insert.
        function renderFigures(figures) {
            const options = Object.assign({}, renderOptions);
            for (const figure of figures) renderOne(figure, options);
            window.dispatchEvent(new Event('md-preview-mermaid-rendered'));
        }

        // Rendering is viewport-driven, so pagination (print/export) must
        // draw every remaining figure before the page is captured.
        async function renderAll() {
            renderFigures(document.querySelectorAll('.mermaid-figure'));
        }

        // A failed figure counts as done, so MdPreview.update keeps it
        // while its source is unchanged and the message is never parsed
        // as a diagram. The message goes above the source as text; the
        // figure keeps line breaks, so a trailing one would show as a
        // blank line, and an empty block shows the message alone.
        function showError(figure, node, message) {
            const source = node.__mdSrc.replace(/\s+$/, '');
            node.textContent = source ? message + '\n\n' + source : message;
            node.dataset.mmDone = '1';
            figure.classList.add('mermaid-error');
        }

        function renderOne(figure, batchOptions) {
            const node = figure.querySelector('.mermaid');
            if (!node || node.dataset.mmDone === '1') return;
            if (node.dataset.mmUnavailable === '1') {
                // The bundle arrived after an export gave up on it: put
                // the source back before drawing it.
                delete node.dataset.mmUnavailable;
                node.textContent = node.__mdSrc;
                figure.classList.remove('mermaid-error');
            }
            // Pre-render source, stashed so MdPreview.update can pair
            // unchanged diagrams with their SVGs during DOM diffs. A
            // morph with new source clears the done flag and lands here.
            node.__mdSrc = node.textContent;
            if (!node.__mdSrc.trim()) {
                showError(figure, node, emptyDiagram);
                figure.classList.add('mermaid-empty');
                return;
            }
            let svg;
            try {
                // A unique prefix keeps each diagram's accessible title and
                // description IDs apart.
                const options = Object.assign({ idPrefix: 'mdp-diagram-' + (++renderCount) + '-' }, batchOptions);
                node.innerHTML = pele.render(node.__mdSrc, options).svg;
                svg = node.querySelector('svg');
            } catch (err) {
                showError(figure, node, errorMessage(err));
                return;
            }
            if (!svg) {
                showError(figure, node, genericError);
                return;
            }
            node.dataset.mmDone = '1';
            attachZoom(figure, svg);
        }

        function attachZoom(figure, svg) {
            // Normalize sizing: prefer viewBox, drop intrinsic width/height.
            let vbW, vbH;
            const vb = svg.viewBox && svg.viewBox.baseVal;
            if (vb && vb.width && vb.height) {
                vbW = vb.width; vbH = vb.height;
            } else {
                vbW = parseFloat(svg.getAttribute('width')) || svg.getBBox().width || 1;
                vbH = parseFloat(svg.getAttribute('height')) || svg.getBBox().height || 1;
                svg.setAttribute('viewBox', '0 0 ' + vbW + ' ' + vbH);
            }
            svg.removeAttribute('width');
            svg.removeAttribute('height');
            svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
            svg.style.width = '100%';
            svg.style.height = '100%';
            const surface = svg.parentElement || svg;
            surface.style.transformOrigin = '0 0';

            // Stable layout: figure claims height from the diagram's aspect ratio,
            // capped by max-height so massive diagrams don't push the page.
            if (vbW > 0 && vbH > 0) {
                figure.style.setProperty('--mm-aspect', vbW + ' / ' + vbH);
                figure.style.setProperty('--mm-height', vbH + 'px');
            }

            const alreadyWired = states.has(figure);
            const state = {
                tx: 0, ty: 0, scale: 1, min: 0.25, max: 8,
                rect: null, raf: 0, dragging: false,
                lastX: 0, lastY: 0, surface,
                vbW, vbH, svg
            };
            states.set(figure, state);

            // A figure redrawn after MdPreview.update morphed in new
            // source keeps its listeners; only the state and HUD need
            // resetting for the fresh SVG. Its rect is measured on first
            // use (or by the ResizeObserver), not here, so a batch of
            // figures does not force a layout per diagram.
            if (alreadyWired) {
                apply(figure, state);
                return;
            }

            figure.addEventListener('pointerenter', () => postMermaidHover(true));
            figure.addEventListener('pointerleave', () => postMermaidHover(false));
            figure.addEventListener('wheel', onWheel, { passive: false });
            figure.addEventListener('pointerdown', onPointerDown);
            figure.addEventListener('dblclick', onDoubleClick);
            const hud = figure.querySelector('.mermaid-hud');
            if (hud) hud.addEventListener('click', onHudClick);
        }

        function cacheRect(figure) {
            const s = states.get(figure);
            if (!s) return;
            const previous = s.rect;
            s.rect = figure.getBoundingClientRect();
            // Zoomed out, the offsets hold the centring for the old box
            // size: move them by the change of that centre, so a centred
            // drawing stays centred and a deliberate pan is kept.
            if (previous && s.scale < 1) {
                const dx = (s.rect.width - previous.width) * (1 - s.scale) / 2;
                const dy = (s.rect.height - previous.height) * (1 - s.scale) / 2;
                if (dx || dy) {
                    s.tx += dx;
                    s.ty += dy;
                    apply(figure, s);
                }
            }
        }

        function postMermaidHover(value) {
            try {
                window.webkit?.messageHandlers?.mdPreviewHost?.postMessage({
                    kind: 'mermaidHover',
                    value
                });
            } catch (_) {}
        }

        // Text of the closest heading before the figure in document
        // order, so the popup window can carry some context instead of
        // a title that's identical for every diagram in the document.
        function nearestHeadingText(figure) {
            const headings = document.querySelectorAll('h1, h2, h3, h4, h5, h6');
            let text = '';
            for (const h of headings) {
                if (h.compareDocumentPosition(figure) & Node.DOCUMENT_POSITION_FOLLOWING) {
                    text = (h.textContent || '').trim();
                } else {
                    break;
                }
            }
            return text;
        }

        // Clone without the pan/zoom transform so the popup starts with
        // the pristine rendered diagram.
        function openPopup(figure) {
            const s = states.get(figure);
            if (!s || !s.svg) return;
            const svg = s.svg;
            const clone = svg.cloneNode(true);
            // Keep the style attribute: it wires Pele's --pele-* inputs
            // into the drawing. The popup has none of this page's CSS,
            // so carry the theme colours along, resolved to plain values
            // (the tokens are system colours and color-mix() here).
            const probe = document.createElement('span');
            figure.appendChild(probe);
            for (const name of peleColorVariables) {
                probe.style.color = 'var(' + name + ')';
                clone.style.setProperty(name, getComputedStyle(probe).color);
            }
            probe.remove();
            for (const [name, value] of Object.entries(peleStyleVariables)) {
                clone.style.setProperty(name, value);
            }
            clone.style.setProperty('--pele-font',
                getComputedStyle(figure).getPropertyValue('--pele-font').trim());
            clone.setAttribute('preserveAspectRatio', 'xMidYMid meet');
            clone.removeAttribute('width');
            clone.removeAttribute('height');
            clone.style.width = '100%';
            clone.style.height = '100%';
            try {
                window.webkit?.messageHandlers?.mdPreviewHost?.postMessage({
                    kind: 'mermaidPopup',
                    svg: clone.outerHTML,
                    sectionTitle: nearestHeadingText(figure)
                });
            } catch (_) {}
        }

        function apply(figure, s) {
            if (s.raf) return;
            s.raf = requestAnimationFrame(() => {
                s.raf = 0;
                s.surface.style.transform = 'translate(' + s.tx + 'px,' + s.ty + 'px) scale(' + s.scale + ')';
                const lvl = figure.querySelector('.mermaid-hud-level');
                if (lvl) lvl.textContent = Math.round(s.scale * 100) + '%';
            });
        }

        function zoomAt(figure, x, y, k) {
            const s = states.get(figure);
            if (!s) return;
            const next = Math.max(s.min, Math.min(s.max, s.scale * k));
            if (next === s.scale) return;
            const ratio = next / s.scale;
            s.tx = x - (x - s.tx) * ratio;
            s.ty = y - (y - s.ty) * ratio;
            s.scale = next;
            if (s.scale <= 1.001) {
                // At or below 100% the whole drawing fits: keep it centred
                // in its box (the transform origin is the top-left corner).
                if (!s.rect) cacheRect(figure);
                s.tx = s.rect.width * (1 - s.scale) / 2;
                s.ty = s.rect.height * (1 - s.scale) / 2;
            }
            apply(figure, s);
        }

        function reset(figure) {
            const s = states.get(figure);
            if (!s) return;
            s.tx = 0; s.ty = 0; s.scale = 1;
            apply(figure, s);
        }

        function toggleWidth(figure) {
            const expanded = figure.classList.toggle('mermaid-width-expanded');
            const btn = figure.querySelector('[data-mm-act="width"]');
            if (btn) {
                const label = expanded ? fitDiagramLabel : fillWidthLabel;
                btn.textContent = expanded ? '⤡' : '⤢';
                btn.setAttribute('aria-label', label);
                btn.setAttribute('aria-pressed', String(expanded));
                btn.setAttribute('title', label);
            }
            reset(figure);
            requestAnimationFrame(() => {
                cacheRect(figure);
                window.dispatchEvent(new Event('md-preview-mermaid-rendered'));
            });
        }

        function step(figure, factor) {
            const s = states.get(figure);
            if (!s) return;
            if (!s.rect) cacheRect(figure);
            const r = s.rect;
            zoomAt(figure, r.width / 2, r.height / 2, factor);
        }

        function onWheel(e) {
            // ⌘/Ctrl + wheel zooms; macOS pinch synthesizes wheel + ctrlKey.
            // Plain wheel falls through to the page scroll (don't preventDefault).
            if (!(e.ctrlKey || e.metaKey)) return;
            const figure = e.currentTarget;
            const s = states.get(figure);
            if (!s) return;
            e.preventDefault();
            if (!s.rect) cacheRect(figure);
            const r = s.rect;
            const k = Math.exp(-e.deltaY * 0.01);
            zoomAt(figure, e.clientX - r.left, e.clientY - r.top, k);
        }

        function onPointerDown(e) {
            if (e.button !== 0) return;
            const figure = e.currentTarget;
            const s = states.get(figure);
            if (!s) return;
            if (e.target.closest('.mermaid-hud')) return;
            figure.setPointerCapture(e.pointerId);
            s.dragging = true;
            s.lastX = e.clientX;
            s.lastY = e.clientY;
            figure.addEventListener('pointermove', onPointerMove);
            figure.addEventListener('pointerup', onPointerUp);
            figure.addEventListener('pointercancel', onPointerUp);
        }

        function onPointerMove(e) {
            const figure = e.currentTarget;
            const s = states.get(figure);
            if (!s || !s.dragging) return;
            s.tx += e.clientX - s.lastX;
            s.ty += e.clientY - s.lastY;
            s.lastX = e.clientX;
            s.lastY = e.clientY;
            apply(figure, s);
        }

        function onPointerUp(e) {
            const figure = e.currentTarget;
            const s = states.get(figure);
            if (!s) return;
            s.dragging = false;
            figure.removeEventListener('pointermove', onPointerMove);
            figure.removeEventListener('pointerup', onPointerUp);
            figure.removeEventListener('pointercancel', onPointerUp);
        }

        function onDoubleClick(e) {
            const figure = e.currentTarget;
            if (e.target.closest('.mermaid-hud')) return;
            const s = states.get(figure);
            if (!s) return;
            if (Math.abs(s.scale - 1) > 0.001) {
                reset(figure);
            } else {
                if (!s.rect) cacheRect(figure);
                const r = s.rect;
                zoomAt(figure, e.clientX - r.left, e.clientY - r.top, 2);
            }
        }

        function onHudClick(e) {
            const btn = e.target.closest('[data-mm-act]');
            if (!btn) return;
            e.stopPropagation();
            const figure = btn.closest('.mermaid-figure');
            if (!figure) return;
            figure.focus();
            switch (btn.dataset.mmAct) {
                case 'in':    step(figure, 1.25); break;
                case 'out':   step(figure, 0.8);  break;
                case 'reset': reset(figure);      break;
                case 'width': toggleWidth(figure); break;
                case 'popup': openPopup(figure);  break;
            }
        }

        const ro = new ResizeObserver((entries) => {
            for (const entry of entries) cacheRect(entry.target);
        });

        function bootstrap() {
            const figures = document.querySelectorAll('.mermaid-figure');
            if (!figures.length) return;
            const io = new IntersectionObserver((entries) => {
                const visible = entries.filter((entry) => entry.isIntersecting).map((entry) => entry.target);
                if (!visible.length) return;
                for (const figure of visible) {
                    io.unobserve(figure);
                    ro.observe(figure);
                }
                renderFigures(visible);
            }, { rootMargin: '300px 0px' });
            figures.forEach((f) => io.observe(f));
        }

        window.MdPreview = window.MdPreview || {};
        window.MdPreview.mermaidRenderAll = renderAll;

        return { bootstrap, renderAll };
    })();
// The app's translations of the diagram texts, by language.
const diagramStrings = {
  "en" : {
    "empty" : "This diagram is empty.",
    "fillWidth" : "Fill width",
    "fitDiagram" : "Fit diagram",
    "generic" : "The diagram could not be drawn.",
    "limit" : "The diagram is too large to draw.",
    "position" : "Line %d, column %d",
    "resetZoom" : "Reset zoom",
    "semantic" : "The diagram is not valid.",
    "syntax" : "The diagram has a syntax error.",
    "unsupported" : "This diagram type is not supported.",
    "zoomIn" : "Zoom In",
    "zoomOut" : "Zoom Out"
  },
  "fa" : {
    "empty" : "این نمودار خالی است.",
    "fillWidth" : "پر کردن عرض",
    "fitDiagram" : "برازش نمودار",
    "generic" : "رسم نمودار ممکن نشد.",
    "limit" : "نمودار برای رسم بیش از حد بزرگ است.",
    "position" : "خط %1$d، ستون %2$d",
    "resetZoom" : "بازنشانی بزرگ‌نمایی",
    "semantic" : "نمودار معتبر نیست.",
    "syntax" : "نمودار خطای نحوی دارد.",
    "unsupported" : "این نوع نمودار پشتیبانی نمی‌شود.",
    "zoomIn" : "بزرگ‌نمایی",
    "zoomOut" : "کوچک‌نمایی"
  },
  "ja" : {
    "empty" : "このダイアグラムは空です。",
    "fillWidth" : "幅に合わせる",
    "fitDiagram" : "ダイアグラム全体を表示",
    "generic" : "ダイアグラムを描画できませんでした。",
    "limit" : "ダイアグラムが大きすぎるため描画できません。",
    "position" : "%1$d 行目、%2$d 列目",
    "resetZoom" : "拡大/縮小をリセット",
    "semantic" : "ダイアグラムが正しくありません。",
    "syntax" : "ダイアグラムに構文エラーがあります。",
    "unsupported" : "この種類のダイアグラムには対応していません。",
    "zoomIn" : "拡大",
    "zoomOut" : "縮小"
  },
  "pl" : {
    "empty" : "Ten diagram jest pusty.",
    "fillWidth" : "Wypełnij szerokość",
    "fitDiagram" : "Dopasuj diagram",
    "generic" : "Nie można narysować diagramu.",
    "limit" : "Diagram jest zbyt duży, aby go narysować.",
    "position" : "Wiersz %d, kolumna %d",
    "resetZoom" : "Wyzeruj powiększenie",
    "semantic" : "Diagram jest nieprawidłowy.",
    "syntax" : "Diagram zawiera błąd składni.",
    "unsupported" : "Ten rodzaj diagramu nie jest obsługiwany.",
    "zoomIn" : "Przybliż",
    "zoomOut" : "Oddal"
  },
  "zh-Hans" : {
    "empty" : "此图表为空。",
    "fillWidth" : "填满宽度",
    "fitDiagram" : "适应图表",
    "generic" : "无法绘制图表。",
    "limit" : "图表过大，无法绘制。",
    "position" : "第 %1$d 行，第 %2$d 列",
    "resetZoom" : "重置缩放",
    "semantic" : "图表无效。",
    "syntax" : "图表存在语法错误。",
    "unsupported" : "不支持此图表类型。",
    "zoomIn" : "放大",
    "zoomOut" : "缩小"
  }
};
window.MdpRenderers = {
    highlightAll: highlightAll,
    renderMathElement: renderMathElement,
    markdownForSelection: markdownForSelection,
    mermaidWiring: mermaidWiring,
    diagramStrings: diagramStrings,
};
})();
