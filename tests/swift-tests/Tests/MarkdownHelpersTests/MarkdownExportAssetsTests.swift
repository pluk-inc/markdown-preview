import XCTest

@testable import MarkdownHelpers

final class MarkdownExportAssetsTests: XCTestCase {

    // MARK: - Stylesheet (T9: prefix-tolerant, message args)

    func testStylesheetHidesInteractiveChrome() {
        let css = MarkdownExportAssets.stylesheet
        XCTAssertTrue(
            css.contains(".md-code-copy"),
            "export CSS should hide the code copy button"
        )
        XCTAssertTrue(
            css.contains(".mermaid-hud"),
            "export CSS should hide the mermaid zoom HUD"
        )
        XCTAssertTrue(
            css.contains("md-search-highlight"),
            "export CSS should neutralize search highlights"
        )
    }

    func testStylesheetSetsPageAndColorAdjust() {
        let css = MarkdownExportAssets.stylesheet
        XCTAssertTrue(css.contains("@page"), "export CSS should set @page margins")
        XCTAssertTrue(
            css.range(of: #"(-webkit-)?print-color-adjust:\s*exact"#, options: .regularExpression) != nil,
            "export CSS should force exact color adjustment when printing"
        )
        XCTAssertTrue(
            css.contains("break-inside: avoid"),
            "export CSS should avoid breaks inside code blocks and diagrams"
        )
    }

    // MARK: - readinessScript (T2: all 8 permutations)

    func testReadinessScriptAllRendererFlagPermutations() {
        for math in [false, true] {
            for mermaid in [false, true] {
                for code in [false, true] {
                    let script = MarkdownExportAssets.readinessScript(
                        containsMath: math,
                        containsMermaid: mermaid,
                        containsCode: code
                    )
                    XCTAssertTrue(
                        script.contains("expectMath = \(math ? "true" : "false")"),
                        "math=\(math) mermaid=\(mermaid) code=\(code)"
                    )
                    XCTAssertTrue(
                        script.contains("expectMermaid = \(mermaid ? "true" : "false")"),
                        "math=\(math) mermaid=\(mermaid) code=\(code)"
                    )
                    XCTAssertTrue(
                        script.contains("expectCode = \(code ? "true" : "false")"),
                        "math=\(math) mermaid=\(mermaid) code=\(code)"
                    )
                    XCTAssertTrue(
                        script.contains("renderComplete"),
                        "math=\(math) mermaid=\(mermaid) code=\(code)"
                    )
                }
            }
        }
    }

    func testReadinessScriptChecksRendererDoneMarkers() {
        let all = MarkdownExportAssets.readinessScript(
            containsMath: true, containsMermaid: true, containsCode: true)
        XCTAssertTrue(
            all.contains("data-math-done"),
            "readiness should wait on KaTeX data-math-done"
        )
        XCTAssertTrue(
            all.contains("data-hljs-done"),
            "readiness should wait on hljs data-hljs-done"
        )
        XCTAssertTrue(
            all.contains("mmDone"),
            "readiness should wait on Mermaid dataset.mmDone"
        )
    }

    func testReadinessScriptIsEventDrivenWithPollFallback() {
        let script = MarkdownExportAssets.readinessScript(
            containsMath: true, containsMermaid: true, containsCode: true)
        XCTAssertTrue(
            script.contains("md-preview-math-rendered"),
            "readiness should listen for math-rendered"
        )
        XCTAssertTrue(
            script.contains("md-preview-mermaid-rendered"),
            "readiness should listen for mermaid-rendered"
        )
        XCTAssertTrue(
            script.contains("md-preview-hljs-rendered"),
            "readiness should listen for hljs-rendered"
        )
        XCTAssertTrue(
            script.contains("setTimeout(check, 50)"),
            "readiness should keep a 50ms poll as a safety net"
        )
    }

    // MARK: - headInjection (T5, T6)

    func testHeadInjectionSetsEagerRenderFlagForAllCombinations() {
        for math in [false, true] {
            for mermaid in [false, true] {
                for code in [false, true] {
                    let head = MarkdownExportAssets.headInjection(
                        containsMath: math,
                        containsMermaid: mermaid,
                        containsCode: code
                    )
                    XCTAssertTrue(
                        head.contains("__mdPreviewRenderAll = true"),
                        "math=\(math) mermaid=\(mermaid) code=\(code)"
                    )
                }
            }
        }
    }

    func testHeadInjectionFlagPrecedesReadinessScript() {
        let head = MarkdownExportAssets.headInjection(
            containsMath: true, containsMermaid: true, containsCode: true)
        guard let flagRange = head.range(of: "__mdPreviewRenderAll = true"),
              let readyRange = head.range(of: "expectMath = true") else {
            XCTFail("headInjection should contain both the eager flag and readiness script")
            return
        }
        XCTAssertTrue(
            flagRange.lowerBound < readyRange.lowerBound,
            "__mdPreviewRenderAll must be set before the readiness script runs"
        )
    }

    func testHeadInjectionIncludesExportStylesheet() {
        let head = MarkdownExportAssets.headInjection(
            containsMath: false, containsMermaid: true, containsCode: false)
        XCTAssertTrue(head.contains("<style>"), "headInjection should include export CSS")
        XCTAssertTrue(
            head.contains(".md-code-copy"),
            "headInjection should embed the export stylesheet"
        )
        XCTAssertTrue(
            head.contains("renderComplete"),
            "headInjection should include the readiness script"
        )
    }

    // MARK: - Renderer JS contracts (T1, T7)

    func testHighlightAllBodyHasOffscreenSafePath() {
        let body = MarkdownExportAssets.highlightAllBody
        XCTAssertTrue(
            body.contains("__mdPreviewRenderAll"),
            "highlight.js must gate an export-only path on __mdPreviewRenderAll"
        )
        guard let renderAllRange = body.range(of: "__mdPreviewRenderAll"),
              let syncRange = body.range(of: "hljs.highlightElement"),
              let rafRange = body.range(of: "requestAnimationFrame") else {
            XCTFail("highlightAllBody missing export gate, sync highlight, or rAF loop")
            return
        }
        XCTAssertTrue(
            renderAllRange.lowerBound < syncRange.lowerBound
                && syncRange.lowerBound < rafRange.lowerBound,
            "synchronous hljs.highlightElement must run before requestAnimationFrame in the export branch"
        )
    }

    func testMermaidInitWiringHasOffscreenSafePath() {
        let wiring = MarkdownExportAssets.mermaidInitWiring
        XCTAssertTrue(
            wiring.contains("__mdPreviewRenderAll"),
            "Mermaid bootstrap must check __mdPreviewRenderAll"
        )
        guard let gateRange = wiring.range(of: "__mdPreviewRenderAll"),
              let drainRange = wiring.range(of: "drain();") else {
            XCTFail("mermaidInitWiring missing export gate or drain() call")
            return
        }
        XCTAssertTrue(
            gateRange.lowerBound < drainRange.lowerBound,
            "export branch must call drain() after __mdPreviewRenderAll"
        )
    }
}
