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
            <div class="mermaid-stage"><div class="mermaid">
            \(diagram)
            </div></div>
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

    private static let mermaidFallbackScript = """
    <script>
    window.addEventListener('load', () => {
        document.querySelectorAll('.mermaid').forEach((node) => {
            node.classList.add('mermaid-error');
            node.textContent = \(javaScriptStringLiteral(
                NSLocalizedString(
                    "Mermaid renderer is unavailable.\n\n",
                    comment: "Mermaid rendering error"
                )
            )) + node.textContent;
        });
    });
    </script>
    """

    /// Shared by the reader and editor. Mermaid's larger bundle is evaluated
    /// only for explicit Mermaid features or when Pele cannot render a diagram.
    /// Inline pages keep the fallback inert so Quick Look stays entirely offline.
    static let diagramRendererWiring = """
    (() => {
        if (window.MdPreviewDiagrams) return;
        let fallbackPromise = null;
        let initializedTheme = null;
        let nextID = 0;
        const fontFamily = '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif';

        async function loadMermaid() {
            if (window.mermaid) return window.mermaid;
            if (!fallbackPromise) {
                fallbackPromise = (async () => {
                    const source = document.getElementById('md-mermaid-fallback-source');
                    if (source) {
                        const script = document.createElement('script');
                        script.textContent = source.textContent;
                        document.head.appendChild(script);
                        script.remove();
                    } else {
                        await window.MdPreviewLazy.loadScript('\(MarkdownAssetScheme.vendorURL("mermaid.min.js"))');
                    }
                    if (!window.mermaid) throw new Error('Mermaid renderer is unavailable');
                    // The host owns rendering, including offscreen export. Do
                    // not let Mermaid's window-load handler process nodes again.
                    window.mermaid.startOnLoad = false;
                    return window.mermaid;
                })().catch(error => {
                    fallbackPromise = null;
                    throw error;
                });
            }
            return fallbackPromise;
        }

        function needsMermaid(source) {
            // Preserve authored configuration, HTML labels, styling and icons
            // rather than silently accepting a different interpretation.
            return /^\\s*---(?:\\r?\\n|$)/.test(source)
                || /%%\\s*\\{/.test(source)
                || /<\\/?[a-z][^>]*>/i.test(source)
                || /(?:^|[\\r\\n;])\\s*(?:classDef|style|linkStyle|click)\\s/.test(source)
                || /@\\s*\\{[^}]*\\b(?:icon|img)\\s*:|::icon\\(/.test(source)
                || /\\b(?:fa|fab|far|fas|fal|fad):[\\w-]+/.test(source);
        }

        function colorize(svg, theme) {
            // Keep colors and Pele's internal CSS aliases on the SVG itself.
            // Popups, PDF snapshots and EPUB rasterization leave the document
            // stylesheet behind and must not depend on inherited variables.
            const colors = theme === 'dark'
                ? ['#1e1e1e', '#f5f5f7', '#aeaeb2', '#d1d1d6', '#2c2c2e', '#3a3a3c', '#8e8e93', '#65a9ff']
                : ['#ffffff', '#1d1d1f', '#6e6e73', '#5b5b60', '#f5f5f7', '#e5e5ea', '#8e8e93', '#0066cc'];
            ['bg', 'fg', 'muted', 'line', 'surface', 'surface-alt', 'border', 'accent'].forEach((key, index) => {
                svg.style.setProperty('--pele-' + key, colors[index]);
            });
        }

        async function render(source, { id, theme } = {}) {
            id = id || 'md-preview-diagram-' + (++nextID);
            theme = theme || (window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default');
            if (window.pele && !needsMermaid(source)) {
                try {
                    if (!window.pele.supports(source)) throw new Error('Unsupported Pele diagram');
                    const result = window.pele.render(source, {
                        idPrefix: id, fontFamily, responsive: false,
                        autoDirection: false, links: false
                    });
                    const holder = document.createElement('div');
                    holder.innerHTML = result.svg;
                    const svg = holder.querySelector('svg');
                    if (!svg) throw new Error('Pele returned no SVG');
                    colorize(svg, theme);
                    return { svg: svg.outerHTML, renderer: 'pele' };
                } catch (_) {
                    // A recognized diagram type can still contain syntax Pele
                    // does not accept. Retry the original source with Mermaid.
                }
            }
            const mermaid = await loadMermaid();
            if (initializedTheme !== theme) {
                mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme, fontFamily });
                initializedTheme = theme;
            }
            try {
                // Match mermaid.run's trimming: the reader's HTML wrapper
                // adds a newline before YAML frontmatter, which Mermaid's
                // direct render API otherwise treats as diagram syntax.
                const result = await mermaid.render(id, source.trim());
                return { svg: result.svg, renderer: 'mermaid' };
            } finally {
                // Mermaid can leave a temporary error SVG behind when parse
                // fails. The host displays the original source in its figure.
                document.getElementById('d' + id)?.remove();
            }
        }

        window.MdPreviewDiagrams = { render };
    })();
    """

    /// Both bundles are local. The fallback script is text until the adapter
    /// needs it; unlike wrapping it in a function, this avoids parsing it early.
    static func inlineDiagramScripts(mermaidJavaScript: String) -> String {
        let pele = bundledVendorResource("pele.global", ext: "js", subdir: "Vendor/Pele") ?? ""
        return """
        <script type="application/octet-stream" id="md-mermaid-fallback-source">\(mermaidJavaScript.replacingOccurrences(of: "</script", with: "<\\/script"))</script>
        <script>
        \(pele.replacingOccurrences(of: "</script", with: "<\\/script"))
        \(diagramRendererWiring)
        </script>
        """
    }

    /// Mermaid pan/zoom/HUD/popup wiring. Internal so SPM helper tests can
    /// drive the real bootstrap path (with a stub `mermaid` + message host).
    static let mermaidInitWiring = """
    (() => {
            const fillWidthLabel = \(javaScriptStringLiteral(
                NSLocalizedString("Fill width", comment: "Mermaid diagram control")
            ));
            const fitDiagramLabel = \(javaScriptStringLiteral(
                NSLocalizedString("Fit diagram", comment: "Mermaid diagram control")
            ));
            const states = new WeakMap();
            const queue = [];
            let drainPromise = null;
            let initializedTheme = null;
            let themeOverride = null;

            function selectedTheme() {
                const nativeScheme = document.documentElement.dataset.mdpColorScheme;
                if (nativeScheme) return nativeScheme === 'dark' ? 'dark' : 'default';
                const dark = window.matchMedia
                    && window.matchMedia('(prefers-color-scheme: dark)').matches;
                return dark ? 'dark' : 'default';
            }

            // Paper printing forces the light palette while mermaid bakes its
            // theme into the SVG, so the host can pin a theme for the length
            // of a print operation.
            function activeTheme() {
                return themeOverride || selectedTheme();
            }

            function ensureInit(theme) {
                if (initializedTheme === theme) return;
                initializedTheme = theme;
                mermaid.initialize({
                    startOnLoad: false,
                    theme,
                    securityLevel: 'strict',
                    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif'
                });
            }

            function drain() {
                if (drainPromise) return drainPromise;
                drainPromise = (async () => {
                    while (queue.length) {
                        const figure = queue.shift();
                        try {
                            await renderOne(figure);
                        } catch (err) {
                            figure.classList.add('mermaid-error');
                        }
                    }
                })().then(() => {
                    drainPromise = null;
                    if (queue.length) return drain();
                    window.dispatchEvent(new Event('md-preview-mermaid-rendered'));
                });
                return drainPromise;
            }

            // Rendering is viewport-driven, so pagination (print/export) must
            // force every remaining figure through the queue and wait for the
            // drain to settle before the page is captured. Passing a theme
            // pins it (and re-renders mismatched figures) until the next call
            // without one restores the on-screen theme.
            async function renderAll(theme) {
                themeOverride = theme || null;
                const want = activeTheme();
                document.querySelectorAll('.mermaid-figure').forEach((figure) => {
                    const node = figure.querySelector('.mermaid');
                    if (!node || queue.includes(figure)) return;
                    if (node.dataset.mmDone !== '1' || node.dataset.mmTheme !== want) {
                        queue.push(figure);
                    }
                });
                while (queue.length || drainPromise) {
                    await drain();
                }
            }

            async function renderOne(figure) {
                const theme = activeTheme();
                const node = figure.querySelector('.mermaid');
                if (!node) return;
                if (node.dataset.mmDone === '1') {
                    if (node.dataset.mmTheme === theme) return;
                    if (typeof node.__mdSrc !== 'string') return;
                    // Theme change: put the stashed source back and clear any
                    // pan/zoom transform now, so a pagination that starts
                    // before the next frame never captures a stale state.
                    const prior = states.get(figure);
                    if (prior && prior.surface) prior.surface.style.transform = '';
                    node.textContent = node.__mdSrc;
                    node.removeAttribute('data-processed');
                    delete node.dataset.mmDone;
                } else {
                    // Pre-render source, stashed so MdPreview.update can pair
                    // unchanged diagrams with their SVGs during DOM diffs.
                    node.__mdSrc = node.textContent;
                }
                try {
                    if (window.MdPreviewDiagrams) {
                        const result = await window.MdPreviewDiagrams.render(node.__mdSrc, { theme });
                        node.innerHTML = result.svg;
                        node.dataset.mmRenderer = result.renderer;
                    } else {
                        ensureInit(theme);
                        await mermaid.run({ nodes: [node], suppressErrors: true });
                    }
                } catch (err) {
                    node.textContent = node.__mdSrc;
                    figure.classList.add('mermaid-error');
                    return;
                }
                const svg = node.querySelector('svg');
                if (!svg) {
                    figure.classList.add('mermaid-error');
                    return;
                }
                node.dataset.mmDone = '1';
                node.dataset.mmTheme = theme;
                figure.classList.remove('mermaid-error');
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
                }

                const alreadyWired = states.has(figure);
                const state = {
                    tx: 0, ty: 0, scale: 1, min: 1, max: 8,
                    rect: null, raf: 0, dragging: false,
                    lastX: 0, lastY: 0, surface,
                    vbW, vbH, svg
                };
                states.set(figure, state);
                cacheRect(figure);

                // A theme re-render reuses the figure and its listeners; only
                // the state and HUD need resetting for the fresh SVG.
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
                if (s) s.rect = figure.getBoundingClientRect();
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
                // Pele stores its palette, CSS aliases and font on the SVG.
                // Clear preview geometry without discarding those styles.
                ['width', 'height', 'transform'].forEach(key => clone.style.removeProperty(key));
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
                if (s.scale <= 1.001) { s.tx = 0; s.ty = 0; }
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
                if (s.scale > 1.001) {
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
                    for (const entry of entries) {
                        if (entry.isIntersecting) {
                            io.unobserve(entry.target);
                            queue.push(entry.target);
                            ro.observe(entry.target);
                            drain();
                        }
                    }
                }, { rootMargin: '300px 0px' });
                figures.forEach((f) => io.observe(f));
            }

            window.MdPreview = window.MdPreview || {};
            window.MdPreview.mermaidRenderAll = renderAll;

            return { bootstrap };
        })()
    """

    static var paperMermaidScript: String {
        let vendor = bundledVendorResource("mermaid.min", ext: "js", subdir: "Vendor/Mermaid") ?? ""
        let pele = bundledVendorResource("pele.global", ext: "js", subdir: "Vendor/Pele") ?? ""
        return pele + "\n" + vendor + "\nmermaid.startOnLoad = false;\n" + diagramRendererWiring + "\n" + mermaidInitWiring
            + ";\nvoid 0;"
    }

    static func mermaidScript(mode: VendorLoading) -> VendorEmission {
        guard bundledVendorURL("mermaid.min", ext: "js", subdir: "Vendor/Mermaid") != nil else {
            return VendorEmission(head: mermaidFallbackScript)
        }
        switch mode {
        case .inline:
            let vendorJS = bundledVendorResource("mermaid.min", ext: "js", subdir: "Vendor/Mermaid") ?? ""
            return VendorEmission(
                body: """
                \(inlineDiagramScripts(mermaidJavaScript: vendorJS))
                <script>
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
            \(diagramRendererWiring)
            (() => {
                let mm = null;
                let ready = false;
                function run() {
                    if (!ready) return;
                    mm = mm || \(mermaidInitWiring);
                    mm.bootstrap();
                }
                window.MdPreview.registerReapplier(run);
                window.MdPreviewLazy.afterPaint(async () => {
                    try {
                        await window.MdPreviewLazy.loadScript('\(MarkdownAssetScheme.vendorURL("pele.global.js"))');
                    } catch (_) {
                        // The compatibility renderer also covers a missing or
                        // unloadable Pele asset, not just rejected diagrams.
                    }
                    ready = true;
                    run();
                });
            })();
            </script>
            """)
        }
    }
}
