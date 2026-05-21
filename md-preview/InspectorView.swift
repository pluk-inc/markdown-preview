//
//  InspectorView.swift
//  md-preview
//

import SwiftUI

struct DocumentMetadata: Equatable {
    var fileName: String = ""
    var wordCount: Int = 0
    var characterCount: Int = 0
    var lineCount: Int = 0
    var headingCount: Int = 0
    var linkCount: Int = 0
    var imageCount: Int = 0
    var modifiedDate: Date?
    var fileSize: Int64?
    var frontmatter: [FrontmatterEntry] = []
}

extension DocumentMetadata {
    static func make(url: URL?, markdown: String) -> DocumentMetadata {
        var meta = DocumentMetadata()
        meta.fileName = url?.lastPathComponent ?? "Untitled"

        let split = MarkdownFrontmatter.split(markdown)
        if let raw = split.raw {
            meta.frontmatter = MarkdownFrontmatter.parse(raw, format: split.format ?? .yaml)
        }
        let body = split.body
        let bodyLines = body.components(separatedBy: .newlines)

        meta.characterCount = body.count
        meta.wordCount = body.split { $0.isWhitespace }.count
        meta.lineCount = body.isEmpty ? 0 : bodyLines.count
        meta.headingCount = bodyLines
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.count
        let totalRefs = max(0, body.components(separatedBy: "](").count - 1)
        meta.imageCount = max(0, body.components(separatedBy: "![").count - 1)
        meta.linkCount = max(0, totalRefs - meta.imageCount)

        if let url,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            meta.modifiedDate = attrs[.modificationDate] as? Date
            meta.fileSize = (attrs[.size] as? NSNumber)?.int64Value
        }
        return meta
    }
}

struct InspectorView: View {
    let metadata: DocumentMetadata
    @State private var tab: Tab = .document

    enum Tab: String, CaseIterable, Identifiable {
        case document = "Document"
        case properties = "Properties"
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .document: return "doc"
            case .properties: return "info"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            switch tab {
            case .document: documentTab
            case .properties: propertiesTab
            }
        }
    }

    private var tabPicker: some View {
        Picker("Inspector tab", selection: $tab) {
            ForEach(Tab.allCases) { tab in
                Image(systemName: tab.systemImage)
                    .accessibilityLabel(tab.rawValue)
                    .tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .modifier(TabPickerSizing())
    }

    private var documentTab: some View {
        Form {
            Section {
                LabeledContent("File Name", value: metadata.fileName)
                LabeledContent("Document Type", value: "Markdown Document")
                if let size = metadata.fileSize {
                    LabeledContent("File Size", value: size.formatted(.byteCount(style: .file)))
                }
            }

            Section {
                LabeledContent("Words", value: metadata.wordCount.formatted())
                LabeledContent("Characters", value: metadata.characterCount.formatted())
                LabeledContent("Lines", value: metadata.lineCount.formatted())
            }

            Section {
                LabeledContent("Headings", value: metadata.headingCount.formatted())
                LabeledContent("Links", value: metadata.linkCount.formatted())
                LabeledContent("Images", value: metadata.imageCount.formatted())
            }

            if let modified = metadata.modifiedDate {
                Section {
                    LabeledContent("Modified") {
                        Text(modified, format: .dateTime.year().month().day().hour().minute())
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var propertiesTab: some View {
        if metadata.frontmatter.isEmpty {
            Text("No frontmatter")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Section {
                    ForEach(metadata.frontmatter) { entry in
                        LabeledContent(entry.key, value: entry.value)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct TabPickerSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonSizing(.flexible)
        } else {
            content.fixedSize()
        }
    }
}
