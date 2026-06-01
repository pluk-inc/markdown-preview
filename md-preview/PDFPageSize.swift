//
//  PDFPageSize.swift
//  md-preview
//

import Foundation

/// Paper size for PDF export. Selected from the user's region so North
/// American locales default to US Letter and the rest of the world to A4.
/// Pure value type (Foundation only) so it is unit-testable in the SwiftPM
/// helper package; `PDFExporter` maps it onto `NSPrintInfo`.
nonisolated enum PaperSize: Equatable {
    case usLetter
    case a4

    /// Dimensions in PostScript points (72 dpi), portrait orientation.
    var pointSize: (width: Double, height: Double) {
        switch self {
        case .usLetter: return (612, 792)        // 8.5" × 11"
        case .a4:       return (595.28, 841.89)  // 210mm × 297mm
        }
    }

    /// Regions that conventionally use US Letter. Everything else gets A4.
    private static let letterRegions: Set<String> = [
        "US", "CA", "MX", "CL", "CO", "CR", "GT", "DO",
        "PH", "SV", "NI", "PA", "VE", "PR"
    ]

    /// Maps an ISO region code (e.g. "US", "GB") to a paper size. A nil or
    /// unrecognized region falls back to A4 (the international default).
    static func forRegion(_ regionCode: String?) -> PaperSize {
        guard let regionCode else { return .a4 }
        return letterRegions.contains(regionCode.uppercased()) ? .usLetter : .a4
    }
}
