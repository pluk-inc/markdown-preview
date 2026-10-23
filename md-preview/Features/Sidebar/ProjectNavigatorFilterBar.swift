//
//  ProjectNavigatorFilterBar.swift
//  md-preview
//

import Cocoa

/// The bar under the Project Navigator: a round "+" button with a menu of
/// things to add, and a capsule field that filters the tree by file name.
/// The clock toggle limits the tree to recently opened files.
final class ProjectNavigatorFilterBar: NSView, NSTextFieldDelegate {

    /// Builds the "+" menu each time it opens.
    var makeAddMenu: (() -> NSMenu)?
    /// Called when the filter text or the recent-files toggle changes.
    var onFilterChange: (() -> Void)?

    private static let height: CGFloat = 28

    private let addButton = NSButton()
    private let filterField = ClickToFocusTextField()
    private let recentButton = NSButton()

    var filterText: String {
        filterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var showsRecentOnly: Bool { recentButton.state == .on }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        configureIconButton(addButton,
                            symbol: "plus",
                            pointSize: 14,
                            tip: NSLocalizedString("Add", comment: "Project navigator add button"))
        addButton.target = self
        addButton.action = #selector(addTapped)

        let filterIcon = NSImageView()
        filterIcon.translatesAutoresizingMaskIntoConstraints = false
        filterIcon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                                   accessibilityDescription: nil)
        filterIcon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        filterIcon.contentTintColor = .secondaryLabelColor
        filterIcon.setContentHuggingPriority(.required, for: .horizontal)

        filterField.translatesAutoresizingMaskIntoConstraints = false
        filterField.isBezeled = false
        filterField.isBordered = false
        filterField.drawsBackground = false
        filterField.focusRingType = .none
        filterField.font = .systemFont(ofSize: NSFont.systemFontSize)
        filterField.placeholderString = NSLocalizedString("Filter", comment: "Project navigator filter field placeholder")
        filterField.cell?.usesSingleLineMode = true
        filterField.cell?.isScrollable = true
        filterField.cell?.wraps = false
        filterField.delegate = self
        filterField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filterField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureIconButton(recentButton,
                            symbol: "clock",
                            pointSize: 13,
                            tip: NSLocalizedString("Show Only Recent Files", comment: "Project navigator filter toggle"))
        recentButton.setButtonType(.toggle)
        recentButton.target = self
        recentButton.action = #selector(recentToggled)
        updateRecentButtonTint()

        let fieldStack = NSStackView(views: [filterIcon, filterField, recentButton])
        fieldStack.orientation = .horizontal
        fieldStack.alignment = .centerY
        fieldStack.spacing = 6
        fieldStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        fieldStack.translatesAutoresizingMaskIntoConstraints = false

        let addCapsule = Self.capsule(around: addButton)
        let fieldCapsule = Self.capsule(around: fieldStack)
        addSubview(addCapsule)
        addSubview(fieldCapsule)

        NSLayoutConstraint.activate([
            addButton.widthAnchor.constraint(equalToConstant: Self.height),
            recentButton.widthAnchor.constraint(equalToConstant: 20),

            addCapsule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            addCapsule.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            addCapsule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            fieldCapsule.leadingAnchor.constraint(equalTo: addCapsule.trailingAnchor, constant: 6),
            fieldCapsule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            fieldCapsule.centerYAnchor.constraint(equalTo: addCapsule.centerYAnchor),
        ])
    }

    private func configureIconButton(_ button: NSButton, symbol: String, pointSize: CGFloat, tip: String) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.symbolConfiguration = .init(pointSize: pointSize, weight: .regular)
        button.toolTip = tip
        button.setAccessibilityLabel(tip)
        button.heightAnchor.constraint(equalToConstant: Self.height).isActive = true
    }

    /// Wraps `content` in a fixed-height capsule: Liquid Glass on macOS 26,
    /// a quiet filled pill before it.
    private static func capsule(around content: NSView) -> NSView {
        let surface: NSView
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = height / 2
            glass.contentView = content
            surface = glass
        } else {
            let box = NSBox()
            box.boxType = .custom
            box.borderWidth = 0
            box.cornerRadius = height / 2
            box.fillColor = .quaternarySystemFill
            box.contentViewMargins = .zero
            box.contentView = content
            surface = box
        }
        surface.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            content.topAnchor.constraint(equalTo: surface.topAnchor),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            surface.heightAnchor.constraint(equalToConstant: height),
        ])
        return surface
    }

    private func updateRecentButtonTint() {
        recentButton.contentTintColor = showsRecentOnly ? .controlAccentColor : .secondaryLabelColor
    }

    /// Opens upward from the button, as the bar sits at the window's bottom.
    @objc private func addTapped() {
        guard let menu = makeAddMenu?() else { return }
        // `at` is the menu's top-left corner; lift it by the menu's height
        // so the menu's bottom sits just above the button.
        let gap: CGFloat = 6
        let y = addButton.isFlipped ? -(menu.size.height + gap) : addButton.bounds.maxY + menu.size.height + gap
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: addButton)
    }

    /// Empties the field and turns off the recent-files toggle.
    func clearFilter() {
        filterField.stringValue = ""
        recentButton.state = .off
        updateRecentButtonTint()
        onFilterChange?()
    }

    @objc private func recentToggled() {
        updateRecentButtonTint()
        onFilterChange?()
    }

    func controlTextDidChange(_ obj: Notification) {
        onFilterChange?()
    }

    /// Escape clears the filter, as in the Finder and Xcode filter fields.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)), !filterField.stringValue.isEmpty else { return false }
        filterField.stringValue = ""
        onFilterChange?()
        return true
    }
}

/// A text field that takes keyboard focus only when clicked. AppKit gives a
/// new window's focus to its first view that accepts it, and in the document
/// window that is this field: the outline and the toolbar refuse focus.
private final class ClickToFocusTextField: NSTextField {

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refusesFirstResponder = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        refusesFirstResponder = true
    }

    override func mouseDown(with event: NSEvent) {
        refusesFirstResponder = false
        super.mouseDown(with: event)
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        refusesFirstResponder = true
    }
}
