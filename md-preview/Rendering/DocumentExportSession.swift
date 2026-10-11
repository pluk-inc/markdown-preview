import AppKit
import PDFKit
import WebKit

@MainActor
final class DocumentExportSession {
    enum Format { case pdf, png, paper, epub }

    private struct PaperLayout: Equatable {
        let width: CGFloat
        let pointSize: Int
        let scale: CGFloat

        init(info: NSPrintInfo, pointSize: Int) {
            let points = info.paperSize.width - 2 * MarkdownHTML.printPageMarginSidePoints
            scale = info.scalingFactor.isFinite && info.scalingFactor > 0 ? info.scalingFactor : 1
            width = points / scale * 96 / 72
            self.pointSize = pointSize
        }
    }

    private let html: String
    private let mermaidSources: [String]
    private let baseURL: URL?
    private let previewSize: NSSize
    private let previewZoom: CGFloat
    private let appearance: NSAppearance
    private let configuration: WKWebViewConfiguration
    private var pages: [Format: ExportPage] = [:]
    private var paperLayout: PaperLayout?
    private var paperPreparation: Task<WKWebView, Error>?
    private var pngPreparation: Task<Data, Error>?
    private var printCompletion: ExportPrintCompletion?
    private(set) var isClosed = false

    private init(html: String, mermaidSources: [String], source: WKWebView,
                 configuration: WKWebViewConfiguration) {
        self.html = html
        self.mermaidSources = mermaidSources
        baseURL = source.url
        previewSize = source.bounds.size
        previewZoom = source.pageZoom
        appearance = source.effectiveAppearance
        self.configuration = configuration
    }

    static func capture(
        from source: WKWebView,
        configuration: WKWebViewConfiguration = WKWebViewConfiguration()
    ) async throws -> DocumentExportSession {
        let result = try await source.callAsyncJavaScript("""
            await window.MdPreview?.mermaidRenderAll?.();
            await document.fonts.ready;
            const copy = document.documentElement.cloneNode(true);
            copy.querySelectorAll('script, .md-table-actions').forEach(node => node.remove());
            copy.querySelectorAll('.md-table-wrap').forEach(wrap => wrap.replaceWith(...wrap.childNodes));
            const checkboxes = document.querySelectorAll('input[type="checkbox"]');
            copy.querySelectorAll('input[type="checkbox"]').forEach((box, index) => {
                box.toggleAttribute('checked', checkboxes[index].checked);
            });
            return {
                html: '<!DOCTYPE html>' + copy.outerHTML,
                mermaidSources: Array.from(document.querySelectorAll('.mermaid'),
                    node => node.__mdSrc || node.textContent)
            };
            """, in: nil, contentWorld: .page)
        guard let snapshot = result as? [String: Any],
              let html = snapshot["html"] as? String,
              let sources = snapshot["mermaidSources"] as? [String] else {
            throw exportError("The document could not be prepared for export.")
        }
        configuration.preferences = source.configuration.preferences
        configuration.websiteDataStore = source.configuration.websiteDataStore
        return DocumentExportSession(html: html, mermaidSources: sources,
                                     source: source, configuration: configuration)
    }

    func webView(for format: Format) async throws -> WKWebView {
        if format == .paper {
            return try await preparePaper(using: NSPrintInfo.shared, pointSize: MarkdownHTML.defaultPrintPointSize)
        }
        return try await page(for: format).webView
    }

    /// WebKit's native scale tiles the unscaled layout horizontally above 100%.
    /// Paper preparation applies scale with CSS zoom instead, before pagination.
    static func printInfoForPreparedPaper(_ info: NSPrintInfo) -> NSPrintInfo {
        let copy = info.copy() as? NSPrintInfo ?? NSPrintInfo()
        copy.scalingFactor = 1
        return copy
    }

