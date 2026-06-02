//
//  PDFExporterIntegrationTests.swift
//  md-previewTests
//

import PDFKit
import XCTest
@testable import Markdown_Preview

final class PDFExporterIntegrationTests: XCTestCase {

    /// Short integration fixtures produce sub-1KB PDFs; keep a low floor to catch blank exports.
    private static let minimumPDFBytes = 512
    private static let maximumPDFBytes = 5_000_000
    private static let runawayDeletionThreshold = 50_000_000
    private static let exportTimeout: TimeInterval = 120

    @MainActor
    func testProseDocumentExport() async throws {
        // Unique marker so the content assertion can't be satisfied by chrome.
        let marker = "ProseMarkerZX42"
        let markdown = """
        # Integration prose \(marker)

        Paragraph with enough body text that the rendered PDF is not a trivial blank page.
        Second paragraph to add vertical extent for pagination smoke coverage.
        """
        try await assertExportSucceeds(markdown: markdown, label: "prose", expectedText: [marker])
    }

    @MainActor
    func testCodeFenceDocumentExport() async throws {
        let marker = "CodeMarkerZX42"
        let markdown = """
        # Code sample \(marker)

        ```swift
        struct Widget {
            var title: String
            func render() -> String {
                (0..<20).map { "\\($0): \\(title)" }.joined(separator: "\\n")
            }
        }
        ```
        """
        try await assertExportSucceeds(markdown: markdown, label: "code-fence",
                                       expectedText: [marker, "Widget"])
    }

    // MARK: - Helpers

    @MainActor
    private func assertExportSucceeds(markdown: String,
                                      label: String,
                                      expectedText: [String]) async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-preview-export-\(label)-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }

        let url = try await exportPDF(markdown: markdown, destination: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as? Int ?? 0

        if size > Self.runawayDeletionThreshold {
            try? FileManager.default.removeItem(at: destination)
            XCTFail("PDF runaway (\(size) bytes) for \(label); deleted to avoid filling disk")
            return
        }

        XCTContext.runActivity(named: "PDF size (\(label))") { _ in
            print("md-preview export [\(label)]: \(size) bytes → \(url.lastPathComponent)")
        }

        XCTAssertGreaterThan(
            size,
            Self.minimumPDFBytes,
            "PDF too small (\(size) bytes) for \(label); render likely stalled or blank"
        )
        XCTAssertLessThan(
            size,
            Self.maximumPDFBytes,
            "PDF unexpectedly large (\(size) bytes) for \(label); export pipeline likely runaway"
        )

        // Content assertion — the real guard against blank pages. A non-empty
        // file size alone is satisfied by a blank PDF (~800 bytes), so extract
        // the actual text and require the document's own content to be present.
        let pdf = try XCTUnwrap(PDFDocument(url: url), "Produced file is not a valid PDF for \(label)")
        XCTAssertGreaterThan(pdf.pageCount, 0, "PDF has no pages for \(label)")
        let text = (0..<pdf.pageCount)
            .compactMap { pdf.page(at: $0)?.string }
            .joined(separator: "\n")
        for needle in expectedText {
            XCTAssertTrue(
                text.contains(needle),
                "Exported PDF for \(label) is missing expected content '\(needle)' — likely blank/unrendered. Extracted length: \(text.count)"
            )
        }
    }

    @MainActor
    private func exportPDF(markdown: String, destination: URL) async throws -> URL {
        try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await Self.performExport(markdown: markdown, destination: destination)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.exportTimeout * 1_000_000_000))
                throw ExportTimeoutError()
            }
            guard let url = try await group.next() else {
                throw ExportTimeoutError()
            }
            group.cancelAll()
            return url
        }
    }

    @MainActor
    private static func performExport(markdown: String, destination: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = PDFExporter(
                markdown: markdown,
                assetBaseURL: nil,
                destinationURL: destination
            ) { result in
                continuation.resume(with: result)
            }
        }
    }
}

private struct ExportTimeoutError: LocalizedError {
    var errorDescription: String? {
        "PDF export timed out"
    }
}
