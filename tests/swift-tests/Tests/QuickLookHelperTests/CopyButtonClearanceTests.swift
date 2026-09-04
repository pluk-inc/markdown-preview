import XCTest
@testable import QuickLookHelpers

/// Guards where the copy-button clearance CSS is spliced into the preview.
///
/// **What a failure here means:** the CSS is being inserted at the wrong
/// place. The dangerous form is insertion *inside an inlined vendor script*,
/// which corrupts that script's JavaScript. When it happened to Mermaid the
/// whole bundle died with `SyntaxError: Unexpected EOF` and no diagram
/// rendered in Quick Look — with no visible console error, because the
/// preview page's opaque origin mutes script errors to a bare
/// "Script error.".
///
/// `testVendorScriptContentIsNeverModified` is the important one: if it
/// fails, expect diagrams to silently stop rendering in Quick Look.
final class CopyButtonClearanceTests: XCTestCase {

    // A page shaped like the real Quick Look output: a vendor bundle inlined
    // in <head> carrying `</head>` as data (DOMPurify), and another inlined
    // in <body> doing the same (Mermaid). Both are single-quoted JavaScript
    // strings and must survive byte-for-byte.
    private let purifyLiteral =
        #"Ie='<html xmlns="http://www.w3.org/1999/xhtml"><head></head><body>'+Ie+"</body></html>";"#

    private func page() -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <script>\(purifyLiteral)</script>
        <style>body { margin: 0; }</style>
        </head>
        <body>
        <article></article>
        <script>\(purifyLiteral)</script>
        </body>
        </html>
        """
    }

    /// Every `<script>…</script>` body, so a test can assert none were touched.
    private func scriptBodies(_ html: String) -> [String] {
        var bodies: [String] = []
        var rest = Substring(html)
        while let open = rest.range(of: "<script>"),
              let close = rest.range(of: "</script>", range: open.upperBound..<rest.endIndex) {
            bodies.append(String(rest[open.upperBound..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return bodies
    }

    // MARK: - The regression

    func testVendorScriptContentIsNeverModified() {
        let input = page()
        let output = CopyButtonClearance.applying(to: input, horizontal: 90, vertical: 44)

        XCTAssertEqual(
            scriptBodies(output),
            scriptBodies(input),
            """
            Clearance CSS was spliced into an inlined vendor script. In Quick \
            Look this corrupts the Mermaid bundle's single-quoted DOMPurify \
            string, which cannot span newlines — the script dies with \
            SyntaxError: Unexpected EOF and diagrams stop rendering.
            """
        )
    }

    func testDOMPurifyLiteralSurvivesIntact() {
        let output = CopyButtonClearance.applying(to: page(), horizontal: 90, vertical: 44)
        XCTAssertEqual(
            output.components(separatedBy: purifyLiteral).count - 1, 2,
            "Both inlined copies of the DOMPurify literal should be byte-identical after the splice."
        )
    }

    // MARK: - Correct placement

    func testStyleIsInsertedIntoTheDocumentHead() {
        let output = CopyButtonClearance.applying(to: page(), horizontal: 90, vertical: 44)
        let headOpen = output.range(of: "<head>")!
        let headClose = output.range(of: "</head>", range: headOpen.upperBound..<output.endIndex)!
        let styleRange = output.range(of: "html body {")

        XCTAssertNotNil(styleRange, "Clearance CSS was not emitted at all.")
        XCTAssertTrue(
            styleRange!.lowerBound > headOpen.upperBound && styleRange!.upperBound < headClose.lowerBound,
            "Clearance CSS must sit inside the document's own <head>."
        )
    }

    func testClearanceValuesAreCarriedThrough() {
        let output = CopyButtonClearance.applying(to: page(), horizontal: 90, vertical: 44)
        XCTAssertTrue(output.contains("padding-right: calc(90px + env(safe-area-inset-right));"))
        XCTAssertTrue(output.contains("padding-bottom: calc(44px + env(safe-area-inset-bottom));"))
    }

    /// `html body` outranks the stylesheet's own `body` rules, which matters
    /// because this rule is now emitted *before* that stylesheet.
    func testSelectorOutranksPlainBodyRules() {
        let output = CopyButtonClearance.applying(to: page(), horizontal: 90, vertical: 44)
        XCTAssertTrue(
            output.contains("html body {"),
            """
            Selector must stay `html body`. It is inserted ahead of the main \
            stylesheet, so a bare `body` selector would lose the cascade and \
            the button would overlap content.
            """
        )
    }

    // MARK: - Degenerate input

    func testDocumentWithoutHeadIsReturnedUnchanged() {
        let html = "<html><body><p>no head here</p></body></html>"
        XCTAssertEqual(
            CopyButtonClearance.applying(to: html, horizontal: 90, vertical: 44),
            html,
            "With nowhere safe to insert, the document must be returned untouched rather than guessed at."
        )
    }
}
