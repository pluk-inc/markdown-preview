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
    /// `{kind:"renderComplete"}` to the host. Listens for `md-preview-*-rendered`
    /// events and re-checks; a 50 ms poll remains as a safety net. The Swift
    /// side also applies a hard timeout.
    ///
    /// Done-marker contract (setters in `MarkdownHTML` must match these selectors):
    /// - KaTeX: `el.dataset.mathDone = '1'` → `[data-math-done="1"]`
    /// - highlight.js: `block.dataset.hljsDone = '1'` → `[data-hljs-done="1"]`
    /// - Mermaid: `node.dataset.mmDone = '1'` → `node.dataset.mmDone !== '1'`
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

            ['md-preview-math-rendered',
             'md-preview-mermaid-rendered',
             'md-preview-hljs-rendered'].forEach((name) => {
                window.addEventListener(name, check);
            });

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', check, { once: true });
            } else {
                check();
            }
        })();
        </script>
        """
    }

    /// JS body of `function highlightAll()`. Offscreen export WebViews throttle
    /// `requestAnimationFrame` when not in a window hierarchy, so the export path
    /// (`window.__mdPreviewRenderAll`) highlights every block synchronously; the
    /// live preview keeps the rAF time-sliced loop.
    static let highlightAllBody = """
    function highlightAll() {
        if (typeof hljs === 'undefined') return;
        if (!document.querySelector('pre code[class*="language-"]:not([data-hljs-done="1"])')) return;
        const blocks = Array.prototype.slice.call(
            document.querySelectorAll('pre code[class*="language-"]:not([data-hljs-done="1"])')
        );
        MdPreviewPerf.log('hljs highlightAll start', blocks.length + ' blocks');
        if (window.__mdPreviewRenderAll) {
            for (let i = 0; i < blocks.length; i++) {
                const block = blocks[i];
                try {
                    hljs.highlightElement(block);
                } catch (e) {
                    MdPreviewPerf.log('hljs threw', String(e && e.message || e));
                }
                block.dataset.hljsDone = '1';
            }
            window.dispatchEvent(new Event('md-preview-hljs-rendered'));
            MdPreviewPerf.log('hljs all done');
            return;
        }
        let i = 0;
        function step() {
            const sliceStart = MdPreviewPerf.now();
            while (i < blocks.length) {
                const block = blocks[i++];
                try {
                    hljs.highlightElement(block);
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

    /// Mermaid wiring IIFE. Assumes the `mermaid` global has been (or will be)
    /// defined by the time DOMContentLoaded fires. Export sets
    /// `window.__mdPreviewRenderAll` so `bootstrap()` enqueues every figure and
    /// calls `drain()` instead of waiting on IntersectionObserver.
    static let mermaidInitWiring = """
    (() => {
            const states = new WeakMap();
            const queue = [];
            let draining = false;
            let initialized = false;

            function ensureInit() {
                if (initialized) return;
                initialized = true;
                const dark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
                mermaid.initialize({
                    startOnLoad: false,
                    theme: dark ? 'dark' : 'default',
                    securityLevel: 'strict',
                    fontFamily: '-apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif'
                });
            }

            async function drain() {
                if (draining) return;
                draining = true;
                while (queue.length) {
                    const figure = queue.shift();
                    await renderOne(figure);
                }
                draining = false;
                window.dispatchEvent(new Event('md-preview-mermaid-rendered'));
            }

            async function renderOne(figure) {
                ensureInit();
                const node = figure.querySelector('.mermaid');
                if (!node || node.dataset.mmDone === '1') return;
                try {
                    await mermaid.run({ nodes: [node], suppressErrors: true });
                } catch (err) {
                    figure.classList.add('mermaid-error');
                    return;
                }
                const svg = node.querySelector('svg');
                if (!svg) {
                    figure.classList.add('mermaid-error');
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
                svg.style.width = '100%';
                svg.style.height = '100%';
                svg.style.transformOrigin = '0 0';

                // Stable layout: figure claims height from the diagram's aspect ratio,
                // capped by max-height so massive diagrams don't push the page.
                if (vbW > 0 && vbH > 0) {
                    figure.style.setProperty('--mm-aspect', vbW + ' / ' + vbH);
                }

                const state = {
                    tx: 0, ty: 0, scale: 1, min: 1, max: 8,
                    rect: null, raf: 0, dragging: false,
                    lastX: 0, lastY: 0, svg
                };
                states.set(figure, state);
                cacheRect(figure);

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

            function apply(figure, s) {
                if (s.raf) return;
                s.raf = requestAnimationFrame(() => {
                    s.raf = 0;
                    s.svg.style.transform = 'translate(' + s.tx + 'px,' + s.ty + 'px) scale(' + s.scale + ')';
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
                }
            }

            const ro = new ResizeObserver((entries) => {
                for (const entry of entries) cacheRect(entry.target);
            });

            function bootstrap() {
                const figures = document.querySelectorAll('.mermaid-figure');
                if (!figures.length) return;
                if (window.__mdPreviewRenderAll) {
                    figures.forEach((f) => { queue.push(f); ro.observe(f); });
                    drain();
                    return;
                }
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

            return { bootstrap };
        })()
    """

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
