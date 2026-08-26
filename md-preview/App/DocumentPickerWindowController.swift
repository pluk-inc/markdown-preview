//
//  DocumentPickerWindowController.swift
//  md-preview
//

import Cocoa

final class DocumentPickerWindowController: NSWindowController, NSWindowDelegate {
    private let onNewDocument: () -> Void
    private let onOpenDocument: () -> Void
    private let onDismiss: () -> Void

    init(
        onNewDocument: @escaping () -> Void,
        onOpenDocument: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onNewDocument = onNewDocument
        self.onOpenDocument = onOpenDocument
        self.onDismiss = onDismiss

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 310),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = NSLocalizedString("Markdown Preview", comment: "Document picker title")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.contentView = Self.makeContentView(target: self)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        onDismiss()
    }

    @objc private func createNewDocument(_ sender: Any?) {
        window?.close()
        onNewDocument()
    }

    @objc private func openExistingDocument(_ sender: Any?) {
        window?.close()
        onOpenDocument()
    }

    private static func makeContentView(target: DocumentPickerWindowController) -> NSView {
        let icon = NSImageView()
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 52).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let title = NSTextField(labelWithString: NSLocalizedString(
            "Markdown Preview",
            comment: "Document picker heading"
        ))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center

        let message = NSTextField(wrappingLabelWithString: NSLocalizedString(
            "Create a Markdown document or open an existing file.",
            comment: "Document picker message"
        ))
        message.alignment = .center
        message.textColor = .secondaryLabelColor
        message.maximumNumberOfLines = 2

        let newDocument = NSButton(frame: .zero)
        newDocument.title = NSLocalizedString("New Document", comment: "Document picker new button")
        newDocument.target = target
        newDocument.action = #selector(createNewDocument(_:))
        newDocument.keyEquivalent = "\r"
        newDocument.image = NSImage(
            systemSymbolName: "square.and.pencil",
            accessibilityDescription: newDocument.title
        )
        newDocument.imagePosition = .imageLeading
        newDocument.bezelStyle = .rounded
        newDocument.controlSize = .large

        let openDocument = NSButton(frame: .zero)
        openDocument.title = NSLocalizedString("Open Existing…", comment: "Document picker open button")
        openDocument.target = target
        openDocument.action = #selector(openExistingDocument(_:))
        openDocument.image = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: openDocument.title
        )
        openDocument.imagePosition = .imageLeading
        openDocument.bezelStyle = .rounded
        openDocument.controlSize = .large

        let buttons = NSStackView(views: [newDocument, openDocument])
        buttons.orientation = .vertical
        buttons.alignment = .centerX
        buttons.spacing = 8

        let stack = NSStackView(views: [icon, title, message, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: message)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -36),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: 4),
            newDocument.widthAnchor.constraint(equalToConstant: 176),
            openDocument.widthAnchor.constraint(equalTo: newDocument.widthAnchor),
        ])
        return contentView
    }
}
