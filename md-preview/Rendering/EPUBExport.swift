//
//  EPUBExport.swift
//  md-preview
//
//  Turns an exported preview page into the parts of an EPUBPackage. The page
//  scripts run in a throwaway copy of the document (see DocumentExportSession),
//  so they are free to rewrite it.
//

import AppKit
import Foundation
import NaturalLanguage

nonisolated enum EPUBExport {
    // MARK: - Book details

    struct Metadata: Equatable {
        var title: String?
        var authors: [String] = []
        var language: String
    }

    /// Frontmatter names the book where it can; the language otherwise comes
    /// from the text, because readers pick hyphenation and dictionaries by it.
    static func metadata(from markdown: String) -> Metadata {
        let frontmatter = MarkdownFrontmatter.split(markdown)
        var entries: [String: FrontmatterEntry] = [:]
        if let raw = frontmatter.raw, let format = frontmatter.format {
            for entry in MarkdownFrontmatter.parse(raw, format: format) {
                entries[entry.key.lowercased()] = entry
            }
        }
        func value(_ keys: String...) -> String? {
            keys.lazy.compactMap { entries[$0]?.value.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
        }
        var authors: [String] = []
        for key in ["author", "authors"] {
            guard let entry = entries[key] else { continue }
            authors = (entry.items ?? [entry.value])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !authors.isEmpty { break }
        }
        return Metadata(title: value("title"), authors: authors,
                        language: language(declared: value("lang", "language"), text: frontmatter.body))
    }

    private static func language(declared: String?, text: String) -> String {
        let tag = #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$"#
        if let declared, declared.range(of: tag, options: .regularExpression) != nil {
            return declared
        }
        // A sample is enough, and keeps long documents quick.
        if let detected = NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(20_000))),
           detected != .undetermined {
            return detected.rawValue
        }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    // MARK: - Images

    struct Image: Sendable {
        var data: Data
        var mediaType: String
        var fileExtension: String
    }

    /// Loads the images the page shows, keyed by the URL the page used.
    /// Images that cannot be read are left out; the page falls back to their
    /// alternative text.
    @concurrent
    static func loadImages(_ sources: [String]) async -> [String: Image] {
        // A stalled or endless download must not hold the export open.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return await withTaskGroup(of: (String, Image?).self) { group in
            for source in Set(sources) {
                group.addTask { (source, await loadImage(source, using: session)) }
            }
            var images: [String: Image] = [:]
            for await (source, image) in group {
                images[source] = image
            }
            return images
        }
    }

    private static func loadImage(_ source: String, using session: URLSession) async -> Image? {
        guard let url = URL(string: source) else { return nil }
        let data: Data?
        switch url.scheme?.lowercased() {
        case MarkdownAssetResolution.scheme:
            data = MarkdownAssetResolution.fileURL(for: url).flatMap { try? Data(contentsOf: $0) }
        case "http", "https", "data":
            // A book cannot refer to the network, so remote images are embedded.
            if let (body, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true {
                data = body
            } else {
                data = nil
            }
        default:
            data = nil
        }
        return data.flatMap(image(from:))
    }

    /// Passes through the formats every reader accepts and re-encodes the
    /// rest (WebP, HEIC, TIFF, …) as PNG.
    static func image(from data: Data) -> Image? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return Image(data: data, mediaType: "image/png", fileExtension: "png")
        }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return Image(data: data, mediaType: "image/jpeg", fileExtension: "jpg")
        }
        if data.starts(with: Data("GIF8".utf8)) {
            return Image(data: data, mediaType: "image/gif", fileExtension: "gif")
        }
        // A web page served in place of a missing image can contain an inline
        // `<svg>` too; that is not a picture.
        let start = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if start.contains("<svg"), !start.contains("<html"), !start.contains("<!doctype html") {
            return Image(data: data, mediaType: "image/svg+xml", fileExtension: "svg")
        }
        guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
            return nil
        }
        return Image(data: png, mediaType: "image/png", fileExtension: "png")
    }

    // MARK: - Page scripts

    /// Lists what has to be gathered before the page is converted: where each
    /// rendered diagram is drawn on the page, and the URL of every image the
    /// page managed to load. An image the preview could not show (missing, or
    /// refused by the asset handler) is never read for the book either.
    static let inventoryScript = #"""
    const article = document.querySelector('article.markdown-body');
    if (!article) return null;
    // Diagrams are captured as pictures; give them the white page a reader
    // shows them on, whatever the preview's theme.
    document.documentElement.setAttribute('data-mdp-color-scheme', 'light');
    const style = document.createElement('style');
    style.textContent = 'html, body, .mermaid-figure, .mermaid-stage, .mermaid { background: #fff !important; }';
    document.head.append(style);
    article.querySelectorAll('.mermaid-hud').forEach(node => node.remove());
    scrollTo(0, 0);
    const diagrams = Array.from(article.querySelectorAll('.mermaid-figure'), figure => {
        const svg = figure.querySelector('.mermaid svg');
        const box = svg && svg.getBoundingClientRect();
        if (!box || !(box.width > 0 && box.height > 0)) return null;
        // The preview fits each drawing inside a wider element. Report the
        // drawing itself, and the size Mermaid laid it out at: its text is
        // body-sized there, which is how large a reader should show it.
        const view = svg.viewBox && svg.viewBox.baseVal;
        const natural = view && view.width > 0 && view.height > 0 ? view : box;
        const fit = Math.min(box.width / natural.width, box.height / natural.height);
        const width = natural.width * fit;
        const height = natural.height * fit;
        return {
            x: box.left + (box.width - width) / 2, y: box.top + (box.height - height) / 2,
            width, height, naturalWidth: natural.width
        };
    });
    const loaded = await Promise.all(Array.from(article.querySelectorAll('img'), image =>
        image.decode().then(() => image.currentSrc || image.src, () => '')));
    return { diagrams, images: Array.from(new Set(loaded.filter(Boolean))) };
    """#

    /// Rewrites the article into reader-friendly markup and returns it as
    /// well-formed XHTML sections plus the table of contents.
    ///
    /// `images` maps the inventory's image URLs to file paths inside the book;
    /// `diagrams` holds `{ path, width }` (or null) per diagram, in page order.
    static let conversionScript = #"""
    const article = document.querySelector('article.markdown-body');
    if (!article) return null;
    const all = selector => Array.from(article.querySelectorAll(selector));
    const clean = text => (text || '').replace(/\s+/g, ' ').trim();

    // In-document links resolve as the preview does (MarkdownWebView's
    // elementOffset): literal ids first, then GitHub-style heading slugs.
    // Slugs are taken now, from the text the preview shows, before the
    // rewriting below changes what a heading contains.
    const headings = all('h1, h2, h3, h4, h5, h6');
    headings.forEach((heading, index) => {
        if (!heading.id) heading.id = 'epub-heading-' + index;
    });
    const slugify = text => text.toLowerCase().trim()
        .replace(/[^\p{L}\p{N}\s_-]/gu, '').replace(/\s/g, '-');
    const slugs = new Map();
    const seen = new Map();
    for (const heading of headings) {
        let slug = slugify(heading.textContent || '');
        const count = seen.get(slug) || 0;
        seen.set(slug, count + 1);
        if (count > 0) slug = slug + '-' + count;
        if (!slugs.has(slug)) slugs.set(slug, heading);
    }

    all('img').forEach(image => {
        const file = images[image.currentSrc || image.src];
        if (file) {
            image.setAttribute('src', file);
            image.removeAttribute('srcset');
        } else {
            image.replaceWith(image.getAttribute('alt') || '');
        }
    });
    // Mermaid's SVG leans on features e-readers lack; use the captured picture.
    all('.mermaid-figure').forEach((figure, index) => {
        const file = diagrams[index];
        if (!file) return;
        const image = document.createElement('img');
        image.setAttribute('src', file.path);
        image.setAttribute('alt', figure.getAttribute('aria-label') || '');
        image.setAttribute('width', String(Math.round(file.width)));
        const replacement = document.createElement('figure');
        replacement.className = 'mermaid-figure';
        replacement.append(image);
        figure.replaceWith(replacement);
    });
    // KaTeX renders each formula twice. Keep the MathML, which readers lay out
    // themselves, and drop the HTML that needs KaTeX's stylesheet and fonts.
    all('.katex').forEach(katex => {
        const math = katex.querySelector('.katex-mathml > math');
        if (!math) return;
        math.querySelectorAll('annotation').forEach(node => node.remove());
        (katex.closest('.katex-display') || katex).replaceWith(math);
    });
    all('.md-code-wrap').forEach(wrap => {
        const pre = wrap.querySelector('pre');
        if (pre) wrap.replaceWith(pre);
    });
    all('mark.md-search-highlight, mark.md-search-highlight-current')
        .forEach(mark => mark.replaceWith(...mark.childNodes));
    // Preview controls, spacing helpers, and anything a book cannot carry.
    all(`script, style, link, template, button, iframe, object, embed, video, audio, canvas,
         source, select, textarea, .md-source-blank-line, .md-code-header, .md-code-action,
         .md-table-actions, .md-search-burst, .mermaid-hud, .markdown-alert-icon`)
        .forEach(node => node.remove());
    // Form controls are dropped by some readers; a glyph always shows.
    all('input').forEach(input => {
        if (input.type === 'checkbox') input.replaceWith(input.checked ? '☑' : '☐');
        else input.remove();
    });
    all('details').forEach(details => details.setAttribute('open', ''));
    all('table').forEach(table => {
        const columns = Math.max(0, ...Array.from(table.rows, row => row.cells.length));
        if (columns >= 6) table.classList.add('md-many-columns');
    });
    all('*').forEach(element => {
        for (const attribute of Array.from(element.attributes)) {
            const name = attribute.name;
            // A prefixed name typed into raw HTML (`xlink:href` on a link) has
            // no namespace, and would make the section unreadable as XML.
            if (name.startsWith('data-') || name === 'tabindex' || name === 'loading'
                || name === 'contenteditable' || (attribute.namespaceURI === null && name.includes(':'))) {
                element.removeAttributeNode(attribute);
            }
        }
        // `align` is not valid in a book's XHTML.
        const align = element.getAttribute('align');
        if (align === null) return;
        if (element.localName !== 'img' && element.style) element.style.textAlign = align;
        element.removeAttribute('align');
    });

    // One file per section, split at the shallowest heading level that repeats:
    // a single title followed by many second-level headings splits at those.
    const nodes = Array.from(article.childNodes);
    const level = node => node.nodeType === 1 && /^h[1-6]$/.test(node.localName)
        ? Number(node.localName[1]) : 0;
    const counts = new Array(7).fill(0);
    nodes.forEach(node => { counts[level(node)] += 1; });
    const splitLevel = [1, 2, 3, 4, 5, 6].find(candidate => counts[candidate] > 1) || 0;
    const groups = [[]];
    let started = false;
    for (const node of nodes) {
        const depth = level(node);
        if (depth && depth <= splitLevel) {
            // Anything before the first heading opens the first section.
            if (started) groups.push([]);
            started = true;
        }
        groups[groups.length - 1].push(node);
    }
    const files = groups.map((_, index) => 'section-' + String(index + 1).padStart(3, '0') + '.xhtml');
    const sectionOfNode = new Map();
    groups.forEach((group, index) => group.forEach(node => sectionOfNode.set(node, index)));
    const sectionOf = element => {
        let node = element;
        while (node && node.parentNode !== article) node = node.parentNode;
        return sectionOfNode.get(node);
    };

    const destination = fragment => {
        let id = fragment;
        try { id = decodeURIComponent(fragment); } catch (error) {}
        const element = document.getElementById(id);
        if (element && article.contains(element)) return element;
        return slugs.get(id.toLowerCase()) || null;
    };
    all('a[href]').forEach(link => {
        const href = link.getAttribute('href');
        if (href.startsWith('#')) {
            const target = href.length > 1 ? destination(href.slice(1)) : null;
            if (!target) return link.removeAttribute('href');
            const file = sectionOf(link) === sectionOf(target) ? '' : files[sectionOf(target)];
            link.setAttribute('href', file + '#' + encodeURIComponent(target.id));
        } else if (!/^(https?:|mailto:|tel:)/i.test(href)) {
            // Links to neighbouring files have nothing to open inside a book.
            link.removeAttribute('href');
        }
    });

    const navigation = headings.map(heading => ({
        level: Number(heading.localName[1]),
        title: clean(heading.textContent),
        href: files[sectionOf(heading)] + '#' + encodeURIComponent(heading.id)
    })).filter(entry => entry.title);
    const firstHeading = headings.find(heading => heading.localName === 'h1') || headings[0];
    const title = firstHeading ? clean(firstHeading.textContent) : '';

    const serializer = new XMLSerializer();
    // Characters XML 1.0 cannot contain, even escaped.
    const invalid = /[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g;
    const sections = groups.map((group, index) => {
        const heading = group.find(node => level(node));
        const holder = document.createElement('article');
        holder.className = 'markdown-body';
        holder.append(...group);
        return {
            file: files[index],
            title: heading ? clean(heading.textContent) : '',
            xhtml: serializer.serializeToString(holder).replace(invalid, ''),
            math: holder.querySelector('math') !== null,
            svg: holder.querySelector('svg') !== null
        };
    });
    return { sections, navigation, title };
    """#
}
