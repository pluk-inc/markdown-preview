//
//  MarkdownHTML+Mermaid.swift
//  md-preview
//
//  Mermaid diagram rendering and vendor emission.
//

import Foundation

// `nonisolated` matters: the targets default to MainActor isolation, and
// rendering runs off the main actor.
nonisolated extension MarkdownHTML {
    // MARK: - Mermaid

    struct MermaidRenderResult {
        let html: String
        let containsMermaid: Bool
    }

    private static let mermaidRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"<pre\b([^>]*)>\s*<code\b[^>]*class="[^"]*\blanguage-mermaid\b[^"]*"[^>]*>([\s\S]*?)</code>\s*</pre>"#
        )
    }()

    static func renderMermaidBlocks(in html: String) -> MermaidRenderResult {
        guard html.contains("language-mermaid") else {
            return MermaidRenderResult(html: html, containsMermaid: false)
        }
        let nsHTML = html as NSString
        let matches = mermaidRegex.matches(
            in: html,
            range: NSRange(location: 0, length: nsHTML.length)
        )
        guard !matches.isEmpty else {
            return MermaidRenderResult(html: html, containsMermaid: false)
        }

        var rendered = ""
        rendered.reserveCapacity(html.count)
        var cursor = 0
        let diagramLabel = htmlEscape(NSLocalizedString("Mermaid diagram", comment: "Mermaid diagram accessibility label"))
        let zoomOut = htmlEscape(NSLocalizedString("Zoom Out", comment: "Mermaid diagram control"))
        let resetZoom = htmlEscape(NSLocalizedString("Reset zoom", comment: "Mermaid diagram control"))
        let zoomIn = htmlEscape(NSLocalizedString("Zoom In", comment: "Mermaid diagram control"))
        let fillWidth = htmlEscape(NSLocalizedString("Fill width", comment: "Mermaid diagram control"))
        // The popup is app-only — `MarkdownWebView` compiles its `mermaidPopup`
        // handler out of the Quick Look extension, so emitting the button there
        // would leave a control that does nothing when clicked.
        #if QUICK_LOOK_EXTENSION
        let popupButton = ""
        #else
        let openWindow = htmlEscape(NSLocalizedString("Open in Window", comment: "Mermaid diagram control"))
        let popupButton = """
        <button type="button" class="mermaid-hud-btn mermaid-hud-popup" data-mm-act="popup" tabindex="-1" aria-label="\(openWindow)" title="\(openWindow)">⛶</button>
        """
        #endif
        for match in matches {
            rendered += nsHTML.substring(with: NSRange(
                location: cursor,
                length: match.range.location - cursor
            ))
            let sourceAttributes = nsHTML.substring(with: match.range(at: 1))
            let diagram = nsHTML.substring(with: match.range(at: 2))
            rendered += """
            <figure\(sourceAttributes) class="mermaid-figure" tabindex="0" role="img" aria-label="\(diagramLabel)">
            <div class="mermaid-stage"><div class="mermaid">\(diagram)</div></div>
            <div class="mermaid-hud" aria-hidden="true">
            <div class="mermaid-hud-group mermaid-hud-zoom">
            <button type="button" class="mermaid-hud-btn" data-mm-act="out" tabindex="-1" aria-label="\(zoomOut)">−</button>
            <button type="button" class="mermaid-hud-btn mermaid-hud-level" data-mm-act="reset" tabindex="-1" aria-label="\(resetZoom)">100%</button>
            <button type="button" class="mermaid-hud-btn" data-mm-act="in" tabindex="-1" aria-label="\(zoomIn)">+</button>
            </div>
            <div class="mermaid-hud-group mermaid-hud-actions">
            <button type="button" class="mermaid-hud-btn mermaid-hud-width" data-mm-act="width" tabindex="-1" aria-label="\(fillWidth)" aria-pressed="false" title="\(fillWidth)"><span class="mermaid-hud-width-symbol" aria-hidden="true">⤢</span></button>
            \(popupButton)
            </div>
            </div>
            </figure>
            """
            cursor = match.range.location + match.range.length
        }
        rendered += nsHTML.substring(from: cursor)
        return MermaidRenderResult(html: rendered, containsMermaid: true)
    }

    /// Localized diagram messages, shared by the preview wiring and the editor
    /// widget so both modes say the same thing. Errors come from PeleError's
    /// code and position, since Pele's own message is English only.
    static let diagramMessagesJS = """
    {
        errors: {
            'unsupported-diagram': \(javaScriptStringLiteral(NSLocalizedString("This diagram type is not supported.", comment: "Mermaid diagram error"))),
            syntax: \(javaScriptStringLiteral(NSLocalizedString("The diagram has a syntax error.", comment: "Mermaid diagram error"))),
            semantic: \(javaScriptStringLiteral(NSLocalizedString("The diagram is not valid.", comment: "Mermaid diagram error"))),
            limit: \(javaScriptStringLiteral(NSLocalizedString("The diagram is too large to draw.", comment: "Mermaid diagram error")))
        },
        generic: \(javaScriptStringLiteral(NSLocalizedString("The diagram could not be drawn.", comment: "Mermaid diagram error"))),
        position: \(javaScriptStringLiteral(NSLocalizedString("Line %d, column %d", comment: "Position of a Mermaid diagram error: line, then column"))),
        empty: \(javaScriptStringLiteral(NSLocalizedString("This diagram is empty.", comment: "Shown for a Mermaid code block with no source"))),
        emptyHint: \(javaScriptStringLiteral(NSLocalizedString("Empty diagram. Click to add Mermaid source.", comment: "Edit-mode placeholder for a Mermaid code block with no source"))),
        unavailable: \(javaScriptStringLiteral(NSLocalizedString("Mermaid renderer is unavailable.\n\n", comment: "Mermaid rendering error"))).trim(),
        zoomOut: \(javaScriptStringLiteral(NSLocalizedString("Zoom Out", comment: "Mermaid diagram control"))),
        zoomIn: \(javaScriptStringLiteral(NSLocalizedString("Zoom In", comment: "Mermaid diagram control"))),
        resetZoom: \(javaScriptStringLiteral(NSLocalizedString("Reset zoom", comment: "Mermaid diagram control"))),
        fillWidth: \(javaScriptStringLiteral(NSLocalizedString("Fill width", comment: "Mermaid diagram control"))),
        fitDiagram: \(javaScriptStringLiteral(NSLocalizedString("Fit diagram", comment: "Mermaid diagram control")))
    }
    """

    /// `(err) => message` for a PeleError, reading `messages` (diagramMessagesJS)
    /// from the enclosing scope. Translations order the numbers positionally.
    static let diagramErrorMessageJS = """
    (err) => {
        const summary = (err && messages.errors[err.code]) || messages.generic;
        if (!(err && err.line > 0)) return summary;
        return summary + ' ' + messages.position
            .replace(/%(1\\$)?d/, String(err.line))
            .replace(/%(2\\$)?d/, String(err.column));
    }
    """

    /// Marks every figure that is not drawn yet with the localized
    /// "renderer unavailable" message above its source. Used when the bundle
    /// is missing, and when a lazy bundle never arrives before an export.
    /// The source is kept, so a bundle that arrives later still draws it.
    /// Internal so SPM helper tests can drive a late load.
    static let markUndrawnFiguresJS = """
    document.querySelectorAll('.mermaid-figure').forEach((figure) => {
        const node = figure.querySelector('.mermaid');
        if (!node || node.dataset.mmDone === '1' || figure.classList.contains('mermaid-error')) return;
        figure.classList.add('mermaid-error');
        node.__mdSrc = node.textContent;
        node.dataset.mmUnavailable = '1';
        // Same layout as showError: no trailing line break under the source.
        node.textContent = \(javaScriptStringLiteral(
            NSLocalizedString(
                "Mermaid renderer is unavailable.\n\n",
                comment: "Mermaid rendering error"
            )
        )) + node.__mdSrc.replace(/\\s+$/, '');
    });
    """

    private static let mermaidFallbackScript = """
    <script>
    window.addEventListener('load', () => {
        \(markUndrawnFiguresJS)
    });
    </script>
    """

    /// Mermaid render, pan/zoom, HUD and popup wiring, as the app runs it:
    /// `mermaidWiringFunction` with the app's own messages. Assumes the `pele`
    /// global has been (or will be) defined by the time DOMContentLoaded
    /// fires — true for both inline vendor `<script>` and `<script defer
    /// src=...>` delivery, since `defer` scripts run before DOMContentLoaded.
    /// Internal so SPM helper tests can drive the real bootstrap path (with a
    /// stub `pele` + message host).
    static let mermaidInitWiring = "(\(mermaidWiringFunction))(\(diagramMessagesJS))"

    /// `(messages) => { bootstrap, renderAll }`: the wiring, taking its words
    /// in the shape of `diagramMessagesJS`. The share viewer (exported by
    /// ShareViewerKitTests) passes the reader's language instead of the app's.
    static let mermaidWiringFunction = """
    (messages) => {
            const fillWidthLabel = messages.fillWidth;
            const fitDiagramLabel = messages.fitDiagram;
            const states = new WeakMap();
            const renderOptions = \(diagramRenderOptionsJS);
            const errorMessage = \(diagramErrorMessageJS);
            const genericError = messages.generic;
            const emptyDiagram = messages.empty;
            let renderCount = 0;
            const peleColorVariables = \(diagramColorVariableNamesJS);
            const peleStyleVariables = \(diagramStyleVariablesJS);

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
                const source = node.__mdSrc.replace(/\\s+$/, '');
                node.textContent = source ? message + '\\n\\n' + source : message;
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

            // The HUD in the HTML carries the words of whoever rendered it;
            // these are the reader's (the same in the app).
            const hudLabels = { out: messages.zoomOut, in: messages.zoomIn, reset: messages.resetZoom };
            function labelHud(figure) {
                figure.querySelectorAll('.mermaid-hud [data-mm-act]').forEach((button) => {
                    const pressed = button.getAttribute('aria-pressed') === 'true';
                    const label = button.dataset.mmAct === 'width'
                        ? (pressed ? fitDiagramLabel : fillWidthLabel)
                        : hudLabels[button.dataset.mmAct];
                    if (!label) return;
                    button.setAttribute('aria-label', label);
                    if (button.hasAttribute('title')) button.title = label;
                });
            }

            function bootstrap() {
                const figures = document.querySelectorAll('.mermaid-figure');
                if (!figures.length) return;
                figures.forEach(labelHud);
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
        }
    """

    static func mermaidScript(mode: VendorLoading) -> VendorEmission {
        guard bundledVendorURL("pele.global", ext: "js", subdir: "Vendor/Pele") != nil else {
            return VendorEmission(head: mermaidFallbackScript)
        }
        switch mode {
        case .inline:
            let vendorJS = bundledVendorResource("pele.global", ext: "js", subdir: "Vendor/Pele") ?? ""
            let safeVendor = vendorJS.replacingOccurrences(of: "</script", with: "<\\/script")
            return VendorEmission(
                body: """
                <script>
                \(safeVendor)

                const __mdpMermaid = \(mermaidInitWiring);
                if (window.MdPreview && window.MdPreview.registerReapplier) {
                    window.MdPreview.registerReapplier(__mdpMermaid.bootstrap);
                }
                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', __mdpMermaid.bootstrap, { once: true });
                } else {
                    __mdpMermaid.bootstrap();
                }
                </script>
                """
            )
        case .lazy:
            return VendorEmission(head: """
            <script>
            (() => {
                let mm = null;
                let markLoaded;
                const loaded = new Promise((resolve) => { markLoaded = resolve; });
                // Print or export can start before the bundle arrives. Until
                // the wiring replaces it, this waits for the bundle (a few
                // seconds at most) so the capture holds drawn diagrams. If it
                // never arrives, the figures say so, as with a missing
                // bundle, instead of exporting bare source as if it were
                // drawn; the rest of the document still exports.
                let waitLimit = null;
                window.MdPreview = window.MdPreview || {};
                window.MdPreview.mermaidRenderAll = async () => {
                    waitLimit = waitLimit || new Promise((resolve) => setTimeout(resolve, 5000));
                    await Promise.race([loaded, waitLimit]);
                    if (mm) return mm.renderAll();
                    \(markUndrawnFiguresJS)
                };
                window.MdPreviewLazy.lazyRenderer({
                    src: '\(MarkdownAssetScheme.vendorURL("pele.global.js"))',
                    run: () => {
                        mm = mm || \(mermaidInitWiring);
                        mm.bootstrap();
                        markLoaded();
                    },
                });
            })();
            </script>
            """)
        }
    }
}
