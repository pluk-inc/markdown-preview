import XCTest
@testable import MarkdownHelpers

extension EditorPreviewLayoutTests {
    private func sample(_ name: String) throws -> String {
        try String(contentsOf: TestVendor.repositoryRoot.appendingPathComponent("tests/fixtures/layout/\(name).md"),
                   encoding: .utf8).replacingOccurrences(of: "{{IMAGE}}", with: image)
    }

    func testCompleteMixedFormattingDocument() async throws {
        try await check(Fixture(name: "mixed-common", markdown: sample("mixed-common"), texts: [
            "Mixed formatting document", "bold phrase", "italic phrase", "deleted phrase", "highlighted phrase",
            "inlineToken", "inline link", "Heading two", "Heading three", "Heading four", "Heading five",
            "Heading six", "Setext one", "Setext two", "A paragraph before lists.",
            "Parent bullet", "Nested bullet", "Deep bullet", "Another nested bullet", "bold list text",
            "Ordered parent", "Nested ordered item", "Second nested ordered item", "Final ordered item",
            "Quotation first paragraph", "quoted emphasis",
            "Quotation second paragraph.", "Nested quotation.", "After nested quotation.",
            "Before fenced code.", "struct LayoutExample", "greeting", "After fenced code.",
            "plainCodeLine", "secondPlainLine", "indentedCodeLine", "secondIndentedLine", "After indented code.",
            "Left heading", "Center heading", "Right heading", "Left cell", "Center cell", "123",
            "Longer cell that wraps at narrow widths", "Unicode café 日本語", "456", "After table.",
            "Before first mixed image.", "After first mixed image.", "After linked mixed image.", "After diagram.",
            "Unicode and direction", "English café, 日本語, emoji 🧪 and combining é.",
            "هذه فقرة عربية لاختبار اتجاه النص والمحاذاة.", "פסקה בעברית לבדיקת כיוון הטקסט.",
            "After multilingual paragraphs.", "literal star", "underscore", "First hard break.",
            "Second hard break.", "One soft line", "continues here.", "Before extra blank lines.",
            "After extra blank lines.", "Final mixed paragraph."
        ], imageCount: 2, readSelectors: ["table": 1, ".mermaid svg": 1],
           editorSelectors: [".cm-md-table-grid": 1, ".cm-md-mermaid-stage svg": 1],
           readBoxes: ["table-head": "thead tr", "table-last-row": "tbody tr:last-child", "diagram-box": ".mermaid-figure", "diagram-svg": ".mermaid svg", "rule-box": "hr"],
           editorBoxes: ["table-head": ".cm-md-table-grid tr:first-child", "table-last-row": ".cm-md-table-grid tr:last-child", "diagram-box": ".cm-md-mermaid-preview", "diagram-svg": ".cm-md-mermaid-stage svg", "rule-box": ".cm-md-hr"],
           height: 14000))
    }

    func testCompleteDocumentWithAllSupportedStyles() async throws {
        try await check(Fixture(name: "mixed-everything", markdown: sample("mixed-everything"), texts: [
            "Extended mixed document", "Mixed formatting document", "bold phrase", "italic phrase", "inlineToken",
            "Deep bullet", "Nested ordered item", "Nested quotation.", "greeting", "Left cell", "Center cell",
            "After first mixed image.", "After diagram.", "هذه فقرة عربية لاختبار اتجاه النص والمحاذاة.",
            "After extra blank lines.", "Final mixed paragraph.", "After equations.", "After alerts.",
            "After reference image.", "After raw HTML.", "Final extended paragraph."
        ], imageCount: 4, editorImageCount: 2,
           readSelectors: ["h1": 3, "h2": 4, "h3": 1, "h4": 1, "h5": 1, "h6": 1,
                           "table": 3, "input[type=checkbox]": 2, "input[type=checkbox]:checked": 1,
                           ".mermaid svg": 1, ".katex": 3, ".math-error": 0, ".mermaid-error": 0,
                           ".markdown-alert": 5, ".footnotes": 1, "details summary": 1, "hr": 2],
           editorSelectors: [".cm-md-table-grid": 2, ".cm-md-mermaid-stage svg": 1, ".cm-md-frontmatter": 6],
           editorSourceSnippets: ["[ ] Unchecked task", "[x] Completed task", "$x_1 + x_2$", "[!NOTE]", "[!TIP]",
                                  "[!IMPORTANT]", "[!WARNING]", "[!CAUTION]", "[reference link][destination]",
                                  "![Reference picture][picture]", "[^first]", "<details>", "**bold cell**"],
           sourceRepresentationReason: "The comprehensive file includes read-rendered features that intentionally remain source in the editor",
           localParityTexts: ["Mixed formatting document", "bold phrase", "italic phrase", "inlineToken",
                              "Deep bullet", "Nested ordered item", "greeting", "Left cell", "Center cell",
                              "After first mixed image.", "After diagram.", "After equations.", "After alerts.",
                              "After reference image.", "After raw HTML.", "Final extended paragraph."],
           height: 20000))
    }

