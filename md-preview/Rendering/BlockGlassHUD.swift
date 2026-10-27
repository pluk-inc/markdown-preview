//
//  BlockGlassHUD.swift
//  md-preview
//
//  The controls of a diagram or a code block as native Liquid Glass on
//  macOS 26: one pill over the preview, on the block under the pointer.
//  The page reports that block (`diagramHUD` messages from the Mermaid
//  wiring, `codeHUD` from the code block script) and runs each action as its
//  HTML buttons do (`mdpDiagramHUDAction`, `mdpCodeHUDAction`), so the
//  logic stays in the page. Quick Look, macOS 15 and the share viewer keep
//  the HTML pills.
//

import AppKit

@available(macOS 26.0, *)
final class BlockGlassHUD: NSView {

    enum Kind { case diagram, code }

    /// The block the page reported, in this view's superview coordinates.
    struct Block {
        var kind: Kind
        var frame: NSRect
        /// Diagrams: the zoom level shown, and whether Open in Window works.
        var level = "100%"
        var hasPopup = false
        /// Code blocks: whether the lines wrap.
        var wrapped = false
    }

    /// Runs an action in the page: for a diagram `out`, `reset`, `in`,
    /// `copy` or `popup`; for a code block `wrap` or `copy`.
    var perform: ((Kind, String) -> Void)?
    /// The web view under the pill, which scrolls when the wheel turns over it.
    weak var scrollTarget: NSView?

    /// The gap from the block's top and right edges to the pill, in CSS
    /// pixels: the same on both sides, and where the page's own pills sit
    /// (`MarkdownHTML.controlPillCSS`).
    private static let inset: CGFloat = 6.5

    private let glass = NSGlassEffectView()
    private let zoomOut = HUDButton(act: "out", width: 24)
    private let levelButton = HUDButton(act: "reset", width: 44)
    private let zoomIn = HUDButton(act: "in", width: 24)
    private let divider = NSBox()
    private let wrapButton = HUDButton(act: "wrap", width: 24)
    private let copyButton = HUDButton(act: "copy", width: 24)
    private let popupButton = HUDButton(act: "popup", width: 24)
    private var current: Block?
    private var laidOut: (Kind, String, Bool, Bool)?
    private var pillSize: NSSize = .zero
    private var copiedReset: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true

