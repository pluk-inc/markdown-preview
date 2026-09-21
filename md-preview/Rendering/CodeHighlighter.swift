//
//  CodeHighlighter.swift
//  md-preview
//
//  Highlights fenced code at render time, so the page arrives with its
//  syntax spans in place and paints once.
//

import Foundation
import JavaScriptCore

/// Runs the bundled highlight.js grammar set in a JavaScriptCore context on
/// the render thread and returns the highlighted inner HTML of a code block.
///
/// One context lives for the whole process: loading the grammar bundle costs
/// about 15 ms, highlighting a typical block well under 2 ms after that, and
/// JavaScriptCore serializes calls through its own lock, so the render paths
/// of several documents can share it. Results are cached by language and
/// source, so a reloaded or re-rendered document pays nothing.
///
/// The output uses the same `hljs-*` classes the in-page pass produces, so the
/// stylesheet's `--hl-*` palette applies unchanged, and the block is stamped
/// `data-hljs-done="1"` so `MdPreview.update` and the deferred pass treat it as
/// finished. The deferred pass stays in the page only as a fallback for blocks
/// this highlighter could not render.
nonisolated enum CodeHighlighter {
    /// `false` when the grammar bundle is missing; callers then fall back to
    /// the deferred in-page pass.
    static var isAvailable: Bool { Engine.shared != nil }

    /// Replaces the grammar bundle the engine runs. The app never calls this:
    /// it exists for the helper test package, which has no app bundle to load
    /// `Vendor/Highlight/highlight.min.js` from.
    static func useGrammar(source: String) {
        Engine.install(source: source)
    }

    /// Languages offered to highlight.js auto-detection for fences without an
    /// info string that the regex detector did not recognize. Kept in step with
    /// `autoDetectCodeLanguage` in MarkdownHTML+Highlight.swift.
    static let autoDetectCandidates = [
        "javascript", "typescript", "python", "json", "css", "xml",
        "bash", "swift", "go", "ruby", "rust", "c", "cpp", "java", "kotlin",
        "csharp", "sql", "yaml", "toml",
    ]

    /// Highlighted inner HTML for `code` in `language`, or `nil` when the
    /// language is unknown to the bundle or the engine is unavailable. The
    /// result is HTML-escaped text wrapped in `hljs-*` spans.
    static func highlight(_ code: String, language: String) -> String? {
        guard !language.isEmpty, let engine = Engine.shared else { return nil }
        let key = "\(language)\u{0}\(code)" as NSString
        if let cached = engine.cache.object(forKey: key) { return cached as String }
        guard var html = engine.highlight(code, language: language) else { return nil }
        if language == "bash" {
            html = decorateShellOptions(in: html)
        }
        engine.cache.setObject(html as NSString, forKey: key, cost: html.utf8.count)
        return html
    }

    /// Whether the bundle has a grammar registered under `language` or one of
    /// its aliases.
    static func supports(language: String) -> Bool {
        guard !language.isEmpty, let engine = Engine.shared else { return false }
        return engine.supports(language: language)
    }

    /// highlight.js auto-detection over `autoDetectCandidates`, accepted only
    /// with the same relevance floor as the in-page pass.
    static func detectLanguage(_ code: String) -> String? {
        guard let engine = Engine.shared else { return nil }
        return engine.detectLanguage(code, candidates: autoDetectCandidates)
    }

    // MARK: - Shell options

    /// Wraps `--long` and `-s` command options in `hljs-attr` spans, the way
    /// the in-page pass does, skipping text inside comments, strings, meta
    /// lines, and existing attributes. Works on the escaped HTML: text between
    /// tags is walked with a stack of the open spans' classes.
    static func decorateShellOptions(in html: String) -> String {
        var output = ""
        output.reserveCapacity(html.utf8.count + 64)
        var stack: [String] = []
        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<" {
                guard let close = html[index...].firstIndex(of: ">") else {
                    output += html[index...]
                    break
                }
                let tag = html[index...close]
                output += tag
                if tag.hasPrefix("</") {
                    if !stack.isEmpty { stack.removeLast() }
                } else if !tag.hasSuffix("/>") {
                    stack.append(classAttribute(in: tag))
                }
                index = html.index(after: close)
            } else {
                let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                let text = html[index..<next]
                let protected = stack.contains { classes in
                    protectedClasses.contains { classes.contains($0) }
                }
                output += protected ? String(text) : wrapOptions(in: String(text))
                index = next
            }
        }
        return output
    }

    private static let protectedClasses = ["hljs-comment", "hljs-string", "hljs-meta", "hljs-attr"]

    private static let optionRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: #"(^|[\s=])(-{1,2}[A-Za-z][A-Za-z0-9-]*)(?=$|[=\s;&|)])"#,
            options: [.anchorsMatchLines]
        )
    }()

    private static func wrapOptions(in text: String) -> String {
        let nsText = text as NSString
        let matches = optionRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            let option = match.range(at: 2)
            result += nsText.substring(with: NSRange(location: cursor, length: option.location - cursor))
            result += "<span class=\"hljs-attr\">\(nsText.substring(with: option))</span>"
            cursor = option.location + option.length
        }
        result += nsText.substring(from: cursor)
        return result
    }

    private static func classAttribute(in tag: Substring) -> String {
        guard let range = tag.range(of: "class=\"") else { return "" }
        let start = range.upperBound
        guard let end = tag[start...].firstIndex(of: "\"") else { return "" }
        return String(tag[start..<end])
    }

    // MARK: - Engine

    private final class Engine: @unchecked Sendable {
        /// Created on first use from the bundled grammar; `nil` when the
        /// bundle is missing. `useGrammar(source:)` replaces it.
        static var shared: Engine? {
            lock.lock()
            defer { lock.unlock() }
            if let engine = storage { return engine }
            let bundled = MarkdownHTML.bundledVendorResource(
                "highlight.min", ext: "js", subdir: "Vendor/Highlight"
            )
            let engine = bundled.flatMap(Engine.init(source:))
            storage = .some(engine)
            return engine
        }

        static func install(source: String) {
            lock.lock()
            defer { lock.unlock() }
            storage = .some(Engine(source: source))
        }

        private static let lock = NSLock()
        /// `nil` until the first lookup; `.some(nil)` when the bundle was missing.
        nonisolated(unsafe) private static var storage: Engine??

        private let context: JSContext
        private let hljs: JSValue
        /// Highlighted HTML by language and source. NSCache is thread-safe.
        let cache: NSCache<NSString, NSString> = {
            let cache = NSCache<NSString, NSString>()
            cache.totalCostLimit = 8 * 1024 * 1024
            return cache
        }()

        private init?(source: String) {
            guard let context = JSContext() else { return nil }
            context.exceptionHandler = { _, _ in }
            context.evaluateScript(source)
            guard let hljs = context.objectForKeyedSubscript("hljs"),
                  hljs.isObject,
                  hljs.hasProperty("highlight") else { return nil }
            self.context = context
            self.hljs = hljs
        }

        func supports(language: String) -> Bool {
            guard let value = hljs.invokeMethod("getLanguage", withArguments: [language]) else {
                return false
            }
            return value.isObject
        }

        func highlight(_ code: String, language: String) -> String? {
            guard supports(language: language),
                  let result = hljs.invokeMethod(
                    "highlight",
                    withArguments: [code, ["language": language, "ignoreIllegals": true]]
                  ),
                  result.isObject,
                  let value = result.objectForKeyedSubscript("value"),
                  value.isString else { return nil }
            return value.toString()
        }

        func detectLanguage(_ code: String, candidates: [String]) -> String? {
            let text = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  let result = hljs.invokeMethod("highlightAuto", withArguments: [text, candidates]),
                  result.isObject,
                  let relevance = result.objectForKeyedSubscript("relevance"),
                  relevance.isNumber, relevance.toDouble() >= 2,
                  let language = result.objectForKeyedSubscript("language"),
                  language.isString else { return nil }
            let name = language.toString() ?? ""
            return name.isEmpty ? nil : name
        }
    }
}
