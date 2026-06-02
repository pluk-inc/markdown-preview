//
//  PDFExporterIntegrationTests.swift
//  md-previewTests
//

import XCTest
@testable import Markdown_Preview

final class PDFExporterIntegrationTests: XCTestCase {

    @MainActor
    func testProseDocumentExport() async throws {
        let markdown = """
        # Integration prose

        Paragraph with enough body text that the rendered PDF is not a trivial blank page.
        Second paragraph to add vertical extent for pagination smoke coverage.
        """
        try await assertExportSucceeds(markdown: markdown, minimumBytes: 2_048)
    }

    @MainActor
    func testCodeFenceDocumentExport() async throws {
        let markdown = """
        # Code sample

        ```swift
        struct Widget {
            var title: String
            func render() -> String {
                (0..<20).map { "\\($0): \\(title)" }.joined(separator: "\\n")
            }
        }
        ```
        """
        try await assertExportSucceeds(markdown: markdown, minimumBytes: 8_192)
    }

    // MARK: - Helpers

    @MainActor
    private func assertExportSucceeds(
        markdown: String,
        minimumBytes: Int
    ) async throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("md-preview-export-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: destination) }

        let url = try await exportPDF(markdown: markdown, destination: destination)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as? Int ?? 0
        XCTAssertLessThan(
            size,
            10_000_000,
            "PDF unexpectedly large (\(size) bytes); export pipeline likely runaway"
        )
        XCTAssertGreaterThan(
            size,
            minimumBytes,
            "PDF too small (\(size) bytes); render likely stalled or blank"
        )
    }

    @MainActor
    private func exportPDF(markdown: String, destination: URL) async throws -> URL {
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
