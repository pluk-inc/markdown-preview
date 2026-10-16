import WebKit
import XCTest
@testable import MarkdownHelpers

@MainActor
final class ConflictDiffTests: XCTestCase {
    func testComparisonShowsBothSourcesWithoutRenderingDocumentHTML() async throws {
        let disk = "---\ntitle: 磁盘\n---\n\n# Plan\nAgent changed this.\n"
        let draft = "---\ntitle: 草稿\n---\n\n# Plan\nHuman changed this.\n</script><script>window.injected = true</script>\n"
        let page = try await comparison(disk: disk, draft: draft)
        defer { page.close() }
        let result = try await page.webView.callAsyncJavaScript("""
            const view = window.__conflictDiff;
            return {disk: view.a.state.doc.toString(), draft: view.b.state.doc.toString(),
                changes: view.chunks.length,
                changedLines: document.querySelectorAll('.cm-changedLine').length,
                editable: [...document.querySelectorAll('[contenteditable=true]')].length,
                injected: window.injected === true,
                labels: [...document.querySelectorAll('.cm-content')].map(e => e.getAttribute('aria-label'))};
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["disk"] as? String, disk)
        XCTAssertEqual(values["draft"] as? String, draft)
        XCTAssertGreaterThan(values["changes"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(values["changedLines"] as? Int ?? 0, 0)
        XCTAssertEqual(values["editable"] as? Int, 0)
        XCTAssertEqual(values["injected"] as? Bool, false)
        XCTAssertEqual((values["labels"] as? [String])?.count, 2)
    }

    func testNavigationReachesDistantChangesAndKeepsBothSnapshots() async throws {
        let disk = (0..<200).map { "Unchanged line \($0)" }.joined(separator: "\n")
        let draft = disk.replacingOccurrences(of: "line 3\n", with: "line 3: human\n")
            .replacingOccurrences(of: "line 180\n", with: "line 180: human\n")
        let page = try await comparison(disk: disk, draft: draft)
        defer { page.close() }
        let result = try await page.webView.callAsyncJavaScript("""
            const initial = window.__conflictPosition;
            const position = MDConflictNavigate(1);
            for (let i = 0; i < 5; i++) window.__layoutTestFrame();
            const view = window.__conflictDiff;
            const target = view.a.coordsAtPos(view.a.state.doc.line(181).from);
            const bounds = view.dom.getBoundingClientRect();
            return {targetVisible: target.top >= bounds.top && target.top < bounds.bottom,
                collapsed: document.querySelectorAll('.cm-collapsedLines').length,
                initial, position,
                changes: view.chunks.length, disk: view.a.state.doc.toString(), draft: view.b.state.doc.toString()};
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["changes"] as? Int, 2)
        XCTAssertEqual(values["targetVisible"] as? Bool, true)
        XCTAssertGreaterThan(values["collapsed"] as? Int ?? 0, 0)
        XCTAssertEqual(values["initial"] as? [Int], [1, 2])
        XCTAssertEqual(values["position"] as? [Int], [2, 2])
        XCTAssertEqual(values["disk"] as? String, disk)
        XCTAssertEqual(values["draft"] as? String, draft)
    }

    func testLongDeletionNavigationShowsItsStartInsteadOfTheFollowingLine() async throws {
        let disk = "# Title\n" + (0..<100).map { "Removed line \($0)\n" }.joined() + "Unchanged ending\n"
        let page = try await comparison(disk: disk, draft: "# Title\nUnchanged ending\n")
        defer { page.close() }
        let result = try await page.webView.callAsyncJavaScript("""
            const view = window.__conflictDiff;
            const first = view.a.coordsAtPos(view.chunks[0].fromA);
            const bounds = view.dom.getBoundingClientRect();
            return first.top >= bounds.top && first.top < bounds.bottom;
            """, arguments: [:], in: nil, contentWorld: .page)
        XCTAssertEqual(result as? Bool, true)
    }

