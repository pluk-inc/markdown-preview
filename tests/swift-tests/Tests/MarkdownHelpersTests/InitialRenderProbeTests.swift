import Foundation
import XCTest
@testable import MarkdownHelpers

/// Manual scaling probe used while tuning the app's first document render.
/// Run in Release so Swift's optimizer matches the distributed app:
///
///     RUN_INITIAL_RENDER_PROBE=1 swift test -c release --package-path tests/swift-tests \
///       --filter InitialRenderProbeTests/testRenderScaling
final class InitialRenderProbeTests: XCTestCase {
    func testRenderScaling() throws {
        guard ProcessInfo.processInfo.environment["RUN_INITIAL_RENDER_PROBE"] == "1" else {
            throw XCTSkip("Set RUN_INITIAL_RENDER_PROBE=1 to run the manual scaling benchmark")
        }
        _ = MarkdownHTML.render(markdown: "warmup", vendorLoading: .lazy)

        let cases = [
            ("prose-100k", makeDocument(targetBytes: 100_000, block: proseBlock)),
            ("prose-500k", makeDocument(targetBytes: 500_000, block: proseBlock)),
            ("prose-1m", makeDocument(targetBytes: 1_000_000, block: proseBlock)),
            ("headings-500k", makeDocument(targetBytes: 500_000, block: headingBlock)),
            ("code-500k", makeDocument(targetBytes: 500_000, block: codeBlock)),
            ("mixed-500k", makeDocument(targetBytes: 500_000, block: mixedBlock)),
        ]

        for (name, markdown) in cases {
            var samples: [Double] = []
            var outputBytes = 0
            for _ in 0..<3 {
                let start = ContinuousClock.now
                let rendered = MarkdownHTML.render(markdown: markdown, vendorLoading: .lazy)
                samples.append(milliseconds(since: start))
                outputBytes = rendered.articleHTML.utf8.count
            }
            let mean = samples.reduce(0, +) / Double(samples.count)
            print(
                "INITIAL_RENDER_PROBE name=\(name)"
                    + " input_bytes=\(markdown.utf8.count)"
                    + " output_bytes=\(outputBytes)"
                    + " mean_ms=\(String(format: "%.1f", mean))"
                    + " samples_ms=\(samples.map { String(format: "%.1f", $0) }.joined(separator: ","))"
            )
        }
    }

    private func makeDocument(targetBytes: Int, block: String) -> String {
        let count = max(1, targetBytes / block.utf8.count)
        return String(repeating: block, count: count)
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        return Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private var proseBlock: String {
        """
        ## A representative section

        Markdown Preview should show useful text quickly, even when a document contains
        many paragraphs, **emphasis**, [links](https://example.com), and ordinary lists.

        - First item with enough prose to wrap across a normal preview column.
        - Second item with `inline code` and a little more explanatory text.
        - Third item that keeps the source structurally realistic.

        """
    }

    private var headingBlock: String {
        """
        ## Section heading

        A short paragraph under the section.

        ### Nested heading

        Another short paragraph with [a link](https://example.com).

        """
    }

    private var codeBlock: String {
        """
        ## Code example

        ```swift
        struct Record {
            let identifier: Int
            let title: String
        }

        let records = (0..<100).map { Record(identifier: $0, title: "Item \\($0)") }
        ```

        A paragraph after the code block.

        """
    }

    private var mixedBlock: String {
        """
        ## Mixed content

        A paragraph with inline math $x^2 + y^2$, a footnote reference[^note], and `code`.

        | Name | Value | Notes |
        | --- | ---: | --- |
        | Alpha | 42 | A representative row |
        | Beta | 84 | Another representative row |

        > [!NOTE]
        > Large files can combine several Markdown features.

        [^note]: A compact footnote definition.

        """
    }
}
