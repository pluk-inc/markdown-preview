//
//  InspectorView.swift
//  md-preview
//

import AppKit
import SwiftUI

struct DocumentMetadata: Equatable {
    var fileName: String = ""
    var fileURL: URL?
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
        meta.fileURL = url
        meta.fileName = url?.lastPathComponent
            ?? NSLocalizedString("Untitled", comment: "Inspector file name when no document is open")

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
    @State private var pathExpanded = false

    enum Tab: String, CaseIterable, Identifiable {
        case document = "Document"
        case properties = "Properties"
        var id: String { rawValue }

        var localizedTitle: String {
            NSLocalizedString(rawValue, comment: "Inspector tab title")
        }

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
        Picker(NSLocalizedString("Inspector tab", comment: "Inspector tab picker accessibility label"), selection: $tab) {
            ForEach(Tab.allCases) { tab in
                Image(systemName: tab.systemImage)
                    .accessibilityLabel(tab.localizedTitle)
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
                LabeledContent(
                    NSLocalizedString("File Name", comment: "Inspector field label"),
                    value: metadata.fileName
                )
                if let url = metadata.fileURL {
                    Group {
                        if pathExpanded {
                            VStack(spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(NSLocalizedString("Full Path", comment: "Inspector field label"))
                                    Spacer()
                                    revealButton(for: url)
                                }
                                pathText(for: url)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        } else {
                            HStack(spacing: 6) {
                                Text(NSLocalizedString("Full Path", comment: "Inspector field label"))
                                Spacer()
                                pathText(for: url)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                revealButton(for: url)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { pathExpanded.toggle() }
                    .contextMenu {
                        Button(NSLocalizedString("Copy Path", comment: "Inspector context menu item")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.path, forType: .string)
                        }
                        Button(NSLocalizedString("Show in Finder", comment: "Inspector reveal button tooltip")) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                    .help(url.path)
                }
                LabeledContent(
                    NSLocalizedString("Document Type", comment: "Inspector field label"),
                    value: NSLocalizedString("Markdown Document", comment: "Inspector document type")
                )
                if let size = metadata.fileSize {
                    LabeledContent(
                        NSLocalizedString("File Size", comment: "Inspector field label"),
                        value: size.formatted(.byteCount(style: .file))
                    )
                }
            }

            Section {
                LabeledContent(
                    NSLocalizedString("Words", comment: "Inspector field label"),
                    value: metadata.wordCount.formatted()
                )
                LabeledContent(
                    NSLocalizedString("Characters", comment: "Inspector field label"),
                    value: metadata.characterCount.formatted()
                )
                LabeledContent(
                    NSLocalizedString("Lines", comment: "Inspector field label"),
                    value: metadata.lineCount.formatted()
                )
            }

            Section {
                LabeledContent(
                    NSLocalizedString("Headings", comment: "Inspector field label"),
                    value: metadata.headingCount.formatted()
                )
                LabeledContent(
                    NSLocalizedString("Links", comment: "Inspector field label"),
                    value: metadata.linkCount.formatted()
                )
                LabeledContent(
                    NSLocalizedString("Images", comment: "Inspector field label"),
                    value: metadata.imageCount.formatted()
                )
            }

            if let modified = metadata.modifiedDate {
                Section {
                    LabeledContent(NSLocalizedString("Modified", comment: "Inspector field label")) {
                        Text(modified, format: .dateTime.year().month().day().hour().minute())
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pathText(for url: URL) -> Text {
        Text(Self.displayPath(for: url))
            .foregroundStyle(.secondary)
    }

    private func revealButton(for url: URL) -> some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Image(systemName: "arrow.right.circle.fill")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Show in Finder", comment: "Inspector reveal button tooltip"))
        .accessibilityLabel(NSLocalizedString("Show in Finder", comment: "Inspector reveal button tooltip"))
    }

    @ViewBuilder
    private var propertiesTab: some View {
        if metadata.frontmatter.isEmpty {
            Text(NSLocalizedString("No frontmatter", comment: "Inspector empty frontmatter message"))
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

extension InspectorView {
    // The sandbox remaps NSHomeDirectory() to the app container, so resolve the
    // user's real home for tilde abbreviation.
    private static let realHomePath: String = {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        return NSHomeDirectory()
    }()

    static func displayPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix(realHomePath + "/") {
            return "~" + path.dropFirst(realHomePath.count)
        }
        return path
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