    func testTOMLFrontmatterSourceRepresentation() async throws {
        try await check(Fixture(name: "toml-frontmatter", markdown: """
            +++
            title = "TOML title"
            draft = false
            +++

            # After TOML

            A paragraph with **TOML emphasis**.
            """, texts: ["After TOML", "TOML emphasis"],
            readSelectors: [".md-frontmatter": 1, "h1": 1, "strong": 1],
            editorSourceSnippets: ["title = \"TOML title\"", "draft = false"],
            sourceRepresentationReason: "TOML metadata renders as a read-mode card and stays editable source",
            localParityTexts: ["After TOML", "TOML emphasis"]))
    }

    func testMixedSourceOnlyFeaturesRenderAndPreserveSource() async throws {
        try await check(Fixture(name: "mixed-source-features", markdown: sample("mixed-source-features"), texts: [
            "Extended mixed document", "bold introduction", "After equations.", "Note body with", "Tip body.",
            "Important body.", "Warning body.", "Caution body.", "After alerts.", "After reference image.",
            "After raw HTML.", "Formatting", "Example", "Inline table styles", "Escaped pipe", "finalValue",
            "Final extended paragraph."
        ], imageCount: 2, editorImageCount: 0,
           readSelectors: [".katex": 3, ".math-error": 0, ".markdown-alert": 5, ".footnotes": 1,
                           "details summary": 1, "p[align=center] img": 1, "table": 2, "input[type=checkbox]": 2],
           editorSelectors: [".cm-md-frontmatter": 6, ".cm-md-table-grid": 1, ".katex": 0, "details": 0],
           editorSourceSnippets: ["[ ] Unchecked task", "[x] Completed task", "$x_1 + x_2$", "[!NOTE]", "[!TIP]", "[!IMPORTANT]", "[!WARNING]", "[!CAUTION]",
                                  "[reference link][destination]", "![Reference picture][picture]", "[^first]", "<details>", "**bold cell**"],
           sourceRepresentationReason: "Math, footnotes, alerts, reference syntax, HTML, and formatted table cells remain editable source",
           localParityTexts: ["Extended mixed document", "bold introduction", "After equations.", "After alerts.",
                              "After reference image.", "After raw HTML.", "Formatting", "Example", "finalValue",
                              "Final extended paragraph."], height: 14000))
    }
}

extension EditorPreviewLayoutTests {
    func testInlineFormattingAcrossTextNodes() async throws {
        try await check(Fixture(name: "inline-formatting", markdown: """
            Before inline formatting.

            Normal **strong words**, *emphasized words*, ~~removed words~~, ==marked words==, `inlineValue`, and [linked words](https://example.com) in one paragraph.

            After inline formatting.
            """, texts: ["Before inline formatting.", "Normal ", "strong words", "emphasized words", "removed words",
                           "marked words", "inlineValue", "linked words", "in one paragraph.", "After inline formatting."],
            styles: ["strong words": ["font-weight": "600"], "emphasized words": ["font-style": "italic"],
                     "removed words": ["text-decoration-line": "line-through"]]))
    }

    func testNestedAndLooseLists() async throws {
        try await check(Fixture(name: "nested-loose-lists", markdown: """
            Before nested lists.

            - Outer bullet
              - Inner bullet
                - Deepest bullet
              - Second inner bullet
            - Last outer bullet

            1. Outer number
               1. Inner number
               2. Second inner number
            2. Last outer number

            - Loose item one

              Continuation paragraph.

            - Loose item two

            After nested lists.
            """, texts: ["Before nested lists.", "Outer bullet", "Inner bullet", "Deepest bullet", "Second inner bullet",
                           "Last outer bullet", "Outer number", "Inner number", "Second inner number", "Last outer number",
                           "Loose item one", "Continuation paragraph.", "Loose item two", "After nested lists."]))
    }

