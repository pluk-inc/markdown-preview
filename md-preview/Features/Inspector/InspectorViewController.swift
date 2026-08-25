//
//  InspectorViewController.swift
//  md-preview
//

import Cocoa
import SwiftUI

final class InspectorViewController: NSViewController {

    private var host: NSHostingView<InspectorView>!
    private var metadata = DocumentMetadata()

    override func loadView() {
        host = NSHostingView(rootView: InspectorView(metadata: metadata))
        view = host
    }

    func display(metadata: DocumentMetadata) {
        self.metadata = metadata
        loadViewIfNeeded()
        host.rootView = InspectorView(metadata: metadata)
    }
}
