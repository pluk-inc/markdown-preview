//
//  EPUBExport.swift
//  md-preview
//
//  Turns an exported preview page into the parts of an EPUBPackage. The page
//  scripts run in a throwaway copy of the document (see DocumentExportSession),
//  so they are free to rewrite it.
//

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
        // A language, then subtags of two letters or more. A single letter
        // opens an extension, or `x` private use, and needs a subtag after it.
        let tag = #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*(-[A-WY-Za-wy-z0-9](-[A-Za-z0-9]{2,8})+)*(-[Xx](-[A-Za-z0-9]{1,8})+)?$"#
        // Locale identifiers such as `en_GB` are a common way to write a tag.
        if let declared = declared?.replacingOccurrences(of: "_", with: "-"),
           declared.range(of: tag, options: .regularExpression) != nil {
            return declared
        }
        // A sample is enough, and keeps long documents quick.
        if let detected = NLLanguageRecognizer.dominantLanguage(for: String(text.prefix(20_000))),
           detected != .undetermined {
            return detected.rawValue
        }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    // MARK: - Page scripts

    /// Marks every picture the book will carry and reports where the page
    /// draws it: Mermaid diagrams, inline SVG and images.
    ///
    /// Pictures are captured from this page, never re-read from their source.
    /// The book then holds what the preview showed, at the size it showed it,
    /// and nothing else: no bytes fetched a second time, no file the preview
    /// did not display, and no SVG markup a reading app would have to trust.
    static let inventoryScript = #"""
    const article = document.querySelector('article.markdown-body');
    if (!article) return null;
    // A reader shows pictures on its own light page, whatever the preview's theme.
    document.documentElement.setAttribute('data-mdp-color-scheme', 'light');
    const style = document.createElement('style');
    style.textContent = 'html, body, .mermaid-figure, .mermaid-stage, .mermaid { background: #fff !important; }';
    document.head.append(style);
    // Preview controls would end up in the pictures, and a closed disclosure
    // hides what the book shows open.
    article.querySelectorAll('.mermaid-hud, .markdown-alert-icon, .md-code-header, .md-table-actions, button')
        .forEach(node => node.remove());
    article.querySelectorAll('details').forEach(details => { details.open = true; });
    scrollTo(0, 0);

    const pictures = [];
    const add = (element, box, displayWidth, jpeg) => {
        element.setAttribute('data-epub-picture', String(pictures.length));
        pictures.push({ x: box.x, y: box.y, width: box.width, height: box.height, displayWidth, jpeg });
    };
    const drawn = box => box.width > 0 && box.height > 0;
    for (const element of article.querySelectorAll('.mermaid-figure, svg, img')) {
        if (element.localName === 'img') {
            // Only an image the preview loaded, and only if it is on the page.
            if (!(await element.decode().then(() => true, () => false))) continue;
            const box = element.getBoundingClientRect();
            if (!drawn(box)) { element.remove(); continue; }
            const source = element.currentSrc || element.src;
            add(element, box, box.width, /^data:image\/jpe?g|\.jpe?g($|[?#])/i.test(source));
        } else if (element.localName === 'svg') {
            // Inline SVG typed into the document; a diagram's own is handled below.
            if (element.closest('.mermaid-figure') || element.parentElement.closest('svg')) continue;
            const box = element.getBoundingClientRect();
            if (drawn(box)) add(element, box, box.width, false);
        } else {
            const svg = element.querySelector('.mermaid svg');
            const box = svg && svg.getBoundingClientRect();
            if (!box || !drawn(box)) continue;
            // The preview fits each drawing inside a wider element. Report the
            // drawing itself, and the size Mermaid laid it out at: its text is
            // body-sized there, which is how large a reader should show it.
            const view = svg.viewBox && svg.viewBox.baseVal;
            const natural = view && view.width > 0 && view.height > 0 ? view : box;
            const fit = Math.min(box.width / natural.width, box.height / natural.height);
            const width = natural.width * fit;
            const height = natural.height * fit;
            add(element, {
                x: box.left + (box.width - width) / 2, y: box.top + (box.height - height) / 2, width, height
            }, natural.width, false);
        }
    }
    return { pictures };
    """#

    /// Rewrites the article into reader-friendly markup and returns it as
    /// well-formed XHTML sections plus the table of contents.
    ///
    /// `pictures` holds `{ path, width }` for each picture the inventory
    /// marked, in the same order, or null where the capture failed.
    static let conversionScript = #"""
    const article = document.querySelector('article.markdown-body');
    if (!article) return null;
    const all = selector => Array.from(article.querySelectorAll(selector));
    const clean = text => (text || '').replace(/\s+/g, ' ').trim();

    // In-document links resolve as the preview does (MarkdownHTML's
    // fragmentTargetScript): literal ids first, then GitHub-style heading slugs.
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
        const base = slugify(heading.textContent || '');
        let slug = base;
        if (seen.has(slug)) {
            let count = seen.get(base);
            do { count += 1; slug = base + '-' + count; } while (seen.has(slug));
            seen.set(base, count);
        }
        seen.set(slug, 0);
        slugs.set(slug, heading);
    }

    // An image the preview could not load leaves its description.
    all('img:not([data-epub-picture])').forEach(image => image.replaceWith(image.getAttribute('alt') || ''));
    all('[data-epub-picture]').forEach(element => {
        const file = pictures[Number(element.getAttribute('data-epub-picture'))];
        const description = element.getAttribute(element.localName === 'img' ? 'alt' : 'aria-label') || '';
        if (!file) return element.replaceWith(description);
        const image = element.localName === 'img' ? element : document.createElement('img');
        image.setAttribute('src', file.path);
        image.setAttribute('alt', description);
        // The file is stored larger than it is shown, to stay sharp.
        image.setAttribute('width', String(Math.round(file.width)));
        image.removeAttribute('height');
        if (element.localName === 'svg') return element.replaceWith(image);
        if (element === image) return;
        const figure = document.createElement('figure');
        figure.className = 'mermaid-figure';
        figure.append(image);
        element.replaceWith(figure);
    });
    // KaTeX renders each formula twice. Keep the MathML, which readers lay out
    // themselves, and drop the HTML that needs KaTeX's stylesheet and fonts.
    all('.katex').forEach(katex => {
        const math = katex.querySelector('.katex-mathml > math');
        if (!math) return;
        math.querySelectorAll('annotation').forEach(node => node.remove());
        // KaTeX writes spacing commands such as `\,` as bare characters, but
        // MathML holds text only in token elements. Each becomes an <mtext>,
        // which keeps the space and stands in the formula as one element.
        const loose = [];
        const walker = document.createTreeWalker(math, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
            if (!/^(mi|mn|mo|ms|mtext)$/.test(node.parentNode.localName)) loose.push(node);
        }
        loose.forEach(node => {
            const text = document.createElementNS(math.namespaceURI, 'mtext');
            node.replaceWith(text);
            text.append(node);
        });
        (katex.closest('.katex-display') || katex).replaceWith(math);
    });
    all('.md-code-wrap').forEach(wrap => {
        const pre = wrap.querySelector('pre');
        if (pre) wrap.replaceWith(pre);
    });
    all('mark.md-search-highlight, mark.md-search-highlight-current')
        .forEach(mark => mark.replaceWith(...mark.childNodes));
    // Preview controls, spacing helpers, and anything a book cannot carry.
    // Every picture is a captured image by now, so any SVG left was not drawn.
    all(`script, style, link, template, button, iframe, object, embed, video, audio, canvas, svg,
         source, map, area, select, textarea, .md-source-blank-line, .md-code-header,
         .md-code-action, .md-table-actions, .md-search-burst, .mermaid-hud, .markdown-alert-icon`)
        .forEach(node => node.remove());
    // Form controls are dropped by some readers; a glyph always shows.
    all('input').forEach(input => {
        if (input.type === 'checkbox') input.replaceWith(input.checked ? '\u2611' : '\u2610');
        else input.remove();
    });
    all('details').forEach(details => details.setAttribute('open', ''));
    all('table').forEach(table => {
        const columns = Math.max(0, ...Array.from(table.rows, row => row.cells.length));
        if (columns >= 6) table.classList.add('md-many-columns');
    });
    all('*').forEach(element => {
        const tag = element.localName;
        for (const attribute of Array.from(element.attributes)) {
            const name = attribute.name;
            // A book must not reach for the network when it is opened: only
            // links, and the pictures stored in it, may point anywhere.
            const reference = ['background', 'poster', 'srcset', 'sizes', 'ping', 'usemap'].includes(name)
                || (name === 'href' && tag !== 'a') || (name === 'src' && tag !== 'img')
                || attribute.namespaceURI === 'http://www.w3.org/1999/xlink';
            // A prefixed name typed into raw HTML (`xlink:href` on a link) has
            // no namespace, and would make the section unreadable as XML.
            if (reference || name.startsWith('data-') || name === 'tabindex' || name === 'loading'
                || name === 'contenteditable' || (attribute.namespaceURI === null && name.includes(':'))) {
                element.removeAttributeNode(attribute);
            }
        }
        // `align` is not valid in a book's XHTML.
        const align = element.getAttribute('align');
        if (align === null) return;
        if (tag !== 'img' && element.style) element.style.textAlign = align;
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
            const target = destination(href.slice(1));
            if (!target) {
                // As in the preview, `#` and `#top` lead to the start.
                if (/^#(top)?$/i.test(href)) link.setAttribute('href', files[0]);
                else link.removeAttribute('href');
                return;
            }
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
    const invalid = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\uFFFE\uFFFF]/g;
    const sections = groups.map((group, index) => {
        const heading = group.find(node => level(node));
        const holder = document.createElement('article');
        holder.className = 'markdown-body';
        holder.append(...group);
        return {
            file: files[index],
            title: heading ? clean(heading.textContent) : '',
            xhtml: serializer.serializeToString(holder).replace(invalid, ''),
            math: holder.querySelector('math') !== null
        };
    });
    return { sections, navigation, title };
    """#
}
