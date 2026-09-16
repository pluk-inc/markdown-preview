import AppKit
import WebKit
import XCTest

/// Measures rendered content, not CSS declarations. Both surfaces use the same
/// WebKit engine, viewport, and local assets; positions are relative to the
/// content column so native toolbar/gutter offsets do not affect comparison.
@MainActor
final class WebViewLayoutHarness {
    struct Rect: Codable, Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct Element: Codable, Equatable {
        let name: String
        let rect: Rect
        let lines: [Rect]
        let editorHeadersAbove: Int
    }

    struct Layout: Codable, Equatable {
        let columnX: Double
        let columnY: Double
        let columnWidth: Double
        let elements: [Element]
    }

    let webView: WKWebView
    private let html: String
    private let isEditor: Bool

    init(html: String, width: CGFloat, isEditor: Bool, zoom: CGFloat = 1, height: CGFloat = 1800) {
        self.html = html
        self.isEditor = isEditor
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        // A command-line test has no visible window. WebKit pauses native
        // animation frames there, even while async JavaScript is running.
        // Drive the frame clock explicitly; DOM layout, fonts, images, and
        // CodeMirror's measurement callbacks still run in real WebKit.
        configuration.userContentController.addUserScript(WKUserScript(source: """
            (() => {
                let nextID = 0;
                const callbacks = new Map();
                window.requestAnimationFrame = callback => {
                    const id = ++nextID;
                    callbacks.set(id, callback);
                    return id;
                };
                window.cancelAnimationFrame = id => callbacks.delete(id);
                window.__layoutTestFrame = () => {
                    const frame = [...callbacks.entries()];
                    for (const [id, callback] of frame) {
                        if (!callbacks.delete(id)) continue;
                        callback(performance.now());
                    }
                    return callbacks.size;
                };
            })();
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height),
                            configuration: configuration)
        webView.pageZoom = zoom
        webView.loadHTMLString(html, baseURL: nil)
    }

    func close() {
        webView.stopLoading()
    }

    func layout(texts: [String], imageCount: Int,
                selectors: [String: Int] = [:], boxes: [String: String] = [:],
                styles: [String: [String: String]] = [:], sourceSnippets: [String] = []) async throws -> Layout {
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !webView.isLoading else { throw Failure("Page navigation timed out") }

        let result = try await webView.callAsyncJavaScript("""
            const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
            const deadline = Date.now() + 7000;
            const rootSelector = isEditor ? '.cm-content' : 'article.markdown-body';
            const imageSelector = isEditor ? '.cm-md-image-preview img' : 'article img';
            const ready = async () => {
                while (!document.querySelector(rootSelector) ||
                       (isEditor && (!window.__mdEditor || !window.__mdEditor.isSyntaxReady()))) {
                    window.__layoutTestFrame();
                    if (Date.now() > deadline) throw new Error('Renderer did not become ready');
                    await delay(20);
                }
                while (Object.entries(selectors).some(([selector, count]) =>
                    document.querySelectorAll(rootSelector + ' ' + selector).length !== count)) {
                    window.__layoutTestFrame();
                    if (Date.now() > deadline) throw new Error('Rendered feature counts: ' + JSON.stringify(
                        Object.entries(selectors).map(([selector, count]) => ({ selector, expected: count,
                            actual: document.querySelectorAll(rootSelector + ' ' + selector).length }))));
                    await delay(20);
                }
                const content = document.querySelector(rootSelector).textContent;
                for (const source of sourceSnippets) {
                    if (!content.includes(source)) throw new Error('Missing visible source fallback: ' + source);
                }
                await document.fonts.ready;
                while (document.querySelectorAll(imageSelector).length !== imageCount) {
                    window.__layoutTestFrame();
                    if (Date.now() > deadline) throw new Error(`Expected ${imageCount} images, found ${document.querySelectorAll(imageSelector).length}`);
                    await delay(20);
                }
                await Promise.all([...document.querySelectorAll(imageSelector)].map(image => image.decode()));
            };
            await Promise.race([
                ready(),
                delay(8000).then(() => { throw new Error('Fonts or images did not become ready'); })
            ]);

            function measure() {
                const root = document.querySelector(rootSelector);
                const style = getComputedStyle(root);
                const bounds = root.getBoundingClientRect();
                const originX = bounds.left + parseFloat(style.paddingLeft);
                const originY = bounds.top + parseFloat(style.paddingTop);
                const rect = box => ({
                    x: box.left - originX, y: box.top - originY,
                    width: box.width, height: box.height
                });
                const headers = isEditor ? [...root.querySelectorAll('.cm-md-codeblock-first:has(.cm-md-code-language)')]
                    .map(header => header.getBoundingClientRect().top - originY) : [];
                const headerCount = y => headers.filter(top => top < y).length;
                // Build one visible text stream so probes can span emphasis,
                // links, syntax-highlighting spans, and soft-joined lines.
                const characters = [];
                const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                let node;
                while ((node = walker.nextNode())) {
                    if (node.parentElement.closest('script, style, .cm-md-image-source')) continue;
                    const style = getComputedStyle(node.parentElement);
                    if (style.visibility === 'hidden' || style.display === 'none') continue;
                    let offset = 0;
                    for (const character of node.textContent) {
                        characters.push({ character, node, offset });
                        offset += character.length;
                    }
                }
                // Indices remain UTF-16, matching DOM Range and String.indexOf.
                const stream = characters.map(item => item.character).join('');
                const offsets = [];
                let streamOffset = 0;
                for (const item of characters) {
                    offsets.push(streamOffset);
                    streamOffset += item.character.length;
                }
                const elements = texts.map(text => {
                    const offset = stream.indexOf(text);
                    if (offset < 0) throw new Error(`Missing rendered text: ${text}`);
                    const firstCharacter = characters[offsets.indexOf(offset)];
                    const computed = getComputedStyle(firstCharacter.node.parentElement);
                    for (const [property, expected] of Object.entries(styles[text] || {})) {
                        const actual = computed.getPropertyValue(property);
                        if (actual !== expected) throw new Error(`${text}: ${property} expected ${expected}, found ${actual}`);
                    }
                    const range = document.createRange();
                    const lineBoxes = [];
                    for (let index = 0; index < characters.length; index++) {
                        if (offsets[index] < offset || offsets[index] >= offset + text.length) continue;
                        const item = characters[index];
                        if (/\\s/u.test(item.character)) continue;
                        range.setStart(item.node, item.offset);
                        range.setEnd(item.node, item.offset + item.character.length);
                        // Ignore trailing spaces and the zero-width caret
                        // rectangle WebKit adds at some wrapped boundaries.
                        for (const clientRect of range.getClientRects()) {
                            if (clientRect.width === 0 || clientRect.height === 0) continue;
                            const box = rect(clientRect);
                            let line = lineBoxes.find(line => Math.abs(line.y - box.y) < 0.5);
                            if (!line) lineBoxes.push({ ...box });
                            else {
                                const right = Math.max(line.x + line.width, box.x + box.width);
                                line.x = Math.min(line.x, box.x);
                                line.width = right - line.x;
                                line.height = Math.max(line.height, box.height);
                            }
                        }
                    }
                    if (!lineBoxes.length) throw new Error(`Text is not visibly laid out: ${text}`);
                    const left = Math.min(...lineBoxes.map(box => box.x));
                    const top = Math.min(...lineBoxes.map(box => box.y));
                    const right = Math.max(...lineBoxes.map(box => box.x + box.width));
                    const bottom = Math.max(...lineBoxes.map(box => box.y + box.height));
                    return { name: text, rect: { x: left, y: top, width: right - left, height: bottom - top },
                             lines: lineBoxes, editorHeadersAbove: headerCount(top) };
                });
                document.querySelectorAll(imageSelector).forEach((image, index) => {
                    const box = rect(image.getBoundingClientRect());
                    elements.push({name: `image-${index}`, rect: box, lines: [], editorHeadersAbove: headerCount(box.y)});
                });
                for (const [name, selector] of Object.entries(boxes).sort()) {
                    const matches = root.querySelectorAll(selector);
                    if (matches.length !== 1) throw new Error(`${name}: expected one ${selector}, found ${matches.length}`);
                    const box = rect(matches[0].getBoundingClientRect());
                    if (box.width <= 0 || box.height <= 0) throw new Error(`${name} is not visibly laid out`);
                    elements.push({ name, rect: box, lines: [], editorHeadersAbove: headerCount(box.y) });
                }
                return {
                    columnX: originX, columnY: originY,
                    columnWidth: bounds.width - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight),
                    elements
                };
            }

            // CodeMirror measures after DOM updates. Require several equal
            // samples after fonts/images are ready, including time for its
            // deferred measurement pass. A navigation finish alone is too early.
            let previous = '';
            let stable = 0;
            const earliest = Date.now() + 300;
            while (Date.now() < deadline) {
                window.__layoutTestFrame();
                await delay(50);
                const pendingFrames = window.__layoutTestFrame();
                const current = JSON.stringify(measure());
                stable = current === previous ? stable + 1 : 0;
                if (stable >= 3 && pendingFrames === 0 && Date.now() >= earliest) return current;
                previous = current;
            }
            throw new Error('Rendered geometry did not settle');
            """, arguments: ["texts": texts, "imageCount": imageCount, "isEditor": isEditor,
                                 "selectors": selectors, "boxes": boxes, "styles": styles, "sourceSnippets": sourceSnippets],
            in: nil, contentWorld: .page)
        let json = try XCTUnwrap(result as? String)
        return try JSONDecoder().decode(Layout.self, from: Data(json.utf8))
    }

    func saveDiagnostics(name: String, layout: Layout?) async -> URL {
        let base = ProcessInfo.processInfo.environment["MDP_LAYOUT_ARTIFACTS"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("md-preview-layout-failures")
        let directory = base.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let surface = isEditor ? "editor" : "read"
        try? Data(html.utf8).write(to: directory.appendingPathComponent("\(surface).html"))
        if let dom = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String {
            try? Data(dom.utf8).write(to: directory.appendingPathComponent("\(surface)-dom.html"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let layout, let data = try? encoder.encode(layout) {
            try? data.write(to: directory.appendingPathComponent("\(surface).json"))
        }
        if let snapshot = try? await webView.takeSnapshot(configuration: nil),
           let tiff = snapshot.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: directory.appendingPathComponent("\(surface).png"))
        }
        return directory
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