    func preparePaper(using info: NSPrintInfo, pointSize: Int) async throws -> WKWebView {
        guard !isClosed else { throw CancellationError() }
        let layout = PaperLayout(info: info, pointSize: pointSize)
        guard layout.width.isFinite, layout.width > 0 else {
            throw Self.exportError("The selected paper has no printable area.")
        }
        if paperLayout == layout, let paperPreparation {
            return try await paperPreparation.value
        }
        let previous = paperPreparation
        let preparation = Task {
            // Finish an in-flight layout before applying the next settings.
            _ = try? await previous?.value
            try Task.checkCancellation()
            let page = try await self.page(for: .paper)
            guard !self.isClosed else { throw CancellationError() }
            page.webView.setFrameSize(NSSize(width: layout.width * layout.scale, height: self.previewSize.height))
            _ = try await page.webView.callAsyncJavaScript("""
                document.body.style.zoom = '1';
                document.body.style.width = width + 'px';
                document.body.style.fontSize = pointSize + 'pt';
                await document.fonts.ready;
                \(ExportTableLayout.prepareScript)
                document.body.style.zoom = scale;
                """, arguments: ["width": layout.width, "pointSize": layout.pointSize, "scale": layout.scale],
                in: nil, contentWorld: .page)
            try Task.checkCancellation()
            guard !self.isClosed else { throw CancellationError() }
            return page.webView
        }
        paperLayout = layout
        paperPreparation = preparation
        do {
            return try await preparation.value
        } catch {
            if paperLayout == layout { paperLayout = nil }
            throw error
        }
    }

    private func page(for format: Format) async throws -> ExportPage {
        guard !isClosed else { throw CancellationError() }
        if let page = pages[format] { return page }
        let size = format == .png
            ? previewSize
            : NSSize(width: MarkdownHTML.preferredPageWidth, height: previewSize.height)
        let page = ExportPage(size: size, configuration: configuration)
        // Paper and reading apps supply their own light page.
        let leavesPreview = format == .paper || format == .epub
        page.webView.appearance = leavesPreview ? NSAppearance(named: .aqua) : appearance
        page.webView.pageZoom = format == .png ? previewZoom : 1
        page.webView.mediaType = format == .paper ? "print" : nil
        pages[format] = page
        do {
            try await page.load(html, baseURL: baseURL)
            let css = format == .pdf ? MarkdownHTML.previewPrintOverrideCSS : ""
            _ = try await page.webView.callAsyncJavaScript("""
                if (matchesPreview) document.documentElement.classList.add(printClass);
                const style = document.createElement('style');
                style.textContent = css;
                document.head.append(style);
                const images = Array.from(document.images);
                images.forEach(image => { image.loading = 'eager'; });
                await Promise.allSettled(images.map(image => image.decode()));
                await document.fonts.ready;
                """, arguments: ["matchesPreview": !leavesPreview,
                                 "printClass": MarkdownHTML.previewPrintClass, "css": css],
                in: nil, contentWorld: .page)
            if leavesPreview {
                if !mermaidSources.isEmpty {
                    _ = try await page.webView.evaluateJavaScript(MarkdownHTML.paperMermaidScript)
                    _ = try await page.webView.callAsyncJavaScript("""
                        document.querySelectorAll('.mermaid').forEach((node, index) => {
                            node.__mdSrc = sources[index];
                            node.style.transform = '';
                        });
                        await window.MdPreview.mermaidRenderAll('default');
                        """, arguments: ["sources": mermaidSources], in: nil, contentWorld: .page)
                }
            } else {
                _ = try await page.webView.callAsyncJavaScript(
                    ExportTableLayout.prepareScript, in: nil, contentWorld: .page)
            }
            guard !isClosed else { throw CancellationError() }
            return page
        } catch {
            pages.removeValue(forKey: format)?.close()
            throw error
        }
    }

    func runPrintOperation(_ operation: NSPrintOperation, from window: NSWindow) async -> Bool {
        let completion = ExportPrintCompletion()
        printCompletion = completion
        defer {
            printCompletion = nil
            close()
        }
        return await completion.run(operation, from: window)
    }

