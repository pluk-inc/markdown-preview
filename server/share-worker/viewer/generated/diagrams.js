/* Generated from the app's MarkdownHTML by ShareViewerKitTests.
   Do not edit; run MDP_WRITE_VIEWER_KIT=1 swift test --filter ShareViewerKitTests. */
window.MdpDiagrams = {
    // (messages, copyText) => { bootstrap, renderAll }
    wiring: (messages, copyText) => {
        const states = new WeakMap();
        const renderOptions = { autoDirection: false,
  get fontFamily() { return getComputedStyle(document.body).fontFamily; },
  get fontSize() { return parseFloat(getComputedStyle(document.body).fontSize); } };
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

            figure.addEventListener('pointerenter', () => {
                postMermaidHover(true);
                diagramHUD?.set(figure);
            });
            figure.addEventListener('pointerleave', () => {
                postMermaidHover(false);
                if (diagramHUD?.target === figure) diagramHUD.set(null);
            });
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
        const diagramHUD = makeNativeHUDReporter('diagramHUD', (figure) =>
            figure.classList.contains('mermaid-error') || !figure.querySelector('.mermaid svg') ? null : {
                level: figure.querySelector('.mermaid-hud-level')?.textContent || '100%',
                popup: !!figure.querySelector('[data-mm-act="popup"]')
            });
        if (diagramHUD) {
            // No focus here: the click was on the host's glass, and
            // focusing the figure from script would draw its focus ring.
            window.mdpDiagramHUDAction = (act) => {
                if (diagramHUD.target?.isConnected) runHudAction(diagramHUD.target, act);
            };
            // A figure under the pointer that draws later gets its HUD then.
            window.addEventListener('md-preview-mermaid-rendered', () => diagramHUD.refresh());
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
                const level = Math.round(s.scale * 100) + '%';
                // A pan keeps the level: only a new one reaches the host.
                if (lvl && lvl.textContent !== level) {
                    lvl.textContent = level;
                    if (diagramHUD?.target === figure) diagramHUD.refresh();
                }
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
            runHudAction(figure, btn.dataset.mmAct);
        }

        function runHudAction(figure, act) {
            switch (act) {
                case 'in':    step(figure, 1.25); break;
                case 'out':   step(figure, 0.8);  break;
                case 'reset': reset(figure);      break;
                case 'popup': openPopup(figure);  break;
                case 'copy':  copySource(figure); break;
            }
        }

        // Copies the text the figure was drawn from, through the host's
        // `copyText`. The HTML button shows a check mark for a moment,
        // as a code block's does.
        async function copySource(figure) {
            const value = figure.querySelector('.mermaid')?.__mdSrc?.replace(/\s+$/, '');
            if (!value || !(await copyText(value))) return;
            const button = figure.querySelector('.mermaid-hud [data-mm-act="copy"]');
            if (!button) return;
            button.classList.add('is-copied');
            button.setAttribute('aria-label', messages.copied);
            clearTimeout(button.__mdCopyTimer);
            button.__mdCopyTimer = setTimeout(() => {
                button.classList.remove('is-copied');
                button.setAttribute('aria-label', messages.copy);
            }, 1100);
        }

        const ro = new ResizeObserver((entries) => {
            for (const entry of entries) cacheRect(entry.target);
        });

        // The HUD in the HTML carries the words of whoever rendered it;
        // these are the reader's (the same in the app).
        const hudLabels = { out: messages.zoomOut, in: messages.zoomIn, reset: messages.resetZoom, copy: messages.copy };
        function labelHud(figure) {
            figure.querySelectorAll('.mermaid-hud [data-mm-act]').forEach((button) => {
                const label = hudLabels[button.dataset.mmAct];
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
    },
    // The app's diagramMessagesJS in each of its languages.
    messages: {
        en: {
    errors: {
        'unsupported-diagram': "This diagram type is not supported.",
        syntax: "The diagram has a syntax error.",
        semantic: "The diagram is not valid.",
        limit: "The diagram is too large to draw."
    },
    generic: "The diagram could not be drawn.",
    position: "Line %d, column %d",
    empty: "This diagram is empty.",
    emptyHint: "Empty diagram. Click to add Mermaid source.",
    unavailable: "Mermaid renderer is unavailable.\n\n".trim(),
    zoomOut: "Zoom Out",
    zoomIn: "Zoom In",
    resetZoom: "Reset zoom",
    copy: "Copy",
    copied: "Copied"
},
        ja: {
    errors: {
        'unsupported-diagram': "この種類のダイアグラムには対応していません。",
        syntax: "ダイアグラムに構文エラーがあります。",
        semantic: "ダイアグラムが正しくありません。",
        limit: "ダイアグラムが大きすぎるため描画できません。"
    },
    generic: "ダイアグラムを描画できませんでした。",
    position: "%1$d 行目、%2$d 列目",
    empty: "このダイアグラムは空です。",
    emptyHint: "空のダイアグラムです。クリックして Mermaid のソースを追加します。",
    unavailable: "Mermaid レンダラーを利用できません。\n\n".trim(),
    zoomOut: "縮小",
    zoomIn: "拡大",
    resetZoom: "拡大\/縮小をリセット",
    copy: "コピー",
    copied: "コピーしました"
},
        "zh-Hans": {
    errors: {
        'unsupported-diagram': "不支持此图表类型。",
        syntax: "图表存在语法错误。",
        semantic: "图表无效。",
        limit: "图表过大，无法绘制。"
    },
    generic: "无法绘制图表。",
    position: "第 %1$d 行，第 %2$d 列",
    empty: "此图表为空。",
    emptyHint: "空图表。点按以添加 Mermaid 源代码。",
    unavailable: "Mermaid 渲染器不可用。\n\n".trim(),
    zoomOut: "缩小",
    zoomIn: "放大",
    resetZoom: "重置缩放",
    copy: "拷贝",
    copied: "已拷贝"
},
        pl: {
    errors: {
        'unsupported-diagram': "Ten rodzaj diagramu nie jest obsługiwany.",
        syntax: "Diagram zawiera błąd składni.",
        semantic: "Diagram jest nieprawidłowy.",
        limit: "Diagram jest zbyt duży, aby go narysować."
    },
    generic: "Nie można narysować diagramu.",
    position: "Wiersz %d, kolumna %d",
    empty: "Ten diagram jest pusty.",
    emptyHint: "Pusty diagram. Kliknij, aby dodać kod źródłowy Mermaid.",
    unavailable: "Mechanizm renderowania Mermaid jest niedostępny.\n\n".trim(),
    zoomOut: "Oddal",
    zoomIn: "Przybliż",
    resetZoom: "Wyzeruj powiększenie",
    copy: "Kopiuj",
    copied: "Skopiowano"
},
        fa: {
    errors: {
        'unsupported-diagram': "این نوع نمودار پشتیبانی نمی‌شود.",
        syntax: "نمودار خطای نحوی دارد.",
        semantic: "نمودار معتبر نیست.",
        limit: "نمودار برای رسم بیش از حد بزرگ است."
    },
    generic: "رسم نمودار ممکن نشد.",
    position: "خط %1$d، ستون %2$d",
    empty: "این نمودار خالی است.",
    emptyHint: "نمودار خالی است. برای افزودن کد Mermaid کلیک کنید.",
    unavailable: "رندرکنندهٔ Mermaid در دسترس نیست.\n\n".trim(),
    zoomOut: "کوچک‌نمایی",
    zoomIn: "بزرگ‌نمایی",
    resetZoom: "بازنشانی بزرگ‌نمایی",
    copy: "کپی",
    copied: "کپی شد"
},
    },
};
