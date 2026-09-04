import Foundation

/// Reserves space at the bottom-right of the preview so the floating copy
/// button never covers the document's own content.
///
/// The CSS is spliced into an already-rendered HTML document, which makes
/// *where* it goes the whole problem.
///
/// The document's real `</head>` cannot be located by string search. Vendor
/// bundles are inlined into the Quick Look page and carry `</head>` inside
/// JavaScript string literals on **both** sides of it: DOMPurify sits in
/// `<head>` and contains one before the real tag, Mermaid sits in `<body>`
/// and contains one after it. So neither the first nor the last occurrence
/// is dependably the document's own.
///
/// Splicing at the last occurrence is what this used to do. With no diagram
/// on the page the last `</head>` really was the document's and the result
/// looked correct, which is why the bug stayed hidden. Add one Mermaid
/// diagram and its bundle lands in `<body>`, past the real tag, so the CSS
/// was inserted into Mermaid's bundled copy of DOMPurify, in the middle of
/// this single-quoted string:
///
/// ```js
/// Ie = '<html xmlns="..."><head></head><body>' + Ie + "</body></html>"
/// ```
///
/// A single-quoted JavaScript string cannot span newlines, so the multi-line
/// CSS ended the literal mid-line and the parser ran to the end of the file
/// looking for a closing quote: `SyntaxError: Unexpected EOF`. That killed
/// the whole 3 MB bundle before its first statement, so no diagram rendered
/// in Quick Look — and the clearance CSS never reached the document either,
/// so the button had no clearance. One splice, two silent failures.
///
/// The *opening* `<head>` has no such ambiguity: it is the first one in the
/// document, ahead of any script. Inserting there places this rule before
/// the main stylesheet rather than after it, so the selector is `html body`
/// — specificity high enough to win regardless of cascade position.
enum CopyButtonClearance {

    /// Returns `html` with the clearance rule inserted, or unchanged when the
    /// document has no `<head>` to insert into.
    static func applying(to html: String, horizontal: Int, vertical: Int) -> String {
        guard let headStart = html.range(of: "<head>") else { return html }
        let style = """

        <style>
        html body {
            padding-right: calc(\(horizontal)px + env(safe-area-inset-right));
            padding-bottom: calc(\(vertical)px + env(safe-area-inset-bottom));
        }
        </style>
        """
        var result = html
        result.insert(contentsOf: style, at: headStart.upperBound)
        return result
    }
}