    func writePNG(to url: URL) async throws {
        guard !isClosed else { throw CancellationError() }
        let preparation: Task<Data, Error>
        if let pngPreparation {
            preparation = pngPreparation
        } else {
            // Share the render so one save cannot close another's page.
            preparation = Task {
                defer { pages.removeValue(forKey: .png)?.close() }
                do {
                    let view = try await webView(for: .png)
                    // WebKit's PDF capture uses screen media and one continuous page.
                    let data = try await view.pdf(configuration: WKPDFConfiguration())
                    try Task.checkCancellation()
                    return try Self.pngData(fromPDF: data)
                } catch {
                    pngPreparation = nil
                    throw error
                }
            }
            pngPreparation = preparation
        }
        let data = try await preparation.value
        guard !isClosed else { throw CancellationError() }
        try data.write(to: url)
    }

    /// Writes a reflowable EPUB of the rendered article. `markdown` supplies
    /// the frontmatter that names the book; `fallbackTitle` names it otherwise.
    func writeEPUB(to url: URL, markdown: String, fallbackTitle: String) async throws {
        guard !isClosed else { throw CancellationError() }
        // The conversion rewrites its page, so each save starts from a fresh one.
        defer { pages.removeValue(forKey: .epub)?.close() }
        let view = try await webView(for: .epub)
        guard let inventory = try await view.callAsyncJavaScript(
            EPUBExport.inventoryScript, in: nil, contentWorld: .page) as? [String: Any]
        else { throw Self.exportError("The document could not be prepared for export.") }

        // Every picture is captured from the page as the preview drew it.
        var resources: [EPUBPackage.Resource] = []
        var pictures: [Any] = []
        for box in inventory["pictures"] as? [[String: Any]] ?? [] {
            guard !isClosed else { throw CancellationError() }
            guard let x = box["x"] as? Double, let y = box["y"] as? Double,
                  let width = box["width"] as? Double, let height = box["height"] as? Double,
                  let displayWidth = box["displayWidth"] as? Double
            else {
                pictures.append(NSNull())
                continue
            }
            let capture = WKPDFConfiguration()
            capture.rect = CGRect(x: x, y: y, width: width, height: height)
            // Twice the size a reader shows it, short of an unreasonable bitmap.
            let scale = min(2 * displayWidth / width, 8192 / max(width, height))
            // Photographs stay JPEG; as PNG they would be many times larger.
            let isPhoto = box["jpeg"] as? Bool ?? false
            // One picture that cannot be captured leaves its description; it
            // is no reason to lose the book.
            guard let pdf = try? await view.pdf(configuration: capture),
                  let png = try? Self.pngData(fromPDF: pdf, scale: scale),
                  let data = isPhoto
                    ? NSBitmapImageRep(data: png)?.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
                    : png
            else {
                pictures.append(NSNull())
                continue
            }
            let path = "images/image-\(resources.count + 1).\(isPhoto ? "jpg" : "png")"
            resources.append(.init(path: path, mediaType: isPhoto ? "image/jpeg" : "image/png", data: data))
            pictures.append(["path": path, "width": displayWidth])
        }

        guard let converted = try await view.callAsyncJavaScript(
            EPUBExport.conversionScript, arguments: ["pictures": pictures],
            in: nil, contentWorld: .page) as? [String: Any],
              let convertedSections = converted["sections"] as? [[String: Any]]
        else { throw Self.exportError("The document could not be prepared for export.") }
        let sections = convertedSections.compactMap { section -> EPUBPackage.Section? in
            guard let file = section["file"] as? String, let xhtml = section["xhtml"] as? String else {
                return nil
            }
            return .init(fileName: file, title: section["title"] as? String ?? "", xhtml: xhtml,
                         containsMath: section["math"] as? Bool ?? false)
        }
        let headings = (converted["navigation"] as? [[String: Any]] ?? []).compactMap { entry -> EPUBPackage.Heading? in
            guard let level = entry["level"] as? Int, let title = entry["title"] as? String,
                  let href = entry["href"] as? String else { return nil }
            return .init(level: level, title: title, href: href)
        }
        let metadata = EPUBExport.metadata(from: markdown)
        let headingTitle = converted["title"] as? String ?? ""
        let package = EPUBPackage(
            title: metadata.title ?? (headingTitle.isEmpty ? fallbackTitle : headingTitle),
            authors: metadata.authors, language: metadata.language,
            sections: sections, headings: headings, resources: resources)
        guard !sections.isEmpty,
              let data = try? await Task(operation: { @concurrent in try package.archiveData() }).value
        else { throw Self.exportError("The document could not be prepared for export.") }
        guard !isClosed else { throw CancellationError() }
        try data.write(to: url, options: .atomic)
    }

