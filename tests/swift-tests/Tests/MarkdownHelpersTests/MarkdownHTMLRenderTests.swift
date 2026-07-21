import XCTest
import WebKit
@testable import MarkdownHelpers

final class MarkdownHTMLRenderTests: XCTestCase {
    func testYamlFrontmatterRendersAsTableBeforeDocumentBody() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ---
            name: build-validator
            description: Validate R&D < 5 & ship safely.
            ---
            You are a **build validator**.
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.hasPrefix("<section class=\"md-frontmatter\""))
        XCTAssertTrue(rendered.articleHTML.contains(
            "data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"4\""
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<tr><th scope=\"row\" dir=\"auto\">name</th><td dir=\"auto\">build-validator</td></tr>"
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<td dir=\"auto\">Validate R&amp;D &lt; 5 &amp; ship safely.</td>"
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<p data-source-line=\"5\" data-source-start=\"5\" data-source-end=\"5\">You are a <strong>build validator</strong>.</p>"
        ))
    }

    func testDocumentWithoutFrontmatterDoesNotRenderFrontmatterTable() {
        let rendered = MarkdownHTML.render(
            markdown: "# Plain document",
            vendorLoading: .lazy
        )

        XCTAssertFalse(rendered.articleHTML.contains("md-frontmatter"))
    }

    @MainActor
    func testScrollableLongTableKeepsWebKitViewportAndScrollsDocument() async throws {
        let rows = (1...750).map { "| \($0) | Function \($0) | 100.00% |" }
            .joined(separator: "\n")
        let rendered = MarkdownHTML.render(
            markdown: """
            | State | Function | Match |
            | --- | --- | ---: |
            \(rows)
            """,
            allowsScroll: true,
            vendorLoading: .lazy
        )
        let styleBlocks = rendered.html
            .components(separatedBy: "<style>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</style>").first }
            .map { "<style>\($0)</style>" }
            .joined(separator: "\n")
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \(styleBlocks)
        </head><body><article class="markdown-body">\(rendered.articleHTML)</article></body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))

        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const root = document.scrollingElement;
            window.scrollTo(0, root.scrollHeight);
            return JSON.stringify({
                viewportHeight: window.innerHeight,
                documentHeight: root.scrollHeight,
                scrollPosition: root.scrollTop,
                articleHeight: document.querySelector('article')?.getBoundingClientRect().height || 0,
                rowCount: document.querySelectorAll('tbody tr').length,
                overflowY: getComputedStyle(document.documentElement).overflowY,
                bodyOverflowY: getComputedStyle(document.body).overflowY,
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let metrics = try JSONDecoder().decode(
            LongDocumentScrollMetrics.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(metrics.viewportHeight, 600, accuracy: 1)
        XCTAssertEqual(metrics.rowCount, 750, json)
        XCTAssertGreaterThan(metrics.articleHeight, metrics.viewportHeight * 5, json)
        XCTAssertGreaterThan(metrics.documentHeight, metrics.viewportHeight * 5, json)
        XCTAssertGreaterThan(metrics.scrollPosition, metrics.viewportHeight, json)
        XCTAssertEqual(metrics.overflowY, "auto")
        XCTAssertEqual(metrics.bodyOverflowY, "visible")
    }

    @MainActor
    func testLongInlineCodeInHeadingStaysWithinViewport() async throws {
        let rendered = MarkdownHTML.render(
            markdown: "## 1. New port — `src/features/imageUpload/application/repositoryInterfaces/imageProcessedPublisherInterface.ts`",
            vendorLoading: .lazy
        )
        let stylesheet = try XCTUnwrap(
            rendered.html
                .components(separatedBy: "<style>")
                .dropFirst()
                .first?
                .components(separatedBy: "</style>")
                .first
        )
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>\(stylesheet)</style>
        </head>
        <body><article class="markdown-body">\(rendered.articleHTML)</article></body>
        </html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))

        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        (() => {
            const heading = document.querySelector('h2');
            const code = heading.querySelector('code');
            const style = getComputedStyle(code);
            return JSON.stringify({
                headingClientWidth: heading.clientWidth,
                headingScrollWidth: heading.scrollWidth,
                codeRight: code.getBoundingClientRect().right,
                viewportRight: document.documentElement.clientWidth,
                boxDecorationBreak: style.webkitBoxDecorationBreak,
            });
        })()
        """)
        let json = try XCTUnwrap(result as? String)
        let metrics = try JSONDecoder().decode(HeadingLayoutMetrics.self, from: Data(json.utf8))

        XCTAssertLessThanOrEqual(metrics.headingScrollWidth, metrics.headingClientWidth)
        XCTAssertLessThanOrEqual(metrics.codeRight, metrics.viewportRight)
        XCTAssertEqual(metrics.boxDecorationBreak, "clone")
    }

    func testReadModeLeavesSelectionPaintingToWebKit() {
        let rendered = MarkdownHTML.render(
            markdown: "Select this text.",
            vendorLoading: .lazy
        )
        let styleBlocks = rendered.html
            .components(separatedBy: "<style>")
            .dropFirst()
            .compactMap { $0.components(separatedBy: "</style>").first }
        let stylesheet = styleBlocks.joined(separator: "\n").lowercased()
        let nonSelectableRules = stylesheet
            .components(separatedBy: "}")
            .filter { $0.contains("user-select: none") }

        XCTAssertFalse(stylesheet.contains("::selection"))
        XCTAssertFalse(stylesheet.contains("::-webkit-selection"))
        XCTAssertFalse(stylesheet.contains("::-moz-selection"))
        XCTAssertEqual(nonSelectableRules.count, 1)
        XCTAssertTrue(nonSelectableRules[0].contains(".md-code-copy"))
    }

    func testBlockquoteUsesItsContentDirectionForLogicalBorder() {
        let rtl = MarkdownHTML.render(
            markdown: "> هذا اقتباس بالعربية.",
            vendorLoading: .lazy
        )
        let ltr = MarkdownHTML.render(
            markdown: "> An English blockquote.",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rtl.articleHTML.contains(
            #"<blockquote data-source-line="1" data-source-start="1" data-source-end="1" dir="rtl">"#
        ))
        XCTAssertFalse(ltr.articleHTML.contains(
            #"<blockquote data-source-line="1" data-source-start="1" data-source-end="1" dir="rtl">"#
        ))
        XCTAssertTrue(rtl.html.contains(
            "border-inline-start: 4px solid var(--quote-border);"
        ))
    }

    func testReadOnlyRenderingPreservesActualBlankLineCounts() {
        let rendered = MarkdownHTML.render(
            markdown: "First paragraph.\n\n\n## Heading\n\nSecond paragraph.",
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<h2 data-source-line=\"4\""
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<div class=\"md-source-blank-line\" aria-hidden=\"true\"></div>\n<p data-source-line=\"6\""
        ))
        XCTAssertTrue(rendered.html.contains(".md-source-blank-line {"))
        XCTAssertTrue(rendered.html.contains("height: 22.8px;"))
    }

    func testMermaidPostProcessingAcceptsSourceMappedPreTag() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<figure data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"4\" class=\"mermaid-figure\""
        ))
        XCTAssertFalse(rendered.articleHTML.contains("<code class=\"language-mermaid\""))
    }

    @MainActor
    func testMermaidWidthToggleExpandsAndRestoresDiagram() async throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```mermaid
            flowchart LR
                A --> B
            ```
            """,
            vendorLoading: .lazy
        )
        XCTAssertTrue(rendered.articleHTML.contains(
            #"data-mm-act="width" tabindex="-1" aria-label="Fill width" aria-pressed="false""#
        ))

        let stylesheet = try XCTUnwrap(
            rendered.html
                .components(separatedBy: "<style>")
                .dropFirst()
                .first?
                .components(separatedBy: "</style>")
                .first
        )
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>\(stylesheet)</style>
        </head><body><article class="markdown-body">\(rendered.articleHTML)</article>
        <script>
        const figure = document.querySelector('.mermaid-figure');
        figure.style.setProperty('--mm-aspect', '1 / 4');
        figure.querySelector('.mermaid').innerHTML = '<svg viewBox="0 0 200 800"></svg>';
        document.querySelector('.mermaid-hud').addEventListener('click', (event) => {
            const button = event.target.closest('[data-mm-act="width"]');
            if (!button) return;
            const figure = button.closest('.mermaid-figure');
            const expanded = figure.classList.toggle('mermaid-width-expanded');
            button.setAttribute('aria-pressed', String(expanded));
        });
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 600))

        webView.loadHTMLString(html, baseURL: nil)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }

        let metricsScript = """
        (() => {
            const host = document.querySelector('.mermaid');
            const figure = document.querySelector('.mermaid-figure');
            const article = document.querySelector('.markdown-body');
            const svg = host.querySelector('svg');
            const button = figure.querySelector('[data-mm-act="width"]');
            const style = getComputedStyle(host);
            return JSON.stringify({
                articleWidth: article.clientWidth,
                articleLeft: article.getBoundingClientRect().left,
                figureWidth: figure.getBoundingClientRect().width,
                figureLeft: figure.getBoundingClientRect().left,
                availableWidth: host.clientWidth
                    - parseFloat(style.paddingLeft)
                    - parseFloat(style.paddingRight),
                svgWidth: svg.getBoundingClientRect().width,
                expanded: figure.classList.contains('mermaid-width-expanded'),
                buttonPressed: button?.getAttribute('aria-pressed') || '',
            });
        })()
        """
        let initialResult = try await webView.evaluateJavaScript(metricsScript)
        let initialJSON = try XCTUnwrap(initialResult as? String)
        let initial = try JSONDecoder().decode(MermaidLayoutMetrics.self, from: Data(initialJSON.utf8))

        XCTAssertFalse(initial.expanded)
        XCTAssertEqual(initial.buttonPressed, "false")
        XCTAssertLessThan(initial.figureWidth, initial.articleWidth)
        XCTAssertEqual(
            initial.figureLeft - initial.articleLeft,
            (initial.articleWidth - initial.figureWidth) / 2,
            accuracy: 1
        )

        try await webView.evaluateJavaScript(
            "document.querySelector('[data-mm-act=\"width\"]').click()"
        )
        let expandedResult = try await webView.evaluateJavaScript(metricsScript)
        let expandedJSON = try XCTUnwrap(expandedResult as? String)
        let expanded = try JSONDecoder().decode(MermaidLayoutMetrics.self, from: Data(expandedJSON.utf8))

        XCTAssertTrue(expanded.expanded)
        XCTAssertEqual(expanded.buttonPressed, "true")
        XCTAssertEqual(expanded.figureWidth, expanded.articleWidth, accuracy: 1)
        XCTAssertEqual(expanded.svgWidth, expanded.availableWidth, accuracy: 1)

        try await webView.evaluateJavaScript(
            "document.querySelector('[data-mm-act=\"width\"]').click()"
        )
        let restoredResult = try await webView.evaluateJavaScript(metricsScript)
        let restoredJSON = try XCTUnwrap(restoredResult as? String)
        let restored = try JSONDecoder().decode(MermaidLayoutMetrics.self, from: Data(restoredJSON.utf8))

        XCTAssertFalse(restored.expanded)
        XCTAssertEqual(restored.buttonPressed, "false")
        XCTAssertEqual(restored.figureWidth, initial.figureWidth, accuracy: 1)
    }

    func testCodeBlockLayoutMatchesDeferredHighlightingFromFirstPaint() throws {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```swift
            let answer = 42
            ```
            """,
            vendorLoading: .lazy
        )

        let codeRuleStart = try XCTUnwrap(rendered.html.range(of: "pre code {"))
        let codeRuleEnd = try XCTUnwrap(
            rendered.html.range(of: "}", range: codeRuleStart.upperBound..<rendered.html.endIndex)
        )
        let codeRule = rendered.html[codeRuleStart.lowerBound..<codeRuleEnd.upperBound]

        XCTAssertTrue(codeRule.contains("display: block;"))
    }

    func testShellFenceAliasesUseBashReadModeGrammar() {
        for language in ["shell", "sh", "zsh", "console", "bash"] {
            let rendered = MarkdownHTML.render(
                markdown: """
                ```\(language)
                git status --short
                ```
                """,
                vendorLoading: .lazy
            )

            XCTAssertTrue(
                rendered.articleHTML.contains("<code class=\"language-bash\">"),
                "\(language): \(rendered.articleHTML)"
            )
        }
    }

    @MainActor
    func testReadModeHighlightsShellOptionsWithoutTouchingComments() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let highlightURL = repositoryRoot
            .appendingPathComponent("md-preview/Vendor/Highlight/highlight.min.js")
        let highlightJS = try String(contentsOf: highlightURL, encoding: .utf8)
            .replacingOccurrences(of: "</script", with: "<\\/script")
        let html = """
        <!DOCTYPE html>
        <html><body>
        <pre><code class="language-bash">#!/bin/bash -e
        git status --short
        git log --pretty=format:%h
        xcodebuild --derivedDataPath=/tmp/build
        npx serve-sim --list -q -a -b
        # --ignored</code></pre>
        <script>\(highlightJS)</script>
        <script>
        const MdPreviewPerf = { log() {}, now: () => performance.now() };
        window.requestAnimationFrame = (callback) => callback();
        \(MarkdownHTML.highlightAllBody)
        highlightAll();
        </script>
        </body></html>
        """
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 700, height: 300))

        webView.loadHTMLString(html, baseURL: repositoryRoot)
        while webView.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            let done = try await webView.evaluateJavaScript(
                "document.querySelector('code').dataset.hljsDone === '1'"
            ) as? Bool
            if done == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let result = try await webView.evaluateJavaScript("""
        JSON.stringify({
            options: Array.from(document.querySelectorAll('code > .hljs-attr')).map((node) => node.textContent),
            commentOptions: Array.from(document.querySelectorAll('.hljs-comment .hljs-attr')).map((node) => node.textContent),
            metaOptions: Array.from(document.querySelectorAll('.hljs-meta .hljs-attr')).map((node) => node.textContent),
            html: document.querySelector('code').innerHTML,
        })
        """)
        let json = try XCTUnwrap(result as? String)
        let values = try JSONDecoder().decode(ShellHighlightValues.self, from: Data(json.utf8))

        XCTAssertEqual(
            values.options,
            ["--short", "--pretty", "--derivedDataPath", "--list", "-q", "-a", "-b"],
            values.html
        )
        XCTAssertTrue(values.commentOptions.isEmpty)
        XCTAssertTrue(values.metaOptions.isEmpty)
    }

    func testBlockMathKeepsValidWrapperAndSourceLine() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ```math
            E = mc^2
            ```
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<div data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"3\" class=\"math math-display\">"
        ), rendered.articleHTML)
        XCTAssertFalse(rendered.articleHTML.contains("<p data-source-line=\"1\" data-source-start=\"1\" data-source-end=\"3\"><div"))
    }

    func testFootnoteRemovalDoesNotShiftFollowingSourceLines() {
        let rendered = MarkdownHTML.render(
            markdown: """
            Prelude.

            Reference.[^note]

            [^note]: First definition line.
                Second definition line.
                Third definition line.

            ## Target
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<h2 data-source-line=\"9\" data-source-start=\"9\" data-source-end=\"9\" id=\"md-heading-0\">Target</h2>"
        ))
        XCTAssertTrue(rendered.articleHTML.contains(
            "<p data-source-line=\"5\" data-source-start=\"5\" data-source-end=\"7\">First definition line."
        ))
    }

    func testFootnoteSourceLinesIncludeFrontmatterOffset() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ---
            title: Footnotes
            ---
            Prelude.

            Reference.[^note]

            [^note]: First definition line.
                Second definition line.
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<p data-source-line=\"8\" data-source-start=\"8\" data-source-end=\"9\">First definition line."
        ))
    }

    func testTablesExposeSourceRangeAndStableCellCoordinates() {
        let rendered = MarkdownHTML.render(
            markdown: """
            ---
            title: Editable table
            ---

            | Name | Score |
            | --- | ---: |
            | Ada | 10 |
            """,
            vendorLoading: .lazy
        )

        XCTAssertTrue(rendered.articleHTML.contains(
            "<table data-source-line=\"5\" data-source-start=\"5\" data-source-end=\"7\">"
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "<th data-table-row=\"0\" data-table-column=\"0\" data-table-markdown=\"Name\">Name</th>"
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "<td data-table-row=\"1\" data-table-column=\"1\" data-table-markdown=\"10\" align=\"right\">10</td>"
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.html.contains("function enableTableEditing()"))
        XCTAssertFalse(rendered.html.contains("md-table-edge-action"))
        XCTAssertTrue(rendered.html.contains("kind: 'tableContextMenu'"))
        XCTAssertTrue(rendered.html.contains("cell.dataset.placeholder = placeholder"))
        XCTAssertTrue(rendered.html.contains("function selectTablePart(cell, operation)"))
        XCTAssertTrue(rendered.html.contains("event.key === 'Backspace' || event.key === 'Delete'"))
        XCTAssertTrue(rendered.html.contains("selectTableRange(tableCellDrag.cell, cell)"))
        XCTAssertTrue(rendered.html.contains("window.getSelection()?.removeAllRanges()"))
        XCTAssertTrue(rendered.html.contains(".md-table-editor .is-table-selection-left"))
        XCTAssertTrue(rendered.html.contains("cell.hasAttribute('data-table-markdown')"))
        XCTAssertTrue(rendered.html.contains("cell.dataset.tableOriginal = cell.dataset.tableMarkdown || ''"))
    }

    func testRenderedTableCellsRetainOriginalMarkdownForSourceAwareEditing() throws {
        let markdown = """
        | Plain | Link | Emphasis | Code | Image |
        | --- | --- | --- | --- | --- |
        | Text | [Docs](https://example.com) | **Bold** | `a|b` | ![Alt](image.png) |
        """
        let rendered = MarkdownHTML.render(markdown: markdown, vendorLoading: .lazy)

        XCTAssertTrue(rendered.articleHTML.contains(
            "data-table-row=\"1\" data-table-column=\"0\" data-table-markdown=\"Text\""
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "data-table-row=\"1\" data-table-column=\"1\" data-table-markdown=\"[Docs](https://example.com)\""
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "data-table-row=\"1\" data-table-column=\"2\" data-table-markdown=\"**Bold**\""
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "data-table-row=\"1\" data-table-column=\"3\" data-table-markdown=\"`a|b`\""
        ), rendered.articleHTML)
        XCTAssertTrue(rendered.articleHTML.contains(
            "data-table-row=\"1\" data-table-column=\"4\" data-table-markdown=\"![Alt](image.png)\""
        ), rendered.articleHTML)

        let updated = try XCTUnwrap(MarkdownTableSource.applying(
            .setCell(row: 1, column: 1, markdown: "[Docs](https://example.com)!"),
            fromLine: 1,
            throughLine: 3,
            in: markdown
        ))
        XCTAssertTrue(updated.contains("[Docs](https://example.com)!"), updated)
        XCTAssertTrue(updated.contains("**Bold**"), updated)
        XCTAssertTrue(updated.contains("`a|b`"), updated)
        XCTAssertTrue(updated.contains("![Alt](image.png)"), updated)
    }

    func testTableCellEditTargetsExactSourceRangeAndEscapesPipes() throws {
        let markdown = """
        Before

        | Name | Value |
        | :--- | ---: |
        | Existing | `a|b` |

        After
        """
        let updated = try XCTUnwrap(MarkdownTableSource.applying(
            .setCell(row: 1, column: 0, markdown: "A | B"),
            fromLine: 3,
            throughLine: 5,
            in: markdown
        ))

        XCTAssertTrue(updated.contains("| A \\| B"), updated)
        XCTAssertTrue(updated.contains("`a|b`"), updated)
        XCTAssertTrue(updated.hasPrefix("Before\n\n"))
        XCTAssertTrue(updated.hasSuffix("\n\nAfter"))
    }

    func testTableRowsAndColumnsCanBeInsertedAndDeleted() throws {
        let markdown = """
        | Name | Value |
        | --- | --- |
        | One | 1 |
        """
        let withRow = try XCTUnwrap(MarkdownTableSource.applying(
            .insertRowAfter(1), fromLine: 1, throughLine: 3, in: markdown
        ))
        XCTAssertEqual(withRow.components(separatedBy: "\n").count, 4)

        let rowBefore = try XCTUnwrap(MarkdownTableSource.applying(
            .insertRowBefore(1), fromLine: 1, throughLine: 3, in: markdown
        ))
        XCTAssertEqual(rowBefore.components(separatedBy: "\n").count, 4)
        XCTAssertTrue(rowBefore.components(separatedBy: "\n")[2]
            .components(separatedBy: "|")
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespaces)
            .isEmpty == true)

        let withColumn = try XCTUnwrap(MarkdownTableSource.applying(
            .insertColumnAfter(0), fromLine: 1, throughLine: 4, in: withRow
        ))
        XCTAssertTrue(withColumn.components(separatedBy: "\n").allSatisfy {
            $0.filter { $0 == "|" }.count == 4
        }, withColumn)

        let columnBefore = try XCTUnwrap(MarkdownTableSource.applying(
            .insertColumnBefore(0), fromLine: 1, throughLine: 3, in: markdown
        ))
        let headerCells = columnBefore.components(separatedBy: "\n")[0]
            .components(separatedBy: "|")
            .dropFirst()
        XCTAssertTrue(headerCells.first?.trimmingCharacters(in: .whitespaces).isEmpty == true)
        XCTAssertEqual(headerCells.dropFirst().first?.trimmingCharacters(in: .whitespaces), "Name")

        let withoutRow = try XCTUnwrap(MarkdownTableSource.applying(
            .deleteRow(2), fromLine: 1, throughLine: 4, in: withColumn
        ))
        let withoutColumn = try XCTUnwrap(MarkdownTableSource.applying(
            .deleteColumn(1), fromLine: 1, throughLine: 3, in: withoutRow
        ))
        XCTAssertEqual(withoutColumn.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(withoutColumn.contains("| Name"))
        XCTAssertTrue(withoutColumn.contains("| One"))
    }
}

private struct HeadingLayoutMetrics: Decodable {
    let headingClientWidth: CGFloat
    let headingScrollWidth: CGFloat
    let codeRight: CGFloat
    let viewportRight: CGFloat
    let boxDecorationBreak: String
}

private struct LongDocumentScrollMetrics: Decodable {
    let viewportHeight: CGFloat
    let documentHeight: CGFloat
    let scrollPosition: CGFloat
    let articleHeight: CGFloat
    let rowCount: Int
    let overflowY: String
    let bodyOverflowY: String
}

private struct ShellHighlightValues: Decodable {
    let options: [String]
    let commentOptions: [String]
    let metaOptions: [String]
    let html: String
}

private struct MermaidLayoutMetrics: Decodable {
    let articleWidth: CGFloat
    let articleLeft: CGFloat
    let figureWidth: CGFloat
    let figureLeft: CGFloat
    let availableWidth: CGFloat
    let svgWidth: CGFloat
    let expanded: Bool
    let buttonPressed: String
}
