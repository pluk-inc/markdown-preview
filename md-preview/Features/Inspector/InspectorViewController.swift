//
//  InspectorViewController.swift
//  md-preview
//

import Cocoa
import SwiftUI

final class InspectorViewController: NSViewController {

    private var host: NSHostingView<InspectorView>!
    private var metadata = DocumentMetadata()
    private var selectedText: String?

    override func loadView() {
        host = NSHostingView(rootView: InspectorView(metadata: metadata, showsSelectionCounts: false))
        view = host
    }

    func display(metadata: DocumentMetadata) {
        self.metadata = metadata
        refreshView()
    }

    func setSelectedText(_ text: String?) {
        guard selectedText != text else { return }
        selectedText = text
        refreshView()
    }

    private func refreshView() {
        loadViewIfNeeded()
        var values = metadata
        if let selectedText, !selectedText.isEmpty {
            values.wordCount = selectedText.split { $0.isWhitespace }.count
            values.characterCount = selectedText.count
            values.lineCount = selectedText.components(separatedBy: .newlines).count
        }
        host.rootView = InspectorView(
            metadata: values,
            showsSelectionCounts: selectedText.map { !$0.isEmpty } ?? false
        )
    }

    func updateFileURL(_ url: URL) {
        metadata.fileURL = url
        metadata.fileName = url.lastPathComponent
        display(metadata: metadata)
    }
}