    func close() {
        isClosed = true
        paperPreparation?.cancel()
        paperPreparation = nil
        pngPreparation?.cancel()
        pngPreparation = nil
        pages.values.forEach { $0.close() }
        pages.removeAll()
    }

    private static func exportError(_ message: String) -> NSError {
        NSError(domain: "doc.md-preview.export", code: 1, userInfo: [
            NSLocalizedDescriptionKey: NSLocalizedString(message, comment: "Document export failure"),
        ])
    }
}

@MainActor
private final class ExportPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private let window: NSWindow
    private var navigation: CheckedContinuation<Void, Error>?

    init(size: NSSize, configuration: WKWebViewConfiguration) {
        let frame = NSRect(origin: .zero, size: size)
        webView = WKWebView(frame: frame, configuration: configuration)
        window = NSWindow(contentRect: frame, styleMask: [], backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.contentView = webView
        webView.navigationDelegate = self
    }

    func load(_ html: String, baseURL: URL?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func close() {
        finish(.failure(CancellationError()))
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.close()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = navigation
        navigation = nil
        continuation?.resume(with: result)
    }
}

@MainActor
private final class ExportPrintCompletion: NSObject {
    private var continuation: CheckedContinuation<Bool, Never>?

    func run(_ operation: NSPrintOperation, from window: NSWindow) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            operation.runModal(for: window, delegate: self,
                               didRun: #selector(didRun(_:success:contextInfo:)), contextInfo: nil)
        }
    }

    // AppKit can finish printing on its print worker thread.
    @objc nonisolated private func didRun(_ operation: NSPrintOperation, success: Bool,
                                         contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(returning: success)
        }
    }
}

extension DocumentExportSession {
    private static func pngData(fromPDF data: Data, scale: CGFloat = 2) throws -> Data {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw exportError("The document could not be rendered as an image.")
        }

        // 2x by default so the result stays sharp on Retina displays and when zoomed.
        let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
        let bounds = pages.map { $0.bounds(for: .mediaBox) }
        let width = bounds.map(\.width).max() ?? 0
        let height = bounds.map(\.height).reduce(0, +)
        guard width > 0, height > 0 else {
            throw exportError("The document could not be rendered as an image.")
        }

        let pixelWidth = Int((width * scale).rounded())
        let pixelHeight = Int((height * scale).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw exportError("The image could not be allocated.")
        }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw exportError("The image could not be allocated.")
        }
        NSGraphicsContext.current = context
        let cgContext = context.cgContext
        cgContext.scaleBy(x: scale, y: scale)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // PDF origin is bottom-left, so stack downward from the top edge.
        var offsetY = height
        for (page, pageBounds) in zip(pages, bounds) {
            offsetY -= pageBounds.height
            cgContext.saveGState()
            cgContext.translateBy(x: 0, y: offsetY)
            page.draw(with: .mediaBox, to: cgContext)
            cgContext.restoreGState()
        }

        // Set the point size only after drawing: a bitmap context scales by
        // the rep's pixels-per-point, which would apply `scale` a second time
        // and leave just an enlarged corner of the document in the image.
        rep.size = NSSize(width: width, height: height)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw exportError("The image could not be encoded.")
        }
        return png
    }

}
