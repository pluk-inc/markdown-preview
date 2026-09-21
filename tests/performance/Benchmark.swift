import AppKit
import CryptoKit
import Darwin
import Foundation
import WebKit

private struct Metric: Encodable {
    let name: String
    let unit: String
    let samples: [Double]
    let inputSHA256: String
}

private struct Report: Encodable {
    let schema = 1
    let revision: String
    let os: String
    let architecture: String
    let metrics: [Metric]
}

private struct BenchmarkError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
private struct PerformanceProbe {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run()
                application.terminate(nil)
            } catch {
                FileHandle.standardError.write(Data("Performance probe failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        // AppKit must process window/activation events for WebKit to regard
        // the page as foreground. An async command-line main alone does not.
        application.run()
    }

    @MainActor
    static func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["MDP_BENCH_OUTPUT"],
              let root = environment["MDP_BENCH_ROOT"],
              let fixturePath = environment["MDP_BENCH_FIXTURE"] else {
            throw BenchmarkError("Missing benchmark output, checkout, or fixture path")
        }
        let samples = Int(environment["MDP_BENCH_SAMPLES"] ?? "7") ?? 7
        guard samples >= 3 else { throw BenchmarkError("At least three samples are required") }
        let vendors = URL(fileURLWithPath: root).appendingPathComponent("md-preview/Vendor")
        func script(_ path: String) throws -> String {
            try String(contentsOf: vendors.appendingPathComponent(path), encoding: .utf8)
                .replacingOccurrences(of: "</script", with: "<\\/script")
        }
        guard MarkdownHTML.bundledVendorResource("purify.min", ext: "js", subdir: "Vendor/DOMPurify") != nil else {
            throw BenchmarkError("Production DOMPurify resource is missing from the probe")
        }
        CodeHighlighter.useGrammar(source: try script("Highlight/highlight.min.js"))
        let mixed = try String(contentsOfFile: fixturePath, encoding: .utf8) + "\n"
        let prose = """
        ## A representative section

        Markdown Preview renders ordinary prose with **emphasis**, *italics*, and `inline code`.
        Another source line supplies text that wraps at a normal window width.

        - A first list item
        - A second list item

        """
        let code = """
        ## Code example

        ```swift
        struct Record {
            let identifier: Int
            let title: String
        }
        let records = (0..<100).map { Record(identifier: $0, title: "Item") }
        ```

        A paragraph after the code block.

        """
        let links = "A bare URL https://example.com/path?one=1&two=2 and [a link](https://example.org).\n\n"
        func repeated(_ block: String, bytes: Int) -> String {
            String(repeating: block, count: max(1, bytes / block.utf8.count))
        }
        let documents = [
            ("prose-100k", repeated(prose, bytes: 100_000)),
            ("prose-1m", repeated(prose, bytes: 1_000_000)),
            ("code-100k", repeated(code, bytes: 100_000)),
            ("links-100k", repeated(links, bytes: 100_000)),
            ("mixed-100k", repeated(mixed, bytes: 100_000)),
        ]
        var metrics: [Metric] = []
        func append(_ name: String, _ values: [Double], source: String, unit: String = "ms") {
            metrics.append(Metric(name: name, unit: unit, samples: values,
                                  inputSHA256: SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()))
        }
        for (name, markdown) in documents {
            var wall: [Double] = []
            var cpu: [Double] = []
            for index in -2..<samples {
                try autoreleasepool {
                    let cpuStart = cpuMilliseconds()
                    let start = ContinuousClock.now
                    let rendered = MarkdownHTML.render(markdown: markdown, vendorLoading: .lazy,
                                                       documentFont: .system, readerLayout: ReaderLayoutSetting())
                    let elapsed = milliseconds(since: start)
                    let consumedCPU = cpuMilliseconds() - cpuStart
                    guard !rendered.articleHTML.isEmpty, rendered.html.contains("markdown-body") else {
                        throw BenchmarkError("Renderer produced no document for \(name)")
                    }
                    if index >= 0 { wall.append(elapsed); cpu.append(consumedCPU) }
                }
            }
            append("render-\(name)-wall", wall, source: markdown)
            append("render-\(name)-cpu", cpu, source: markdown)
        }
        // This is the Swift probe process, sampled before creating any WKWebView.
        // WebContent lives in another process; do not label this total app memory.
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        append("renderer-peak-rss", [Double(usage.ru_maxrss) / 1_048_576],
               source: documents.map(\.1).joined(), unit: "MiB")

        let editorScript = try script("CodeMirror/mdedit.min.js")
        let mermaidScript = try script("Mermaid/mermaid.min.js")
        let large = documents[4].1
        let media = """
        # Rendered media

        A paragraph with **emphasis**, inline math $x^2 + y^2$, and a link.

        ![Local fixture](data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIyNDAiIGhlaWdodD0iODAiPjxyZWN0IHdpZHRoPSIyNDAiIGhlaWdodD0iODAiIGZpbGw9InJveWFsYmx1ZSIvPjwvc3ZnPg==)

        ```mermaid
        flowchart LR
            A[Draft] --> B[Review] --> C[Publish]
        ```

        ```swift
        let answer = 42
        ```

        After all rendered media.
        """
        for (name, markdown, mediaCase) in [("mixed-100k", large, false), ("media", media, true)] {
            for isEditor in [false, true] {
                let surface = isEditor ? "editor" : "read"
                let html = isEditor
                    ? EditorHTML.render(markdown: markdown, editorJavaScript: editorScript,
                                        mermaidJavaScript: mediaCase ? mermaidScript : nil)
                    : MarkdownHTML.render(markdown: markdown, vendorLoading: .inline,
                                          documentFont: .system, readerLayout: ReaderLayoutSetting()).html
                var opens: [Double] = []
                let openingPage = BenchmarkPage()
                for index in -2..<samples {
                    let start = ContinuousClock.now
                    try await openingPage.load(html, isEditor: isEditor, media: mediaCase)
                    if index >= 0 { opens.append(milliseconds(since: start)) }
                }
                openingPage.close()
                append("\(surface)-open-\(name)", opens, source: markdown)
                guard !mediaCase else { continue }
                let page = BenchmarkPage()
                defer { page.close() }
                try await page.load(html, isEditor: isEditor, media: false)
                if isEditor {
                    let values = try await page.editorEdits(markdown: markdown, samples: samples)
                    append("editor-edit-cycle-\(name)", values, source: markdown)
                    let replacements = try await page.editorReplacements(markdown: markdown, samples: samples)
                    append("editor-replace-\(name)", replacements, source: markdown)
                } else {
                    let changed = MarkdownHTML.render(markdown: markdown + "\n\nChanged final paragraph.",
                                                      vendorLoading: .lazy).articleHTML
                    let original = MarkdownHTML.render(markdown: markdown, vendorLoading: .lazy).articleHTML
                    let values = try await page.readerUpdates(original: original, changed: changed, samples: samples)
                    append("read-update-\(name)", values, source: markdown)
                }
            }
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let report = Report(revision: environment["MDP_BENCH_REVISION"] ?? "unknown",
                            os: ProcessInfo.processInfo.operatingSystemVersionString,
                            architecture: architecture, metrics: metrics)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("Wrote \(metrics.count) performance metrics to \(output)")
    }

    private static func cpuMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }
}

