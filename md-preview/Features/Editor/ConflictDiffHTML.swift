import Foundation

/// The text-only half of the save-conflict comparison. The sheet's title,
/// column headings, change navigation and buttons are native controls in
/// SaveConflictSheet; this page only shows the two sources, in the same type
/// and highlight color as the editor and preview.
nonisolated enum ConflictDiffHTML {
    static func render(disk: String, draft: String, javaScript: String) -> String {
        let labels = [
            "disk": NSLocalizedString("On Disk", comment: "Save conflict comparison heading"),
            "draft": NSLocalizedString("Your Draft", comment: "Save conflict comparison heading"),
            "unchanged": NSLocalizedString("$ unchanged lines", comment: "$ is replaced by CodeMirror with the number of collapsed lines"),
        ]
        let labelsJSON = labels.sorted { $0.key < $1.key }.map {
            "\(EditorHTML.jsStringLiteral($0.key)):\(EditorHTML.jsStringLiteral($0.value))"
        }.joined(separator: ",")
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'">
        <style>
        /* Palette mirrors EditorHTML and MarkdownHTML.stylesheet: semantic
           system colors, and the preview's ==highlight== color for changes. */
        :root { color-scheme: light dark; --text: -apple-system-label;
            --secondary: -apple-system-secondary-label; --grid: -apple-system-separator;
            --code-bg: #f9f9f9; --highlight: rgba(255, 216, 77, 0.55);
            --changed-line: rgba(255, 216, 77, 0.12); --changed-edge: #ffbf00; }
        @media (prefers-color-scheme: dark) {
            :root { --code-bg: #262626; --changed-line: rgba(255, 216, 77, 0.08); }
        }
        @media (prefers-contrast: more) {
            :root { --grid: -apple-system-label; }
            #comparison .cm-changedText { outline: 1px solid var(--changed-edge); }
        }
        * { box-sizing: border-box; }
        html, body { margin: 0; height: 100%; overflow: hidden; }
        body { font-family: \(MarkdownHTML.bodyFontFamily); color: var(--text);
            background: -apple-system-text-background; border: 1px solid var(--grid);
            -webkit-font-smoothing: antialiased; }
        #comparison, .cm-mergeView { height: 100%; }
        /* Keep the divider between the panes full height for short files. */
        #comparison .cm-mergeViewEditors { min-height: 100%; }
        .cm-mergeViewEditor { min-width: 0; }
        .cm-mergeViewEditor + .cm-mergeViewEditor { border-left: 1px solid var(--grid); }
        #comparison .cm-editor { font-size: \(MarkdownHTML.bodyFontSize)px; }
        #comparison .cm-scroller { font-family: inherit; line-height: \(MarkdownHTML.bodyLineHeight); }
        #comparison .cm-gutters { border: 0; background: transparent; }
        #comparison .cm-line { padding: 0 14px 0 10px; }
        #comparison .cm-changedLine { background: var(--changed-line); }
        #comparison .cm-changedText { background: var(--highlight); color: inherit;
            box-decoration-break: clone; -webkit-box-decoration-break: clone; }
        #comparison .cm-changedLineGutter { background: var(--changed-edge); }
        #comparison .cm-collapsedLines { padding: 4px 0; text-align: center; color: var(--secondary);
            background: var(--code-bg); font: 12px/18px \(MarkdownHTML.bodyFontFamily); }
        #comparison .cm-collapsedLines::before, #comparison .cm-collapsedLines::after { content: none; }
        /* WebKit's auto outline is the system focus ring. */
        #comparison .cm-editor.cm-focused { outline: -webkit-focus-ring-color auto 4px; outline-offset: -4px; }
        #comparison .cm-selectionBackground { background: color-mix(in srgb, Highlight 30%, transparent); }
        </style></head><body>
        <div id="comparison"></div>
        <script>\(javaScript)</script>
        <script>MDConflictDiff(\(EditorHTML.jsStringLiteral(disk)),
            \(EditorHTML.jsStringLiteral(draft)), {\(labelsJSON)});</script>
        </body></html>
        """
    }

    /// Explains a conflict CodeMirror cannot show, because it compares
    /// normalized lines. Nil when both sources use the same line endings.
    static func lineEndingNote(disk: String, draft: String) -> String? {
        let normalized = { (source: String) in
            source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        let endings = lineEndings(in: disk), draftEndings = lineEndings(in: draft)
        guard endings != draftEndings || (disk != draft && normalized(disk) == normalized(draft)) else {
            return nil
        }
        return String(format: NSLocalizedString("Line endings differ. On disk: %1$@; draft: %2$@.",
                                                comment: "Line ending names"),
                      endings, draftEndings)
    }

    private static func lineEndings(in source: String) -> String {
        var names = Set<String>()
        for scalar in source.unicodeScalars.indices {
            switch source.unicodeScalars[scalar] {
            case "\r":
                let next = source.unicodeScalars.index(after: scalar)
                names.insert(next < source.unicodeScalars.endIndex && source.unicodeScalars[next] == "\n" ? "CRLF" : "CR")
            case "\n":
                if scalar == source.unicodeScalars.startIndex
                    || source.unicodeScalars[source.unicodeScalars.index(before: scalar)] != "\r" {
                    names.insert("LF")
                }
            default:
                continue
            }
        }
        return names.isEmpty
            ? NSLocalizedString("None", comment: "No line ending characters")
            : names.sorted().joined(separator: " / ")
    }
}
