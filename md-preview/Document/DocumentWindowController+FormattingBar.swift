//
//  DocumentWindowController+FormattingBar.swift
//  md-preview
//
//  The formatting accessory bar shown while editing.
//

import Cocoa

extension DocumentWindowController {
    // MARK: Formatting bar

    /// Second toolbar row with common markdown actions, shown while
    /// editing — like Preview's markup bar.
    func showEditAccessory() {
        guard editAccessory == nil else { return }

        let symbolConfig = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        func formatButton(_ symbol: String, _ command: String, _ tip: String) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
                .withSymbolConfiguration(symbolConfig) ?? NSImage()
            let button = NSButton(image: image, target: self, action: #selector(formatCommand(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(command)
            // Preview-style: small bare icons, bezel only under the pointer.
            button.bezelStyle = .accessoryBarAction
            button.controlSize = .small
            button.showsBorderOnlyWhileMouseInside = true
            button.toolTip = tip
            // The accessory-bar bezel pads the icon generously; a fixed
            // width tightens the leading/trailing space around the glyph.
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 26).isActive = true
            return button
        }

        // Plain button with a composed icon+chevron face: unlike a pull-down,
        // the chevron stays visible when the hover-only bezel is hidden.
        let headingTitle = NSLocalizedString("Heading", comment: "Formatting toolbar heading button")
        let headingIcon = NSImage(systemSymbolName: "textformat.size",
                                  accessibilityDescription: headingTitle)?
            .withSymbolConfiguration(symbolConfig) ?? NSImage()
        let headingChevron = NSImage(systemSymbolName: "chevron.down",
                                     accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .semibold)) ?? NSImage()
        let gap: CGFloat = 4
        let faceSize = NSSize(width: headingIcon.size.width + gap + headingChevron.size.width,
                              height: max(headingIcon.size.height, headingChevron.size.height))
        let headingFace = NSImage(size: faceSize, flipped: false) { _ in
            headingIcon.draw(at: NSPoint(x: 0, y: (faceSize.height - headingIcon.size.height) / 2),
                             from: .zero, operation: .sourceOver, fraction: 1)
            headingChevron.draw(at: NSPoint(x: headingIcon.size.width + gap,
                                            y: (faceSize.height - headingChevron.size.height) / 2),
                                from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        headingFace.isTemplate = true
        let headings = NSButton(image: headingFace, target: self,
                                action: #selector(showHeadingMenu(_:)))
        headings.bezelStyle = .accessoryBarAction
        headings.controlSize = .small
        headings.showsBorderOnlyWhileMouseInside = true
        headings.toolTip = headingTitle
        headings.translatesAutoresizingMaskIntoConstraints = false
        headings.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let views: [NSView] = [
            headings,
            separatorView(),
            formatButton("bold", "bold", NSLocalizedString("Bold", comment: "Formatting toolbar tooltip")),
            formatButton("italic", "italic", NSLocalizedString("Italic", comment: "Formatting toolbar tooltip")),
            formatButton("strikethrough", "strikethrough", NSLocalizedString("Strikethrough", comment: "Formatting toolbar tooltip")),
            separatorView(),
            formatButton("list.bullet", "bulletList", NSLocalizedString("Bulleted List", comment: "Formatting toolbar tooltip")),
            formatButton("list.number", "orderedList", NSLocalizedString("Numbered List", comment: "Formatting toolbar tooltip")),
            formatButton("checklist", "taskList", NSLocalizedString("Task List", comment: "Formatting toolbar tooltip")),
            formatButton("text.quote", "quote", NSLocalizedString("Block Quote", comment: "Formatting toolbar tooltip")),
            separatorView(),
            formatButton("chevron.left.forwardslash.chevron.right", "code", NSLocalizedString("Inline Code", comment: "Formatting toolbar tooltip")),
            formatButton("link", "link", NSLocalizedString("Link", comment: "Formatting toolbar tooltip")),
        ]
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 2
        // Buttons stay tight (2px); the group dividers get room to breathe.
        for (index, view) in views.enumerated() where view is NSBox {
            if index > 0 { stack.setCustomSpacing(8, after: views[index - 1]) }
            stack.setCustomSpacing(8, after: view)
        }
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Translucent like the main toolbar: nothing can render behind the
        // bar (the editor scroller clips text at its hairline and the pocket
        // ends at the toolbar), so the bar needs no opaque backing — the
        // flat theme color shows through. Without a theme the .hard edge
        // still paints the classic opaque bar.
        let container = EditAccessoryContainerView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hairline)
        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        hairline.isHidden = !activeSchemeThemed
        editAccessoryHairline = hairline

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .bottom
        accessory.fullScreenMinHeight = 34
        // macOS 26 replaced the titlebar separator with scroll edge
        // effects; hard = the classic line under the bar. With a themed
        // window background the hard edge would paint an opaque system
        // strip over the theme color, so the frosted automatic style is
        // used instead.
        if #available(macOS 26.1, *) {
            accessory.preferredScrollEdgeEffectStyle =
                activeSchemeThemed ? .automatic : .hard
        }
        documentWindow.addTitlebarAccessoryViewController(accessory)
        editAccessory = accessory
    }

    private func separatorView() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return line
    }

    private func hideEditAccessory() {
        guard let accessory = editAccessory else { return }
        accessory.removeFromParent()
        editAccessory = nil
    }

    /// Leaves edit-mode chrome as one operation: drops the formatting bar
    /// and refreshes the toolbar pencil state.
    func dismissEditChrome() {
        hideEditAccessory()
        updateEditToolbarItem()
    }

    @objc private func formatCommand(_ sender: NSButton) {
        guard let command = sender.identifier?.rawValue else { return }
        formatMarkdown(command)
    }

    @objc private func showHeadingMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let normalText = NSMenuItem(title: NSLocalizedString("Normal Text", comment: "Formatting toolbar heading menu"),
                                    action: #selector(headingCommand(_:)),
                                    keyEquivalent: "")
        normalText.target = self
        normalText.tag = 0
        menu.addItem(normalText)
        menu.addItem(.separator())
        for level in 1...3 {
            let item = NSMenuItem(title: String(
                format: NSLocalizedString("Heading %d", comment: "Formatting toolbar heading menu level"),
                level
            ),
                                  action: #selector(headingCommand(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = level
            menu.addItem(item)
        }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.maxY + 4),
                   in: sender)
    }

    @objc private func headingCommand(_ sender: NSMenuItem) {
        formatMarkdown("h\(sender.tag)")
    }

    /// File > Save (⌘S) while editing: write without leaving edit mode.
    /// Intercepts the responder chain ahead of MarkdownDocument, whose
    /// NSDocument save machinery stays disabled.
    @IBAction func saveDocument(_ sender: Any?) {
        guard isEditing || hasPendingEditorChanges else {
            NSSound.beep()
            return
        }
        commitEdits(exitAfter: false)
    }
}