@MainActor
private final class BenchmarkPage {
    // Headless/occluded WKWebViews can add one-second background scheduling
    // delays. Use one real foreground window for both revisions and all samples.
    private static let window: NSWindow = {
        let window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Markdown Preview performance probe"
        window.isReleasedWhenClosed = false
        return window
    }()

    let webView: WKWebView

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        // Measure actual callbacks and WebKit layout work explicitly. Native
        // frame pacing and display paint are outside these work metrics.
        configuration.userContentController.addUserScript(WKUserScript(source: """
        (() => {
            let next = 0;
            const callbacks = new Map();
            window.requestAnimationFrame = callback => { callbacks.set(++next, callback); return next; };
            window.cancelAnimationFrame = id => callbacks.delete(id);
            window.__benchFrame = () => {
                const frame = [...callbacks.entries()];
                for (const [id, callback] of frame) {
                    if (callbacks.delete(id)) callback(performance.now());
                }
                document.body?.getBoundingClientRect();
                return callbacks.size;
            };
            window.__benchWork = async action => {
                let active = 0;
                let start = performance.now();
                action();
                active += performance.now() - start;
                let quiet = 0;
                for (let count = 0; count < 50; count++) {
                    // Timer delay isn't editor CPU/layout work. Time the actual
                    // transaction, callbacks, and forced layout separately.
                    await new Promise(resolve => setTimeout(resolve, 0));
                    start = performance.now();
                    const pending = window.__benchFrame();
                    active += performance.now() - start;
                    quiet = pending ? 0 : quiet + 1;
                    if (quiet >= 3) return active;
                }
                throw new Error('Editor measurement frames never settled');
            };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600), configuration: configuration)
        Self.window.contentView = webView
        Self.window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }

    func close() {
        webView.stopLoading()
        if Self.window.contentView === webView { Self.window.contentView = nil }
    }

    func load(_ html: String, isEditor: Bool, media: Bool) async throws {
        let started = Date()
        webView.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while webView.isLoading && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard !webView.isLoading else { throw BenchmarkError("WebKit navigation timed out") }
        let navigationMilliseconds = Date().timeIntervalSince(started) * 1000
        let arguments: [String: Any] = ["isEditor": isEditor, "media": media]
        _ = try await webView.callAsyncJavaScript("""
            window.__benchFontsReady = false;
            window.__benchImageDecodes = new WeakMap();
            window.__benchAssetError = null;
            document.fonts.ready
                .then(() => { window.__benchFontsReady = true; })
                .catch(error => { window.__benchAssetError = String(error); });
            """, arguments: arguments, in: nil, contentWorld: .page)
        // Hidden WebKit timers can clamp a 5 ms test poll to a full second.
        // Poll from Swift so page-open measurements include real readiness work
        // without that variable, test-only delay. Production timers stay intact.
        var quiet = 0
        while Date() < deadline {
            let settled = try await webView.callAsyncJavaScript("""
                if (window.__benchAssetError) throw new Error(window.__benchAssetError);
                const pending = window.__benchFrame();
                const root = document.querySelector(isEditor ? '.cm-content' : 'article.markdown-body');
                if (!root || !root.textContent.trim()) return false;
                // Editor image widgets can appear after navigation and initial layout.
                // Discover them on every poll, and decode replacements as well.
                const images = [...root.querySelectorAll(isEditor ? '.cm-md-image-preview img' : 'img')];
                window.__benchImageCount = images.length;
                for (const image of images) {
                    if (window.__benchImageDecodes.has(image)) continue;
                    window.__benchImageDecodes.set(image, false);
                    image.decode()
                        .then(() => { window.__benchImageDecodes.set(image, true); })
                        .catch(error => { window.__benchAssetError = String(error); });
                }
                const imagesReady = (!media || images.length === 1)
                    && images.every(image => window.__benchImageDecodes.get(image));
                const diagramReady = !media || root.querySelector(isEditor ? '.cm-md-mermaid-stage svg' : '.mermaid svg');
                const mathReady = !media || isEditor || root.querySelector('.katex');
                return Boolean(document.visibilityState === 'visible' && window.__benchFontsReady && imagesReady && !pending && diagramReady && mathReady);
                """, arguments: arguments, in: nil, contentWorld: .page)
            quiet = (settled as? Bool) == true ? quiet + 1 : 0
            if quiet >= 3 {
                let totalMilliseconds = Date().timeIntervalSince(started) * 1000
                print("page=\(isEditor ? "editor" : "read") media=\(media) navigation_ms=\(Int(navigationMilliseconds)) readiness_ms=\(Int(totalMilliseconds - navigationMilliseconds))")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        let visibility = try? await webView.evaluateJavaScript("document.visibilityState")
        let imageCount = try? await webView.evaluateJavaScript("window.__benchImageCount")
        throw BenchmarkError("WebKit renderers did not settle (media: \(media), images: \(String(describing: imageCount)), page visibility: \(String(describing: visibility))). Keep the benchmark window visible and unobstructed.")
    }

    func editorEdits(markdown: String, samples: Int) async throws -> [Double] {
        try await measurements("""
            const values = [];
            const position = source.indexOf('paragraph');
            if (position < 0) throw new Error('Typing target missing');
            for (let index = -2; index < samples; index++) {
                const elapsed = await window.__benchWork(() => window.__mdEditor.insertTextAt('x', position, position));
                if (window.__mdEditor.getMarkdown() !== source.slice(0, position) + 'x' + source.slice(position)) {
                    throw new Error('Edit did not apply');
                }
                const removal = await window.__benchWork(() => window.__mdEditor.insertTextAt('', position, position + 1));
                if (window.__mdEditor.getMarkdown() !== source) throw new Error('Edit changed original source');
                if (index >= 0) values.push(elapsed + removal);
            }
            return values;
            """, arguments: ["source": markdown, "samples": samples])
    }

    func editorReplacements(markdown: String, samples: Int) async throws -> [Double] {
        try await measurements("""
            const values = [];
            for (let index = -2; index < samples; index++) {
                const target = source + (index % 2 === 0 ? '\\n\\nUpdated document.' : '');
                const elapsed = await window.__benchWork(() => window.__mdEditor.replaceMarkdown(target));
                if (window.__mdEditor.getMarkdown() !== target) throw new Error('Replacement lost source');
                if (index >= 0) values.push(elapsed);
            }
            return values;
            """, arguments: ["source": markdown, "samples": samples])
    }

    func readerUpdates(original: String, changed: String, samples: Int) async throws -> [Double] {
        try await measurements("""
            const values = [];
            for (let index = -2; index < samples; index++) {
                const updating = index % 2 === 0;
                const elapsed = await window.__benchWork(() => window.MdPreview.update(updating ? changed : original));
                const present = document.querySelector('article').textContent.includes('Changed final paragraph.');
                if (present !== updating) throw new Error('Read update did not apply');
                if (index >= 0) values.push(elapsed);
            }
            return values;
            """, arguments: ["original": original, "changed": changed, "samples": samples])
    }

    private func measurements(_ script: String, arguments: [String: Any]) async throws -> [Double] {
        let result = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        guard let values = result as? [Double], !values.isEmpty else { throw BenchmarkError("Missing WebKit measurements") }
        return values
    }
}
