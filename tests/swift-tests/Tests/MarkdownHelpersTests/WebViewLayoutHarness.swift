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

    init(html: String, width: CGFloat, isEditor: Bool, zoom: CGFloat = 1) {
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
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1800),
                            configuration: configuration)
        webView.pageZoom = zoom
        webView.loadHTMLString(html, baseURL: nil)
    }

    func close() {
        webView.stopLoading()
    }

    func layout(texts: [String], imageCount: Int) async throws -> Layout {
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard !webView.isLoading else { throw Failure("Page navigation timed out") }

        let result = try await webView.callAsyncJavaScript("""
            const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
            const deadline = Date.now() + 8000;
            const rootSelector = isEditor ? '.cm-content' : 'article.markdown-body';
            const imageSelector = isEditor ? '.cm-md-image-preview img' : 'article img';
            const ready = async () => {
                while (!document.querySelector(rootSelector) ||
                       (isEditor && !window.__mdEditor)) {
                    if (Date.now() > deadline) throw new Error('Renderer did not become ready');
                    await delay(20);
                }
                await document.fonts.ready;
                const images = [...document.querySelectorAll(imageSelector)];
                if (images.length !== imageCount) {
                    throw new Error(`Expected ${imageCount} images, found ${images.length}`);
                }
                await Promise.all(images.map(image => image.decode()));
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
                const elements = texts.map(text => {
                    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
                    let node;
                    while ((node = walker.nextNode())) {
                        if (node.parentElement.closest('.cm-md-image-source')) continue;
                        const offset = node.textContent.indexOf(text);
                        if (offset < 0) continue;
                        const range = document.createRange();
                        range.setStart(node, offset);
                        range.setEnd(node, offset + text.length);
                        // pre-wrap retains trailing spaces at line breaks;
                        // normal white-space trims them. Compare the visible
                        // character bounds rather than that invisible advance.
                        const lineBoxes = [];
                        let position = offset;
                        for (const character of text) {
                            range.setStart(node, position);
                            position += character.length;
                            range.setEnd(node, position);
                            if (/\\s/u.test(character)) continue;
                            // At a wrapped boundary WebKit can also return
                            // a zero-width caret on the preceding line.
                            for (const clientRect of range.getClientRects()) {
                                if (clientRect.width === 0) continue;
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
                        const left = Math.min(...lineBoxes.map(box => box.x));
                        const top = Math.min(...lineBoxes.map(box => box.y));
                        const right = Math.max(...lineBoxes.map(box => box.x + box.width));
                        const bottom = Math.max(...lineBoxes.map(box => box.y + box.height));
                        return { name: text, rect: { x: left, y: top, width: right - left, height: bottom - top },
                                 lines: lineBoxes };
                    }
                    throw new Error(`Missing rendered text: ${text}`);
                });
                document.querySelectorAll(imageSelector).forEach((image, index) => {
                    elements.push({name: `image-${index}`, rect: rect(image.getBoundingClientRect()), lines: []});
                });
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
            """, arguments: ["texts": texts, "imageCount": imageCount, "isEditor": isEditor],
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
