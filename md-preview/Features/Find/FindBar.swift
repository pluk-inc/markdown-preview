//
//  FindBar.swift
//  md-preview
//

import Cocoa

/// Slim bar shown beneath the toolbar while searching: match count,
/// previous / next chevrons, and a Done button.
final class FindBar: NSView {

    static let preferredHeight: CGFloat = 36

    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onDone: (() -> Void)?
    var onModeChanged: ((SearchMode) -> Void)?

    private let modeLabel = NSTextField(labelWithString: NSLocalizedString("Match:", comment: "Find bar match mode label"))
    private let containsButton = NSButton(
        title: NSLocalizedString("Contains", comment: "Find bar match mode"),
        target: nil,
        action: nil
    )
    private let beginsWithButton = NSButton(
        title: NSLocalizedString("Begins With", comment: "Find bar match mode"),
        target: nil,
        action: nil
    )
    private let countLabel = NSTextField(labelWithString: "")
    private let navigationControl = NSSegmentedControl()
    private let doneButton = NSButton(
        title: NSLocalizedString("Done", comment: "Find bar close button"),
        target: nil,
        action: nil
    )
    private let bottomSeparator = HairlineSeparator()

    private enum NavigationSegment: Int {
        case previous = 0
        case next = 1
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    func update(matchCount: Int, currentIndex: Int) {
        if matchCount == 0 {
            countLabel.stringValue = NSLocalizedString("Not found", comment: "Find bar empty result")
        } else {
            countLabel.stringValue = String(
                format: NSLocalizedString("%d of %d", comment: "Find bar current and total match count"),
                currentIndex,
                matchCount
            )
        }
        let hasMatches = matchCount > 0
        navigationControl.setEnabled(hasMatches, forSegment: NavigationSegment.previous.rawValue)
        navigationControl.setEnabled(hasMatches, forSegment: NavigationSegment.next.rawValue)
    }

    private func setUp() {
        countLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        countLabel.textColor = .secondaryLabelColor
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        configureModeButtons()
        configureNavigationControl()

        modeLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        modeLabel.textColor = .secondaryLabelColor

        doneButton.bezelStyle = .rounded
        doneButton.controlSize = .regular
        doneButton.target = self
        doneButton.action = #selector(doneTapped)
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        let leadingStack = NSStackView(views: [modeLabel, containsButton, beginsWithButton])
        leadingStack.orientation = .horizontal
        leadingStack.spacing = 8
        leadingStack.alignment = .centerY
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leadingStack)

        let trailingStack = NSStackView(views: [countLabel, navigationControl, doneButton])
        trailingStack.orientation = .horizontal
        trailingStack.spacing = 12
        trailingStack.alignment = .centerY
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(trailingStack)

        // macOS 26 dropped the system-drawn separators around titlebar
        // accessories, so we draw our own bottom rule. macOS 15 still draws
        // them, so hiding ours avoids a doubled line there.
        // NSBox(.separator) inside a bottom titlebar accessory triggers a macOS
        // 26 layout regression that bypasses the window's contentMinSize and
        // collapses the window to the toolbar's natural minimum width — use a
        // plain NSView with a 1pt separator-colored layer instead.
        let needsManualSeparator: Bool = {
            if #available(macOS 26.0, *) { return true }
            return false
        }()

        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        bottomSeparator.isHidden = !needsManualSeparator
        addSubview(bottomSeparator)

        NSLayoutConstraint.activate([
            leadingStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            leadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),

            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    private func configureModeButtons() {
        for button in [containsButton, beginsWithButton] {
            button.bezelStyle = .flexiblePush
            button.controlSize = .small
            button.showsBorderOnlyWhileMouseInside = true
            button.setButtonType(.pushOnPushOff)
            button.setAccessibilitySubrole(.toggle)
            button.target = self
            button.action = #selector(modeButtonTapped(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        containsButton.state = .on
        beginsWithButton.state = .off
    }

    private func configureNavigationControl() {
        let previousMatch = NSLocalizedString("Previous match", comment: "Find bar navigation button")
        let nextMatch = NSLocalizedString("Next match", comment: "Find bar navigation button")
        let previous = NSImage(systemSymbolName: "chevron.left",
                               accessibilityDescription: previousMatch) ?? NSImage()
        let next = NSImage(systemSymbolName: "chevron.right",
                           accessibilityDescription: nextMatch) ?? NSImage()
        previous.isTemplate = true
        next.isTemplate = true

        navigationControl.segmentStyle = .rounded
        navigationControl.trackingMode = .momentary
        navigationControl.segmentCount = 2
        navigationControl.setImage(previous, forSegment: NavigationSegment.previous.rawValue)
        navigationControl.setImage(next, forSegment: NavigationSegment.next.rawValue)
        navigationControl.setToolTip(previousMatch, forSegment: NavigationSegment.previous.rawValue)
        navigationControl.setToolTip(nextMatch, forSegment: NavigationSegment.next.rawValue)
        navigationControl.setImageScaling(.scaleProportionallyDown,
                                          forSegment: NavigationSegment.previous.rawValue)
        navigationControl.setImageScaling(.scaleProportionallyDown,
                                          forSegment: NavigationSegment.next.rawValue)
        navigationControl.target = self
        navigationControl.action = #selector(navigationTapped(_:))
        navigationControl.translatesAutoresizingMaskIntoConstraints = false
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.preferredHeight)
    }

    @objc private func navigationTapped(_ sender: NSSegmentedControl) {
        switch NavigationSegment(rawValue: sender.selectedSegment) {
        case .previous: onPrevious?()
        case .next: onNext?()
        case .none: break
        }
    }

    @objc private func doneTapped() { onDone?() }

    @objc private func modeButtonTapped(_ sender: NSButton) {
        let mode: SearchMode = sender === beginsWithButton ? .beginsWith : .contains
        guard containsButton.state != (mode == .contains ? .on : .off) else { return }
        containsButton.state = mode == .contains ? .on : .off
        beginsWithButton.state = mode == .beginsWith ? .on : .off
        onModeChanged?(mode)
    }
}