    func testCollapsedSourceExpandsOnClickAndKeyboardCopyRetainsMixedLineEndings() async throws {
        let disk = (0..<100).map { "Line \($0)" + ($0.isMultiple(of: 2) ? "\r\n" : "\n") }.joined()
        let page = try await comparison(disk: disk, draft: disk.replacingOccurrences(of: "Line 50", with: "Edited line 50"))
        defer { page.close() }
        let result = try await page.webView.callAsyncJavaScript("""
            const view = window.__conflictDiff.a;
            const key = (key, extra = {}) => view.contentDOM.dispatchEvent(
                new KeyboardEvent('keydown', {key, bubbles: true, cancelable: true, ...extra}));
            const initialCollapsed = document.querySelectorAll('.cm-collapsedLines').length;
            key('a', {metaKey: true});
            const selectedAll = view.state.selection.main.from === 0 && view.state.selection.main.to === view.state.doc.length;
            let copied;
            const copy = new Event('copy', {bubbles: true, cancelable: true});
            Object.defineProperty(copy, 'clipboardData', {value: {setData: (type, value) => { if (type === 'text/plain') copied = value; }}});
            view.contentDOM.dispatchEvent(copy);
            key('Backspace'); key('Enter');
            const unchanged = view.state.doc.toString();
            key('ArrowLeft'); key('ArrowRight', {shiftKey: true});
            const selectedCharacter = view.state.sliceDoc(view.state.selection.main.from, view.state.selection.main.to);
            const collapsed = document.querySelectorAll('.cm-collapsedLines');
            collapsed[0].click();
            for (let i = 0; i < 5; i++) window.__layoutTestFrame();
            const expandedOne = document.querySelectorAll('.cm-collapsedLines').length < collapsed.length;
            return {initialCollapsed, selectedAll, copied, unchanged, selectedCharacter, expandedOne};
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertGreaterThan(values["initialCollapsed"] as? Int ?? 0, 0)
        XCTAssertEqual(values["selectedAll"] as? Bool, true)
        XCTAssertEqual(values["copied"] as? String, disk)
        XCTAssertEqual(values["unchanged"] as? String, disk.replacingOccurrences(of: "\r\n", with: "\n"))
        XCTAssertEqual(values["selectedCharacter"] as? String, "L")
        XCTAssertEqual(values["expandedOne"] as? Bool, true)
    }

    func testShowWholeFileRevealsBothSnapshotsWithoutChangingSelectionOrNavigation() async throws {
        let disk = (0..<200).map { "Line \($0)" }.joined(separator: "\n")
        let draft = disk.replacingOccurrences(of: "Line 50\n", with: "Edited 50\n")
            .replacingOccurrences(of: "Line 150\n", with: "Edited 150\n")
        let page = try await comparison(disk: disk, draft: draft)
        defer { page.close() }
        let result = try await page.webView.callAsyncJavaScript("""
            const merge = window.__conflictDiff;
            const collapsedBefore = document.querySelectorAll('.cm-collapsedLines').length;
            merge.a.dispatch({selection: {anchor: 2, head: 5}});
            MDConflictShowWholeFile();
            MDConflictShowWholeFile();
            for (let i = 0; i < 5; i++) window.__layoutTestFrame();
            return {collapsedBefore, collapsedAfter: document.querySelectorAll('.cm-collapsedLines').length,
                selection: [merge.a.state.selection.main.from, merge.a.state.selection.main.to],
                disk: merge.a.state.doc.toString(), draft: merge.b.state.doc.toString(),
                next: MDConflictNavigate(1)};
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertGreaterThan(values["collapsedBefore"] as? Int ?? 0, 0)
        XCTAssertEqual(values["collapsedAfter"] as? Int, 0)
        XCTAssertEqual(values["selection"] as? [Int], [2, 5])
        XCTAssertEqual(values["disk"] as? String, disk)
        XCTAssertEqual(values["draft"] as? String, draft)
        XCTAssertEqual(values["next"] as? [Int], [2, 2])
    }

    func testLineEndingOnlyConflictIsExplained() async throws {
        let page = try await comparison(disk: "a\r\nb\r\n", draft: "a\nb\n")
        defer { page.close() }
        let result = try await page.webView.callAsyncJavaScript("""
            return {changes: window.__conflictDiff.chunks.length, position: window.__conflictPosition};
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["changes"] as? Int, 0)
        XCTAssertEqual(values["position"] as? [Int], [0, 0])
        XCTAssertEqual(ConflictDiffHTML.lineEndingNote(disk: "a\r\nb\r\n", draft: "a\nb\n"),
                       "Line endings differ. On disk: CRLF; draft: LF.")
        XCTAssertEqual(ConflictDiffHTML.lineEndingNote(disk: "a\r\nb\n", draft: "a\nb\r\n"),
                       "Line endings differ. On disk: CRLF / LF; draft: CRLF / LF.")
        XCTAssertEqual(ConflictDiffHTML.lineEndingNote(disk: "a", draft: "b\r"),
                       "Line endings differ. On disk: None; draft: CR.")
        XCTAssertNil(ConflictDiffHTML.lineEndingNote(disk: "a\nb\n", draft: "a\nc\n"))
    }

    func testComparisonUsesTheDocumentTypeAndHighlightColor() async throws {
        let page = try await comparison(disk: "Disk value\n", draft: "Draft value\n")
        defer { page.close() }
        let result = try await page.webView.callAsyncJavaScript("""
            const word = document.querySelector('.cm-changedText');
            const scroller = document.querySelector('.cm-scroller');
            return {highlight: getComputedStyle(word).backgroundColor,
                underline: getComputedStyle(word).backgroundImage,
                font: getComputedStyle(scroller).fontFamily,
                lineNumbers: document.querySelectorAll('.cm-lineNumbers').length,
                controls: document.querySelectorAll('button, output').length};
            """, arguments: [:], in: nil, contentWorld: .page)
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["highlight"] as? String, "rgba(255, 216, 77, 0.55)")
        XCTAssertEqual(values["underline"] as? String, "none")
        XCTAssertFalse((values["font"] as? String ?? "monospace").contains("mono"))
        XCTAssertEqual(values["lineNumbers"] as? Int, 0)
        XCTAssertEqual(values["controls"] as? Int, 0)
    }

    private func comparison(disk: String, draft: String) async throws -> WebViewLayoutHarness {
        let script = try TestVendor.script("md-preview/Vendor/CodeMirror/mdconflict.min.js")
        let page = WebViewLayoutHarness(
            html: ConflictDiffHTML.render(disk: disk, draft: draft, javaScript: script),
            width: 820, isEditor: false, height: 420)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if !page.webView.isLoading,
               (try? await page.webView.evaluateJavaScript("window.__conflictReady === true")) as? Bool == true {
                _ = try await page.webView.evaluateJavaScript("for (let i = 0; i < 5; i++) window.__layoutTestFrame()")
                return page
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        page.close()
        throw NSError(domain: "ConflictDiffTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Conflict comparison did not load"])
    }
}