    func testNestedQuotesAndParagraphs() async throws {
        try await check(Fixture(name: "nested-quotes", markdown: """
            Before nested quotes.

            > Outer quote.
            >
            > Second quote paragraph.
            > > Inner quote.

            After nested quotes.
            """, texts: ["Before nested quotes.", "Outer quote.", "Second quote paragraph.", "Inner quote.", "After nested quotes."]))
    }

    func testFencedUnlabelledAndIndentedCode() async throws {
        try await check(Fixture(name: "code-blocks", markdown: """
            Before code blocks.

            ```swift
            let exampleValue = 42
            print(exampleValue)
            ```

            Between code blocks.

            ```
            unlabelledExample
            secondExampleLine
            ```

                indentedExample
                anotherIndentedLine

            After code blocks.
            """, texts: ["Before code blocks.", "let exampleValue", "print", "Between code blocks.",
                           "unlabelledExample", "secondExampleLine", "indentedExample", "anotherIndentedLine", "After code blocks."],
                           readSelectors: ["pre": 3], editorSelectors: [".cm-md-code-language": 3]))
    }

    func testTableColumnsAndWrappedCells() async throws {
        try await check(Fixture(name: "table-layout", markdown: """
            Before table layout.

            | Left label | Center label | Right label |
            | :--- | :---: | ---: |
            | Alpha cell | Beta cell | 10 |
            | A much longer cell that wraps when the column gets narrow | 日本語 café | 200 |

            After table layout.
            """, texts: ["Before table layout.", "Left label", "Center label", "Right label", "Alpha cell", "Beta cell", "10",
                           "A much longer cell that wraps when the column gets narrow", "日本語 café", "200", "After table layout."],
                           readSelectors: ["table": 1, "th": 3, "td": 6],
                           editorSelectors: [".cm-md-table-grid": 1, "th": 3, "td": 6],
                           readBoxes: ["table-head": "thead tr", "table-last-row": "tbody tr:last-child"],
                           editorBoxes: ["table-head": ".cm-md-table-grid tr:first-child", "table-last-row": ".cm-md-table-grid tr:last-child"]))
    }

    func testMermaidWithRealBundledRenderer() async throws {
        try await check(Fixture(name: "mermaid-layout", markdown: """
            Before Mermaid diagram.

            ```mermaid
            flowchart LR
                A[Source] --> B[Preview]
            ```

            After Mermaid diagram.
            """, texts: ["Before Mermaid diagram.", "After Mermaid diagram."],
                           readSelectors: [".mermaid svg": 1, ".mermaid-error": 0],
                           editorSelectors: [".cm-md-mermaid-stage svg": 1, ".cm-md-mermaid-error": 0],
                           readBoxes: ["diagram-box": ".mermaid-figure", "diagram-svg": ".mermaid svg"],
                           editorBoxes: ["diagram-box": ".cm-md-mermaid-preview", "diagram-svg": ".cm-md-mermaid-stage svg"]))
    }

    func testUnicodeAndRightToLeftParagraphs() async throws {
        try await check(Fixture(name: "unicode-rtl", markdown: """
            Unicode café 日本語 🧪 é.

            هذه فقرة عربية لاختبار اتجاه النص والمحاذاة.

            פסקה בעברית לבדיקת כיוון הטקסט.

            After bidirectional text.
            """, texts: ["Unicode café 日本語 🧪 é.", "هذه فقرة عربية لاختبار اتجاه النص والمحاذاة.",
                           "פסקה בעברית לבדיקת כיוון הטקסט.", "After bidirectional text."]))
    }

    func testBlankLinesSoftBreaksHardBreaksAndRules() async throws {
        try await check(Fixture(name: "blank-lines-breaks-rules", markdown: """
            Before extra blanks.


            After extra blanks.

            A soft source line
            continues as a paragraph.

            A hard source line.\("  ")
            Continues below.

            ---

            After horizontal rule.
            """, texts: ["Before extra blanks.", "After extra blanks.", "A soft source line", "continues as a paragraph.",
                           "A hard source line.", "Continues below.", "After horizontal rule."],
                           readSelectors: ["hr": 1], editorSelectors: [".cm-md-hr": 1]))
    }
}