        zoomOut.setSymbol("minus", label: NSLocalizedString("Zoom Out", comment: "Mermaid diagram control"))
        zoomIn.setSymbol("plus", label: NSLocalizedString("Zoom In", comment: "Mermaid diagram control"))
        showCopyIcon()
        popupButton.setSymbol("arrow.down.left.and.arrow.up.right",
                              label: NSLocalizedString("Open in Window", comment: "Mermaid diagram control"))
        for button in [zoomOut, levelButton, zoomIn, wrapButton, copyButton, popupButton] {
            button.onPress = { [weak self] act in
                guard let self, let kind = self.current?.kind else { return }
                self.perform?(kind, act)
                if act == "copy" { self.showCopied() }
            }
        }

        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let stack = NSStackView(views: [zoomOut, levelButton, zoomIn, divider, wrapButton, copyButton, popupButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 2
        stack.setCustomSpacing(6, after: zoomIn)
        stack.setCustomSpacing(6, after: divider)
        // The glass sizes its content view to fill it, so the margin that
        // keeps the hover fill clear of the rounded ends lives here.
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        glass.style = .regular
        glass.cornerRadius = 16
        glass.contentView = stack
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            glass.heightAnchor.constraint(equalToConstant: 32),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // .inVisibleRect follows the pill's size, so the area is added once.
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .cursorUpdate,
                                                 .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows the pill on `block`. `visibleTop` is the superview's y below
    /// which the page is not under the window's toolbar; the pill hides
    /// rather than draw over it.
    func show(_ block: Block, scale: CGFloat, visibleTop: CGFloat) {
        guard let superview else { return }
        if current?.kind != block.kind {
            copiedReset?.cancel()
            showCopyIcon()
        }
        current = block
        // While the page scrolls only the frame changes: lay out again only
        // for new contents.
        let content = (block.kind, block.level, block.hasPopup, block.wrapped)
        if laidOut.map({ $0 != content }) ?? true {
            let isDiagram = block.kind == .diagram
            for view in [zoomOut, levelButton, zoomIn, divider] { view.isHidden = !isDiagram }
            wrapButton.isHidden = isDiagram
            popupButton.isHidden = !(isDiagram && block.hasPopup)
            if isDiagram {
                levelButton.setText(block.level, label: NSLocalizedString("Reset zoom", comment: "Mermaid diagram control"))
            } else {
                wrapButton.setImage(Self.codeIcons[block.wrapped ? "unwrap" : "wrap"],
                                    label: block.wrapped
                                        ? NSLocalizedString("Unwrap code", comment: "Code block wrap button")
                                        : NSLocalizedString("Wrap code", comment: "Code block wrap button"))
            }
            layoutSubtreeIfNeeded()
            pillSize = fittingSize
            laidOut = content
        }
        let size = pillSize
        let inset = Self.inset * scale
        // Measured down from the superview's top. A block whose top went
        // under the toolbar keeps its pill just below it, while it fits.
        let height = superview.bounds.height
        let blockTop = superview.isFlipped ? block.frame.minY : height - block.frame.maxY
        let blockBottom = superview.isFlipped ? block.frame.maxY : height - block.frame.minY
        let top = max(blockTop, visibleTop) + inset
        let x = block.frame.maxX - inset - size.width
        let y = superview.isFlipped ? top : height - top - size.height
        frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        let fits = top + size.height + inset <= blockBottom && frame.minX >= block.frame.minX
        // The block moves under a still pointer while the page scrolls.
        let pointer = window.map { superview.convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        let pointerOn = pointer.map { block.frame.contains($0) || frame.contains($0) } ?? true
        isHidden = !(fits && pointerOn)
        if isHidden { current = nil }
    }

    /// The page left a block of `kind`. It reports that too when the pointer
    /// moves onto this view, so the pill stays while the pointer is on it;
    /// a report for the other kind leaves the pill alone.
    func leave(_ kind: Kind) {
        guard current?.kind == kind else { return }
        guard let window else { return hide() }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if isHidden || !bounds.contains(point) { hide() }
    }

    func hide() {
        isHidden = true
        current = nil
    }

    /// The page goes on scrolling under the pill, which follows its block.
    override func scrollWheel(with event: NSEvent) {
        if let scrollTarget { scrollTarget.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    /// A check mark for a moment after Copy, as the page's copy button shows.
    private func showCopied() {
        copyButton.setImage(Self.codeIcons["check"],
                            label: NSLocalizedString("Copied", comment: "Mermaid diagram copy confirmation"))
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.showCopyIcon() }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: reset)
    }

    private func showCopyIcon() {
        copyButton.setImage(Self.codeIcons["copy"],
                            label: NSLocalizedString("Copy", comment: "Mermaid diagram copy button"))
    }

    /// The page's own line icons (`MarkdownHTML.codeIconShapes`) as
    /// template images, tinted like the symbols beside them.
    private static let codeIcons: [String: NSImage] = MarkdownHTML.codeIconShapes.compactMapValues { shapes in
        let image = NSImage(data: Data((MarkdownHTML.lineIconSVGOpen(stroke: "black") + shapes + "</svg>").utf8))
        image?.isTemplate = true
        return image
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        guard let superview, let current else { return }
        let point = superview.convert(event.locationInWindow, from: nil)
        if !current.frame.contains(point) { hide() }
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

/// One HUD button: an icon or a short label over a fill that is a circle
/// (a capsule when wider) under the pointer and darker while pressed, as
/// the page's own HUD and code block buttons do. A plain view, not an
/// NSButton: on macOS 27 a borderless NSButton on glass gets a system hover
/// shaped by its content, so the buttons' fills would all differ.
@available(macOS 26.0, *)
private final class HUDButton: NSView {
    let act: String
    var onPress: ((String) -> Void)?

    private let imageView = NSImageView()
    private let textField = NSTextField(labelWithString: "")
    private var isHovered = false { didSet { updateFill() } }
    private var isPressed = false { didSet { updateFill() } }

    init(act: String, width: CGFloat) {
        self.act = act
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        imageView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        textField.alignment = .center
        addSubview(imageView)
        addSubview(textField)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: 24),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.centerXAnchor.constraint(equalTo: centerXAnchor),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSymbol(_ name: String, label: String) {
        setImage(NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)), label: label)
    }

    func setImage(_ image: NSImage?, label: String) {
        imageView.image = image
        textField.isHidden = true
        setLabel(label)
    }

    func setText(_ text: String, label: String) {
        textField.stringValue = text
        imageView.image = nil
        textField.isHidden = false
        setLabel(label)
    }

    private func setLabel(_ label: String) {
        toolTip = label
        setAccessibilityLabel(label)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(act)
        return true
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if inside { onPress?(act) }
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
        isPressed = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        let tint: NSColor = isHovered ? .labelColor : .secondaryLabelColor
        imageView.contentTintColor = tint
        textField.textColor = tint
        let alpha: CGFloat = isPressed ? 0.16 : isHovered ? 0.1 : 0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
        }
    }
}
