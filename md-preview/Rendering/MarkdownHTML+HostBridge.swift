//
//  MarkdownHTML+HostBridge.swift
//  md-preview
//
//  The MdPreview JS bootstrap injected into every rendered page.
//

import Foundation

// `nonisolated` matters: the targets default to MainActor isolation, and
// rendering runs off the main actor.
nonisolated extension MarkdownHTML {
    // Debug-only perf instrumentation. Routes labelled timings through the
    // host bridge so `[mdp-perf +Xms]` entries land in Xcode's console while
    // diagnosing load-phase regressions. Compiled out of release builds —
    // no-op shims keep call sites unchanged.
    #if DEBUG
    private static let perfBridgeScript = """
    const perfT0 = (typeof performance !== 'undefined' && performance.now)
        ? performance.now() : 0;
    function perfNow() {
        return (typeof performance !== 'undefined' && performance.now)
            ? performance.now() - perfT0 : 0;
    }
    function perfLog(label, detail) {
        const dt = perfNow().toFixed(1);
        const msg = '[mdp-perf +' + dt + 'ms] ' + label
            + (detail !== undefined ? ' ' + detail : '');
        try { post({ kind: 'log', message: msg }); } catch (e) {}
    }
    window.MdPreviewPerf = { now: perfNow, log: perfLog, t0: perfT0 };
    perfLog('script eval');

    if (typeof PerformanceObserver === 'function') {
        try {
            // Disconnect after FCP — paint emits at most two entries
            // (first-paint, first-contentful-paint), no need to keep the
            // observer pinned for the WebView's lifetime.
            const seen = new Set();
            const po = new PerformanceObserver((list) => {
                for (const entry of list.getEntries()) {
                    perfLog('paint:' + entry.name, entry.startTime.toFixed(1) + 'ms');
                    seen.add(entry.name);
                }
                if (seen.has('first-contentful-paint')) po.disconnect();
            });
            po.observe({ type: 'paint', buffered: true });
        } catch (e) {}
    }
    """
    #else
    private static let perfBridgeScript = """
    function perfNow() { return 0; }
    function perfLog() {}
    window.MdPreviewPerf = { now: perfNow, log: perfLog };
    """
    #endif

    // Always-on host bridge: pushes the document height to the AppKit host via
    // a WKScriptMessageHandler instead of having the host poll. Quietly no-ops
    // when the bridge isn't installed (e.g. Quick Look render).
    // Internal so the WebKit regression tests can exercise the exact
    // `MdPreview.update` pipeline shipped by the app with the bundled
    // DOMPurify and morphdom runtimes.
    static let hostBridgeScript: String = """
    <script>
    (() => {
        const localized = {
            copy: \(javaScriptStringLiteral(NSLocalizedString("Copy", comment: "Code block copy button"))),
            copied: \(javaScriptStringLiteral(NSLocalizedString("Copied", comment: "Code block copy confirmation"))),
            copyCode: \(javaScriptStringLiteral(NSLocalizedString("Copy code", comment: "Code block copy button accessibility label"))),
            codeCopied: \(javaScriptStringLiteral(NSLocalizedString("Code copied", comment: "Code block copy confirmation accessibility label")))
        };
        let hasHostBridge = false;
        const post = (() => {
            try {
                const h = window.webkit && window.webkit.messageHandlers
                    && window.webkit.messageHandlers.mdPreviewHost;
                if (!h) return () => false;
                hasHostBridge = true;
                return (msg) => {
                    h.postMessage(msg);
                    return true;
                };
            } catch (e) { return () => false; }
        })();

        \(perfBridgeScript)

        function measureHeight() {
            const body = document.body;
            const article = document.querySelector('.markdown-body');
            if (!body || !article) return 1;
            const rect = article.getBoundingClientRect();
            const cs = getComputedStyle(body);
            const pt = parseFloat(cs.paddingTop) || 0;
            const pb = parseFloat(cs.paddingBottom) || 0;
            return Math.max(rect.bottom + pb, pt + article.scrollHeight + pb, 1);
        }

        let last = -1;
        let raf = 0;

        function pushHeight() {
            if (raf) return;
            raf = requestAnimationFrame(() => {
                raf = 0;
                const h = Math.ceil(measureHeight());
                if (h !== last) {
                    last = h;
                    post({ kind: 'height', value: h });
                }
            });
        }

        // Scroll bridge: with compositor-scrolled WKWebView (macOS 26 SDK)
        // the host can't observe scrolling natively — the page reports it.
        let lastScroll = -1;
        let scrollRaf = 0;
        function pushScroll() {
            if (scrollRaf) return;
            scrollRaf = requestAnimationFrame(() => {
                scrollRaf = 0;
                const y = window.scrollY || document.documentElement.scrollTop || 0;
                if (y !== lastScroll) {
                    lastScroll = y;
                    post({ kind: 'scrollPosition', value: y });
                }
            });
        }
        window.addEventListener('scroll', pushScroll, { passive: true });

        window.MdPreviewHost = { pushHeight, measureHeight };

        function elementForEventTarget(target) {
            if (target instanceof Element) return target;
            if (target && target.parentElement instanceof Element) return target.parentElement;
            return document.activeElement instanceof Element ? document.activeElement : null;
        }

        function keyBelongsToFocusedControl(target) {
            const el = elementForEventTarget(target);
            if (!el) return false;
            if (el.isContentEditable) return true;
            return !!el.closest([
                'button',
                'input',
                'select',
                'textarea',
                'summary',
                'audio',
                'video',
                '[contenteditable]',
                '[role="button"]',
                '[role="checkbox"]',
                '[role="switch"]',
                '[role="textbox"]',
                '[role="combobox"]',
                '[role="listbox"]',
                '[role="menuitem"]'
            ].join(','));
        }

        function handlePreviewScrollKey(event) {
            if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return false;
            if (keyBelongsToFocusedControl(event.target)) return false;

            const isSpace = event.key === ' ' || event.key === 'Spacebar' || event.code === 'Space';
            if (isSpace) {
                return post({ kind: 'scroll', value: event.shiftKey ? 'pageUp' : 'pageDown' });
            }

            if (event.shiftKey) return false;
            const key = (event.key || '').toLowerCase();
            if (key === 'j') return post({ kind: 'scroll', value: 'lineDown' });
            if (key === 'k') return post({ kind: 'scroll', value: 'lineUp' });
            return false;
        }

        document.addEventListener('keydown', (event) => {
            if (handlePreviewScrollKey(event)) {
                event.preventDefault();
                event.stopPropagation();
            }
        }, true);

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

                const button = document.createElement('button');
                button.type = 'button';
                button.className = 'md-code-copy';
                button.textContent = localized.copy;
                button.setAttribute('aria-label', localized.copyCode);
                wrap.appendChild(button);
            });
        }

        function cloneSelectionWithoutCopyButtons(selection) {
            const fragment = document.createDocumentFragment();
            for (let i = 0; i < selection.rangeCount; i += 1) {
                fragment.appendChild(selection.getRangeAt(i).cloneContents());
            }
            const buttons = fragment.querySelectorAll('.md-code-copy');
            if (buttons.length === 0) return null;
            buttons.forEach((button) => button.remove());
            return fragment;
        }

        function plainTextFromFragment(fragment) {
            const div = document.createElement('div');
            div.appendChild(fragment.cloneNode(true));
            return div.innerText || div.textContent || '';
        }

        function htmlFromFragment(fragment) {
            const div = document.createElement('div');
            div.appendChild(fragment.cloneNode(true));
            return div.innerHTML;
        }

        async function copyCodeBlock(button) {
            const wrap = button.parentElement;
            const code = wrap && wrap.querySelector('pre > code');
            if (!code) return;
            const text = code.textContent || '';
            let copied = false;
            try {
                copied = post({ kind: 'copyCode', value: text });
            } catch (e) {}
            if (!copied && navigator.clipboard && navigator.clipboard.writeText) {
                try {
                    await navigator.clipboard.writeText(text);
                    copied = true;
                } catch (e) {}
            }
            if (!copied) return;
            button.textContent = localized.copied;
            button.setAttribute('aria-label', localized.codeCopied);
            button.classList.add('is-copied');
            clearTimeout(button.__mdCopyTimer);
            button.__mdCopyTimer = setTimeout(() => {
                button.textContent = localized.copy;
                button.setAttribute('aria-label', localized.copyCode);
                button.classList.remove('is-copied');
            }, 1100);
        }

        document.addEventListener('click', (event) => {
            const button = event.target.closest('.md-code-copy');
            if (!button) return;
            event.preventDefault();
            event.stopPropagation();
            copyCodeBlock(button);
        });

        function enableTaskCheckboxes() {
            if (!hasHostBridge) return;
            document.querySelectorAll('.task-list-item-checkbox').forEach((checkbox) => {
                checkbox.disabled = false;
            });
        }

        let activeTableCell = null;
        let nextTableContextToken = 1;
        let pendingTableContextAction = null;
        let selectedTablePart = null;
        let tableCellDrag = null;
        let suppressNextTableClick = false;

        function tableMessage(cell, operation, value, pendingValue, pendingCell) {
            const table = cell && cell.closest('table[data-source-start][data-source-end]');
            if (!table || table.dataset.tableSaving === '1') return false;
            const start = Number(table.dataset.sourceStart);
            const end = Number(table.dataset.sourceEnd);
            const row = Number(cell.dataset.tableRow);
            const column = Number(cell.dataset.tableColumn);
            if (![start, end, row, column].every(Number.isInteger)) return false;
            table.dataset.tableSaving = '1';
            table.closest('.md-table-editor')?.classList.add('is-saving');
            const message = { kind: 'tableEdit', operation, start, end, row, column };
            if (typeof value === 'string') message.value = value;
            if (typeof pendingValue === 'string') {
                message.pendingValue = pendingValue;
                message.pendingRow = Number(pendingCell?.dataset.tableRow ?? row);
                message.pendingColumn = Number(pendingCell?.dataset.tableColumn ?? column);
            }
            return post(message);
        }

        function finishTableCellEdit(save) {
            const cell = activeTableCell;
            if (!cell) return;
            activeTableCell = null;
            const original = cell.dataset.tableOriginal || '';
            const value = (cell.innerText || '').replace(/\\n+/g, ' ').trim();
            cell.contentEditable = 'false';
            cell.classList.remove('is-editing');
            if (!save) {
                cell.innerHTML = cell.__mdOriginalHTML || '';
                return;
            }
            if (value !== original) {
                tableMessage(cell, 'setCell', value);
            } else {
                cell.innerHTML = cell.__mdOriginalHTML || '';
            }
        }

        function beginTableCellEdit(cell) {
            if (!hasHostBridge || !cell) return false;
            if (cell === activeTableCell) return true;
            clearTablePartSelection();
            finishTableCellEdit(true);
            // Never fall back to rendered text. Without exact source metadata,
            // editing could silently flatten links, emphasis, code, images, or
            // other inline Markdown into plain text.
            if (!cell.hasAttribute('data-table-markdown')) return false;
            cell.__mdOriginalHTML = cell.innerHTML;
            cell.dataset.tableOriginal = cell.dataset.tableMarkdown || '';
            cell.textContent = cell.dataset.tableOriginal;
            cell.contentEditable = 'plaintext-only';
            cell.classList.add('is-editing');
            activeTableCell = cell;
            cell.focus();
            const selection = window.getSelection();
            if (selection) {
                const range = document.createRange();
                range.selectNodeContents(cell);
                range.collapse(false);
                selection.removeAllRanges();
                selection.addRange(range);
            }
            return true;
        }

        function clearTablePartSelection() {
            document.querySelectorAll('.is-table-part-selected').forEach((cell) => {
                cell.classList.remove(
                    'is-table-part-selected',
                    'is-table-selection-top',
                    'is-table-selection-right',
                    'is-table-selection-bottom',
                    'is-table-selection-left'
                );
            });
            selectedTablePart?.editor.classList.remove(
                'is-table-row-selected',
                'is-table-column-selected',
                'is-table-range-selected'
            );
            selectedTablePart?.editor.removeAttribute('aria-label');
            selectedTablePart = null;
        }

        function applyTableSelection(cell, kind, bounds) {
            if (!cell) return;
            finishTableCellEdit(true);
            clearTablePartSelection();
            const editor = cell.closest('.md-table-editor');
            const table = cell.closest('table');
            if (!editor || !table) return;
            const items = Array.from(table.querySelectorAll('[data-table-row][data-table-column]'))
                .filter((item) => {
                    const row = Number(item.dataset.tableRow);
                    const column = Number(item.dataset.tableColumn);
                    return row >= bounds.top && row <= bounds.bottom
                        && column >= bounds.left && column <= bounds.right;
                });
            items.forEach((item) => {
                item.classList.add('is-table-part-selected');
                const row = Number(item.dataset.tableRow);
                const column = Number(item.dataset.tableColumn);
                if (row === bounds.top) item.classList.add('is-table-selection-top');
                if (column === bounds.right) item.classList.add('is-table-selection-right');
                if (row === bounds.bottom) item.classList.add('is-table-selection-bottom');
                if (column === bounds.left) item.classList.add('is-table-selection-left');
            });
            editor.classList.add(
                kind === 'row'
                    ? 'is-table-row-selected'
                    : kind === 'column'
                        ? 'is-table-column-selected'
                        : 'is-table-range-selected'
            );
            window.getSelection()?.removeAllRanges();
            selectedTablePart = { cell, kind, editor, bounds };
            editor.tabIndex = 0;
            if (kind === 'range') {
                const rowCount = bounds.bottom - bounds.top + 1;
                const columnCount = bounds.right - bounds.left + 1;
                editor.setAttribute(
                    'aria-label',
                    `Selected ${rowCount} rows by ${columnCount} columns.`
                );
            } else {
                const row = Number(cell.dataset.tableRow);
                const column = Number(cell.dataset.tableColumn);
                const number = kind === 'row' ? row : column + 1;
                editor.setAttribute(
                    'aria-label',
                    `Selected ${kind} ${number}. Press Delete to remove it.`
                );
            }
            editor.focus({ preventScroll: true });
        }

        function selectTablePart(cell, operation) {
            if (!cell) return;
            const table = cell.closest('table');
            if (!table) return;
            const row = Number(cell.dataset.tableRow);
            const column = Number(cell.dataset.tableColumn);
            const kind = operation === 'selectRow' ? 'row' : 'column';
            const bounds = kind === 'row'
                ? { top: row, right: table.rows[0].cells.length - 1, bottom: row, left: 0 }
                : { top: 0, right: column, bottom: table.rows.length - 1, left: column };
            applyTableSelection(cell, kind, bounds);
        }

        function selectTableRange(anchorCell, headCell) {
            if (!anchorCell || !headCell || anchorCell.closest('table') !== headCell.closest('table')) {
                return;
            }
            const anchorRow = Number(anchorCell.dataset.tableRow);
            const anchorColumn = Number(anchorCell.dataset.tableColumn);
            const headRow = Number(headCell.dataset.tableRow);
            const headColumn = Number(headCell.dataset.tableColumn);
            applyTableSelection(anchorCell, 'range', {
                top: Math.min(anchorRow, headRow),
                right: Math.max(anchorColumn, headColumn),
                bottom: Math.max(anchorRow, headRow),
                left: Math.min(anchorColumn, headColumn)
            });
        }

        function performTableStructure(cell, operation) {
            if (!cell) return;
            const table = cell.closest('table');
            const editingCell = activeTableCell && activeTableCell.closest('table') === table
                ? activeTableCell : null;
            let pendingValue = null;
            if (editingCell) {
                const value = (editingCell.innerText || '').replace(/\\n+/g, ' ').trim();
                if (value !== (editingCell.dataset.tableOriginal || '')) pendingValue = value;
                else editingCell.innerHTML = editingCell.__mdOriginalHTML || '';
                activeTableCell = null;
                editingCell.contentEditable = 'false';
                editingCell.classList.remove('is-editing');
            }
            tableMessage(cell, operation, null, pendingValue, editingCell);
        }

        function requestNativeTableContextMenu(cell) {
            const table = cell.closest('table');
            const row = Number(cell.dataset.tableRow);
            const columnCount = table?.rows[0]?.cells.length || 1;
            const token = String(nextTableContextToken++);
            pendingTableContextAction = { token, cell };
            post({
                kind: 'tableContextMenu',
                token,
                canInsertRowAbove: row > 0,
                canDuplicateRow: false,
                canDeleteRow: row > 0,
                canDeleteColumn: columnCount > 1,
                showsDuplicateRow: false
            });
        }

        function enableTableEditing(root = document) {
            if (!hasHostBridge) return;
            root.querySelectorAll('table[data-source-start][data-source-end]').forEach((table) => {
                if (table.closest('.md-table-editor')) return;
                const editor = document.createElement('div');
                editor.className = 'md-table-editor';
                table.parentNode.insertBefore(editor, table);
                const scroll = document.createElement('div');
                scroll.className = 'md-table-scroll';
                editor.appendChild(scroll);
                scroll.appendChild(table);
                table.querySelectorAll('th[data-table-column]').forEach((cell) => {
                    const column = Number(cell.dataset.tableColumn);
                    const placeholder = `Column ${column + 1}`;
                    cell.dataset.placeholder = placeholder;
                    // `innerText` forces layout when the table is already in
                    // the live document. Header emptiness only depends on the
                    // authored content, so `textContent` is sufficient here.
                    if (!(cell.textContent || '').trim()) cell.textContent = '';
                    updateTableHeaderAccessibilityLabel(cell);
                });
            });
        }

        function updateTableHeaderAccessibilityLabel(cell) {
            const placeholder = cell.dataset.placeholder;
            if (!placeholder) return;
            if ((cell.textContent || '').trim()) cell.removeAttribute('aria-label');
            else cell.setAttribute('aria-label', placeholder);
        }

        if (hasHostBridge) {
            // One delegated listener covers both initial and morphed tables.
            document.addEventListener('input', (event) => {
                const cell = event.target.closest?.(
                    '.md-table-editor th[data-table-column]'
                );
                if (cell) updateTableHeaderAccessibilityLabel(cell);
            });
        }

        document.addEventListener('mousedown', (event) => {
            if (event.button !== 0) return;
            const cell = event.target.closest?.('.md-table-editor th, .md-table-editor td');
            if (!cell) return;
            const row = Number(cell.dataset.tableRow);
            const column = Number(cell.dataset.tableColumn);
            if (!Number.isInteger(row) || row < 0 || !Number.isInteger(column)) return;
            tableCellDrag = {
                cell,
                table: cell.closest('table'),
                row,
                column,
                head: cell,
                active: false
            };
        }, true);

        document.addEventListener('mousemove', (event) => {
            if (!tableCellDrag) return;
            const hitTarget = document.elementFromPoint?.(event.clientX, event.clientY);
            const cell = hitTarget?.closest?.('.md-table-editor th, .md-table-editor td')
                || event.target.closest?.('.md-table-editor th, .md-table-editor td');
            if (!cell || cell.closest('table') !== tableCellDrag.table) {
                return;
            }
            if (cell === tableCellDrag.cell && !tableCellDrag.active) return;
            if (cell === tableCellDrag.head) return;
            event.preventDefault();
            tableCellDrag.active = true;
            tableCellDrag.head = cell;
            selectTableRange(tableCellDrag.cell, cell);
        }, true);

        document.addEventListener('mouseup', (event) => {
            if (tableCellDrag?.active) {
                event.preventDefault();
                window.getSelection()?.removeAllRanges();
                suppressNextTableClick = true;
            }
            tableCellDrag = null;
        }, true);

        document.addEventListener('click', (event) => {
            if (suppressNextTableClick) {
                suppressNextTableClick = false;
                event.preventDefault();
                event.stopPropagation();
                return;
            }
            const cell = event.target.closest('.md-table-editor th, .md-table-editor td');
            if (!cell) {
                clearTablePartSelection();
                finishTableCellEdit(true);
                return;
            }
            if (event.target.closest('a, button, input')) return;
            if (beginTableCellEdit(cell)) event.preventDefault();
        });

        document.addEventListener('contextmenu', (event) => {
            const cell = event.target.closest('.md-table-editor th, .md-table-editor td');
            if (!cell) return;
            event.preventDefault();
            beginTableCellEdit(cell);
            requestNativeTableContextMenu(cell);
        });

        document.addEventListener('keydown', (event) => {
            if (selectedTablePart && event.target === selectedTablePart.editor) {
                if (event.key === 'Escape') {
                    event.preventDefault();
                    clearTablePartSelection();
                    return;
                }
                if (event.key === 'Backspace' || event.key === 'Delete') {
                    event.preventDefault();
                    if (selectedTablePart.kind === 'range') return;
                    const selection = selectedTablePart;
                    clearTablePartSelection();
                    performTableStructure(
                        selection.cell,
                        selection.kind === 'row' ? 'deleteRow' : 'deleteColumn'
                    );
                    return;
                }
            }
            if (!activeTableCell || event.target !== activeTableCell) return;
            if (event.key === 'Escape') {
                event.preventDefault();
                finishTableCellEdit(false);
            } else if (event.key === 'Enter' || event.key === 'Tab') {
                event.preventDefault();
                finishTableCellEdit(true);
            }
        });

        document.addEventListener('paste', (event) => {
            if (!activeTableCell || event.target !== activeTableCell || !event.clipboardData) return;
            event.preventDefault();
            document.execCommand('insertText', false, event.clipboardData.getData('text/plain'));
        });

        document.addEventListener('change', (event) => {
            const checkbox = event.target.closest('.task-list-item-checkbox');
            if (!checkbox || !hasHostBridge) return;
            const item = checkbox.closest('[data-source-line]');
            const sourceLine = item && Number(item.dataset.sourceLine);
            if (!Number.isInteger(sourceLine) || sourceLine < 1) {
                checkbox.checked = !checkbox.checked;
                return;
            }
            checkbox.disabled = true;
            if (!post({ kind: 'taskCheckbox', line: sourceLine, checked: checkbox.checked })) {
                checkbox.checked = !checkbox.checked;
                checkbox.disabled = false;
            }
        });

        document.addEventListener('copy', (event) => {
            const selection = window.getSelection();
            if (!selection || selection.rangeCount === 0 || !event.clipboardData) return;
            const fragment = cloneSelectionWithoutCopyButtons(selection);
            if (!fragment) return;
            event.clipboardData.setData('text/plain', plainTextFromFragment(fragment));
            event.clipboardData.setData('text/html', htmlFromFragment(fragment));
            event.preventDefault();
        });

        // Vendor lazy-load helpers. rAF is paused while the WKWebView is
        // offscreen (e.g. during the launch-time warmup before the window
        // becomes visible), so afterPaint also falls back to setTimeout(50).
        window.MdPreviewLazy = {
            afterPaint(cb) {
                function tick() {
                    let fired = false;
                    function fire(via) {
                        if (!fired) {
                            fired = true;
                            perfLog('afterPaint fire', via);
                            cb();
                        }
                    }
                    requestAnimationFrame(() => requestAnimationFrame(() => fire('rAF')));
                    setTimeout(() => fire('timeout'), 50);
                }
                if (document.readyState === 'loading') {
                    document.addEventListener('DOMContentLoaded', tick, { once: true });
                } else {
                    tick();
                }
            },
            loadScript(src) {
                return new Promise((resolve, reject) => {
                    const tStart = perfNow();
                    perfLog('script append', src);
                    const s = document.createElement('script');
                    s.onload = () => {
                        perfLog('script onload', src + ' (+' + (perfNow() - tStart).toFixed(1) + 'ms)');
                        resolve();
                    };
                    s.onerror = () => reject(new Error('failed: ' + src));
                    s.src = src;
                    document.head.appendChild(s);
                });
            },
            // Wires up a renderer whose vendor JS is loaded after first paint.
            // - registers a reapplier that gates on `loaded`, so fast-path
            //   updates don't fire the renderer before its bundle has arrived
            // - on first paint, fetches `src` (and any `extras` after) and
            //   calls `run`
            lazyRenderer({ src, extras, run }) {
                let loaded = false;
                if (window.MdPreview && window.MdPreview.registerReapplier) {
                    window.MdPreview.registerReapplier(() => { if (loaded) run(); });
                }
                this.afterPaint(async () => {
                    try {
                        await this.loadScript(src);
                        loaded = true;
                        run();
                        if (extras) {
                            for (const e of extras) this.loadScript(e).catch(() => {});
                        }
                    } catch (e) {}
                });
            }
        };

        // DOMPurify config. Closes the raw-HTML XSS path on user markdown
        // (EscapingHTMLFormatter passes block- and inline-HTML through per
        // CommonMark). Inline event handlers, <script>, <iframe>, <object>,
        // <embed>, <base>, <meta>, <link>, <style>, and <form> are dropped;
        // the `style` attribute is stripped to defeat visual-deception
        // attacks against the copy button (display:none segments inside
        // <pre><code> would otherwise survive into clipboard textContent).
        // <button> stays allowed so the mermaid zoom HUD survives sanitize();
        // without a parent <form> (forbidden above), `formaction` has nothing
        // to submit to, and on* handlers are stripped by DOMPurify defaults.
        //
        // ALLOWED_URI_REGEXP extends DOMPurify's default safe-URL list with
        // `md-asset:` so markdown image references that resolve to the
        // document's base directory (![alt](relative/path.png)) keep working.
        const SANITIZE_CONFIG = {
            FORBID_TAGS: ['style', 'form', 'iframe', 'object',
                          'embed', 'meta', 'link', 'base'],
            FORBID_ATTR: ['style'],
            ADD_ATTR: ['target'],
            ALLOWED_URI_REGEXP: /^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix|md-asset):|[^a-z]|[a-z+.\\-]+(?:[^a-z+.\\-:]|$))/i
        };
        function sanitize(html) {
            if (typeof html !== 'string') return '';
            if (typeof DOMPurify === 'undefined' || !DOMPurify.sanitize) {
                // Fail closed: refuse to render rather than risk shipping
                // unsanitized HTML into innerHTML. This branch fires only if
                // the bundled purify.min.js is missing from the app bundle.
                if (window.console && console.error) {
                    console.error('[md-preview] DOMPurify not loaded; refusing to render article.');
                }
                return '';
            }
            return DOMPurify.sanitize(html, SANITIZE_CONFIG);
        }

        // Incremental-update entry point. Each renderer (KaTeX/Mermaid)
        // registers an idempotent reapplier that re-processes the current
        // article. Same-flag re-renders skip the WKWebView reload entirely.
        const reappliers = [];
        window.MdPreview = window.MdPreview || {};
        window.MdPreview.performTableContextAction = (token, operation) => {
            if (!pendingTableContextAction || pendingTableContextAction.token !== token) return false;
            const pending = pendingTableContextAction;
            pendingTableContextAction = null;
            if (operation === 'selectRow' || operation === 'selectColumn') {
                selectTablePart(pending.cell, operation);
            } else {
                performTableStructure(pending.cell, operation);
            }
            return true;
        };
        window.MdPreview.registerReapplier = (fn) => {
            if (typeof fn === 'function') reappliers.push(fn);
        };
        function mdHash(s) {
            let h = 5381;
            for (let i = 0; i < s.length; i++) h = ((h << 5) + h + s.charCodeAt(i)) >>> 0;
            return h.toString(36);
        }

        // One row per expensive block kind: the wrapper class, a key prefix,
        // where the node carrying __mdSrc and the renderer's done flag lives
        // inside the wrapper (null = the wrapper itself), and where the
        // source-position attrs live when not on the wrapper. The keying,
        // preservation, and attr-sync helpers below all derive from this
        // table, so a new renderer means one new row — not three new branches.
        const EXPENSIVE_BLOCKS = [
            { cls: 'mermaid-figure', kind: 'mm',   inner: '.mermaid',   done: 'mmDone',   attrInner: null  },
            { cls: 'md-code-wrap',   kind: 'code', inner: 'pre > code', done: 'hljsDone', attrInner: 'pre' },
            { cls: 'math',           kind: 'math', inner: null,         done: 'mathDone', attrInner: null  }
        ];
        const EXPENSIVE_SELECTOR = EXPENSIVE_BLOCKS.map((b) => '.' + b.cls).join(', ');
        function expensiveKindOf(el) {
            if (!el.classList) return null;
            return EXPENSIVE_BLOCKS.find((b) => el.classList.contains(b.cls)) || null;
        }
        function expensiveSrcNode(el, info) {
            return info.inner ? el.querySelector(info.inner) : el;
        }

        // Content-derived keys so morphdom re-pairs unchanged diagrams/math/
        // code even when blocks are inserted above them. Live nodes hash the
        // stashed __mdSrc (renderers replace textContent with their output);
        // incoming nodes hash textContent — the same Swift emitter produced
        // both strings, so identical source yields identical keys.
        function keyExpensiveBlocks(root) {
            const counts = new Map();
            root.querySelectorAll(EXPENSIVE_SELECTOR).forEach((el) => {
                const info = expensiveKindOf(el);
                const srcNode = expensiveSrcNode(el, info);
                if (!srcNode) return;
                const src = srcNode.__mdSrc !== undefined ? srcNode.__mdSrc : srcNode.textContent;
                // Hash memoized per node — live-tree sources are stable
                // across updates, so only fresh incoming nodes pay the hash.
                // Kind-prefixed so a hash collision can never pair blocks of
                // different types (block math and code wraps are both <div>s).
                let base = srcNode.__mdKeyBase;
                if (base === undefined || srcNode.__mdKeySrc !== src) {
                    base = info.kind + '-' + mdHash(src);
                    srcNode.__mdKeyBase = base;
                    srcNode.__mdKeySrc = src;
                }
                const n = (counts.get(base) || 0) + 1;
                counts.set(base, n);
                el.setAttribute('data-md-key', 'k' + base + ':' + n);
            });
        }

        // A preserved subtree keeps its pre-shift source metadata, which
        // would desync scroll handoff and table edits after lines move.
        // Copy the incoming line attributes onto the live node.
        function syncSourceAttrs(fromEl, toEl, info) {
            let from = fromEl;
            let to = toEl;
            if (info.attrInner) {
                from = fromEl.querySelector(info.attrInner);
                to = toEl.querySelector(info.attrInner);
                if (!from || !to) return;
            }
            for (const name of ['data-source-line', 'data-source-start', 'data-source-end']) {
                const value = to.getAttribute(name);
                if (value === null) from.removeAttribute(name);
                else from.setAttribute(name, value);
            }
        }

        // True when the live subtree holds finished renderer output for the
        // exact source the incoming node carries — morphdom must then leave
        // it untouched. Anything else (still rendering, changed source)
        // morphs normally and the reappliers re-render it.
        function isRenderedForSource(info, fromEl, toEl) {
            const live = expensiveSrcNode(fromEl, info);
            const incoming = expensiveSrcNode(toEl, info);
            return !!live && !!incoming && live.dataset[info.done] === '1'
                && live.__mdSrc === incoming.textContent;
        }

        // Both are stateless, so they're built once instead of per update —
        // MdPreview.update is the per-keystroke-exit/file-change hot path.
        const SANITIZE_DOM_CONFIG = Object.assign({}, SANITIZE_CONFIG, { RETURN_DOM_FRAGMENT: true });
        const MORPH_OPTIONS = {
            childrenOnly: true,
            getNodeKey: (node) => node.nodeType === 1
                ? (node.getAttribute('data-md-key') || node.id || undefined)
                : undefined,
            onBeforeElUpdated: (fromEl, toEl) => {
                if (fromEl.isEqualNode(toEl)) return false;
                // Skipping is all-or-nothing per subtree: letting morphdom
                // descend would strip the done markers (incoming nodes lack
                // them) and force a destructive re-render on the next reapply.
                const info = expensiveKindOf(fromEl);
                if (info && isRenderedForSource(info, fromEl, toEl)) {
                    syncSourceAttrs(fromEl, toEl, info);
                    return false;
                }
                if (fromEl.tagName === 'DETAILS') toEl.toggleAttribute('open', fromEl.open);
                return true;
            }
        };

        // `opts.keepHidden` preserves the warmup opacity so the synthetic
        // Mermaid pre-render doesn't flash on screen. The host then issues a
        // second update without the flag once the real document arrives,
        // which clears the inline style and reveals the article.
        window.MdPreview.update = (articleHTML, opts) => {
            // Body swaps can carry a document from a different folder — move
            // the page <base> first so the incoming content's relative URLs
            // resolve against the right folder.
            if (opts && opts.baseHref) {
                const base = document.querySelector('base');
                if (base && base.getAttribute('href') !== opts.baseHref) {
                    base.setAttribute('href', opts.baseHref);
                }
            }
            const article = document.querySelector('.markdown-body');
            if (!article) return;
            const tStart = perfNow();
            finishTableCellEdit(false);
            clearTablePartSelection();
            // DOM-diff fast path: morph the live article toward the incoming
            // HTML so finished Mermaid SVGs, KaTeX output, and highlighted
            // code survive the update instead of being re-rendered. Skipped
            // for the first populate (empty article), the warmup article,
            // and whenever morphdom or DOMPurify is missing; any throw
            // falls back to the innerHTML swap below.
            const canMorph = !!articleHTML && article.firstElementChild
                && article.dataset.warmup !== '1'
                && typeof morphdom === 'function'
                && typeof DOMPurify !== 'undefined' && DOMPurify.sanitize;
            let morphed = false;
            if (canMorph) {
                try {
                    const frag = DOMPurify.sanitize(articleHTML, SANITIZE_DOM_CONFIG);
                    const next = document.createElement('article');
                    next.appendChild(frag);
                    // Pre-shape the incoming tree so the decorators' wrappers
                    // pair one-to-one with the live DOM during the diff.
                    decorateCodeBlocks(next);
                    enableTableEditing(next);
                    keyExpensiveBlocks(article);
                    keyExpensiveBlocks(next);
                    morphdom(article, next, MORPH_OPTIONS);
                    morphed = true;
                } catch (e) {
                    perfLog('morphdom fallback', String(e && e.message || e));
                }
            }
            if (!morphed) {
                article.innerHTML = sanitize(articleHTML);
            }
            if (!opts || !opts.keepHidden) {
                article.style.opacity = '';
                article.style.pointerEvents = '';
                // Revealing means the synthetic warmup content is gone — the
                // hidden populate keeps the flag so the first real document
                // still takes the guaranteed innerHTML replace above, and
                // every update after it may morph.
                delete article.dataset.warmup;
            }
            if (articleHTML) {
                // The morph path already decorated the incoming tree; only
                // the innerHTML swap leaves fresh undecorated nodes behind.
                if (!morphed) {
                    decorateCodeBlocks();
                    enableTableEditing();
                }
                enableTaskCheckboxes();
                for (const fn of reappliers) {
                    try { fn(); } catch (e) { /* one bad apple shouldn't block others */ }
                }
            }
            perfLog('MdPreview.update' + (morphed ? ' (morphdom)' : ''), '(+' + (perfNow() - tStart).toFixed(1) + 'ms)');
            pushHeight();
        };

        // Initial-load populator. The article body ships inside an inert
        // <template> element so the parser never fires inline event handlers
        // on first paint. Pull it out, sanitize, inject. The template is
        // removed once consumed.
        function populateFromTemplate() {
            const tmpl = document.getElementById('md-article-source');
            if (!tmpl) return;
            const article = document.querySelector('.markdown-body');
            const keepHidden = !!(article && article.dataset.warmup === '1');
            window.MdPreview.update(tmpl.innerHTML, { keepHidden });
            tmpl.remove();
        }
        // Body-end hook: inline-mode documents call this right after the
        // template parses, before the vendor bundles, so text paints early.
        window.MdPreview.populateNow = populateFromTemplate;

        function start() {
            perfLog('start (DOM ready)');
            populateFromTemplate();
            decorateCodeBlocks();
            pushHeight();
            try {
                const ro = new ResizeObserver(pushHeight);
                ro.observe(document.body);
                const article = document.querySelector('.markdown-body');
                if (article) ro.observe(article);
            } catch (e) {}
            window.addEventListener('md-preview-mermaid-rendered', pushHeight);
            window.addEventListener('md-preview-math-rendered', pushHeight);
            window.addEventListener('load', pushHeight);
        }

        if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', start, { once: true });
        } else {
            start();
        }
    })();
    </script>
    """
}
