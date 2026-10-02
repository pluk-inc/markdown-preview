//
//  MarkdownWebView+PDFExport.swift
//  md-preview
//
//  Printing and document export. App-only: the Quick Look extension compiles
//  MarkdownWebView.swift but not this file.
//

import Cocoa
import UniformTypeIdentifiers
import WebKit

private enum DocumentExportFormat: String, CaseIterable {
    case pdf
    case html
    case png

    private static let defaultsKey = "DocumentExportFormat"

    static var selected: DocumentExportFormat {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(DocumentExportFormat.init(rawValue:)) ?? .pdf
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var title: String {
        switch self {
        case .pdf:
            return NSLocalizedString(
                "PDF Document", comment: "Export format name")
        case .html:
            return NSLocalizedString(
                "HTML Document", comment: "Export format name")
        case .png:
            return NSLocalizedString(
                "PNG Image", comment: "Export format name")
        }
    }

    var contentType: UTType {
        switch self {
        case .pdf: return .pdf
        case .html: return .html
        case .png: return .png
        }
    }

    /// PDF is produced by the panel's own print pipeline; the others are
    /// written by us through a save panel.
    var usesPrintPipeline: Bool { self == .pdf }
}

/// Everything the panel needs to write the non-PDF formats itself.
private struct FileExportSource {
    let markdown: String
    let sourceURL: URL?
    let assetBaseURL: URL?
    /// Reports nil after the image has been saved.
    let writePNG: (URL, @escaping (Error?) -> Void) -> Void

    func writeHTML(to url: URL) throws {
        let html = MarkdownHTML.makeHTML(
            from: markdown,
            allowsScroll: true,
            assetBaseHref: assetBaseURL?.absoluteString,
            vendorLoading: .inline
        )
        try html.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum AccessoryRowMetrics {
    static let height: CGFloat = 30
    static let spacing: CGFloat = 8
    static let horizontalInset: CGFloat = 16
}

private final class ExportFormatRowView: NSView {
    var onChange: ((DocumentExportFormat) -> Void)?
    private(set) var selectedFormat: DocumentExportFormat

    private let formats = DocumentExportFormat.allCases
    private let popup = NSPopUpButton()

    init(width: CGFloat, selectedFormat: DocumentExportFormat) {
        self.selectedFormat = selectedFormat
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: width, height: AccessoryRowMetrics.height))
        autoresizingMask = [.width]

        let label = NSTextField(labelWithString: NSLocalizedString(
            "Format:", comment: "Export format field label"))
        popup.addItems(withTitles: formats.map(\.title))
        popup.selectItem(at: formats.firstIndex(of: selectedFormat) ?? 0)
        popup.target = self
        popup.action = #selector(formatChanged(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(
            NSLayoutConstraint.Priority(1), for: .horizontal)

        let stack = NSStackView(views: [label, spacer, popup])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.distribution = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: AccessoryRowMetrics.height),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 190),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AccessoryRowMetrics.horizontalInset),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AccessoryRowMetrics.horizontalInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard formats.indices.contains(sender.indexOfSelectedItem) else {
            return
        }
        selectedFormat = formats[sender.indexOfSelectedItem]
        onChange?(selectedFormat)
    }
}

/// Printed body size, persisted so the panel reopens with the last choice.
private enum PrintSizeOptions {
    private static let defaultsKey = "PrintBodyPointSize"
    static let minimumPointSize = 6
    static let maximumPointSize = 48

    static var pointSize: Int {
        get {
            let stored = UserDefaults.standard.integer(forKey: defaultsKey)
            guard stored != 0 else {
                return clamped(MarkdownHTML.defaultPrintPointSize)
            }
            return clamped(stored)
        }
        set { UserDefaults.standard.set(clamped(newValue), forKey: defaultsKey) }
    }

    static func clamped(_ points: Int) -> Int {
        min(max(points, minimumPointSize), maximumPointSize)
    }

    static func localizedLabel(for points: Int) -> String {
        String(
            format: NSLocalizedString("%d pt", comment: "Print font size, in points"),
            points
        )
    }
}

/// `Font Size: … [ 12 pt ] ⇅` — an editable field paired with a stepper, the
/// same pairing the print panel's own Copies field uses.
private final class PrintSizeRowView: NSView {
    /// Called with the committed, clamped size. Persistence already happened.
    var onChange: ((Int) -> Void)?

    private var pointSize: Int
    private let sizeField = NSTextField()
    private let stepper = NSStepper()

    init(width: CGFloat) {
        pointSize = PrintSizeOptions.pointSize
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: width, height: AccessoryRowMetrics.height))
        autoresizingMask = [.width]

        let caption = NSTextField(labelWithString: NSLocalizedString(
            "Font Size:", comment: "Print font size field label"))

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        let pointUnit = NSLocalizedString(
            "pt", comment: "Abbreviation for typographic points")
        formatter.positiveSuffix = " \(pointUnit)"
        // Keep direct numeric entry convenient: both `13` and `13 pt` commit
        // to the same value, while the resting presentation always shows `pt`.
        formatter.isLenient = true

        sizeField.formatter = formatter
        sizeField.alignment = .right
        sizeField.integerValue = pointSize
        sizeField.target = self
        sizeField.action = #selector(sizeFieldChanged(_:))
        // Commit on Return *and* on focus loss, so a typed value isn't lost by
        // clicking straight into the surrounding panel's controls.
        sizeField.cell?.sendsActionOnEndEditing = true

        stepper.minValue = Double(PrintSizeOptions.minimumPointSize)
        stepper.maxValue = Double(PrintSizeOptions.maximumPointSize)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.integerValue = pointSize
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))

        // A low-hugging spacer pushes the controls to the far edge, matching
        // the print panel's other accessory rows.
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        let stack = NSStackView(views: [caption, spacer, sizeField, stepper])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.distribution = .fill
        stack.setCustomSpacing(8, after: caption)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: AccessoryRowMetrics.height),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            sizeField.widthAnchor.constraint(equalToConstant: 74),
            stack.leadingAnchor.constraint(
                equalTo: leadingAnchor,
                constant: AccessoryRowMetrics.horizontalInset),
            stack.trailingAnchor.constraint(
                equalTo: trailingAnchor,
                constant: -AccessoryRowMetrics.horizontalInset),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func sizeFieldChanged(_ sender: NSTextField) {
        commit(sender.integerValue)
    }

    @objc private func stepperChanged(_ sender: NSStepper) {
        commit(sender.integerValue)
    }

    private func commit(_ requested: Int) {
        let size = PrintSizeOptions.clamped(requested)
        // Echo the clamp back so the field never shows an out-of-range value,
        // and keep the two controls in step.
        sizeField.integerValue = size
        stepper.integerValue = size
        guard size != pointSize else { return }
        pointSize = size
        PrintSizeOptions.pointSize = size
        onChange?(size)
    }
}

/// Adds a "Markdown Preview" pane to the system print panel holding the font
/// size control, so the panel's own page thumbnails act as the preview.
private final class PrintSizeAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    var preparePaper: ((NSPrintInfo, Int) async throws -> Void)?
    var presentError: ((Error) -> Void)?
    var exportFormatDidChange: ((DocumentExportFormat) -> Void)?

    /// Refresh the native preview after the new layout is ready.
    @objc private dynamic var previewRevision = 0

    private var pointSize = PrintSizeOptions.pointSize
    private var exportFormat: DocumentExportFormat?
    private let showsPrintSize: Bool
    private var printInfoObservers: [NSKeyValueObservation] = []

    override var representedObject: Any? {
        didSet {
            guard (oldValue as? NSPrintInfo) !== (representedObject as? NSPrintInfo) else { return }
            printInfoObservers = []
            guard showsPrintSize, let info = representedObject as? NSPrintInfo else { return }
            printInfoObservers = [
                info.observe(\.paperSize, options: [.old, .new]) { [weak self] _, change in
                    guard change.oldValue != change.newValue else { return }
                    Task { @MainActor in self?.refreshPreview() }
                },
                info.observe(\.orientation, options: [.old, .new]) { [weak self] _, change in
                    guard change.oldValue != change.newValue else { return }
                    Task { @MainActor in self?.refreshPreview() }
                },
            ]
            refreshPreview()
        }
    }

    func prepareForPrinting(using info: NSPrintInfo) async throws {
        try await preparePaper?(info, pointSize)
    }

    private func refreshPreview() {
        guard let info = representedObject as? NSPrintInfo else { return }
        Task {
            do {
                try await prepareForPrinting(using: info)
                previewRevision += 1
            } catch is CancellationError {
            } catch {
                presentError?(error)
            }
        }
    }

    init(exportFormat: DocumentExportFormat? = nil) {
        self.exportFormat = exportFormat
        showsPrintSize = exportFormat == nil
        super.init(nibName: nil, bundle: nil)
        title = NSLocalizedString("Markdown Preview",
                                  comment: "Print panel accessory pane title")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        var rows: [NSView] = []
        if showsPrintSize {
            let sizeRow = PrintSizeRowView(width: 620)
            sizeRow.onChange = { [weak self] size in
                guard let self else { return }
                self.willChangeValue(forKey: "localizedSummaryItems")
                self.pointSize = size
                self.didChangeValue(forKey: "localizedSummaryItems")
                self.refreshPreview()
            }
            rows.append(sizeRow)
        }

        if let exportFormat {
            let formatRow = ExportFormatRowView(
                width: 620,
                selectedFormat: exportFormat
            )
            formatRow.onChange = { [weak self] format in
                guard let self else { return }
                self.willChangeValue(forKey: "localizedSummaryItems")
                self.exportFormat = format
                self.didChangeValue(forKey: "localizedSummaryItems")
                self.exportFormatDidChange?(format)
            }
            rows.insert(formatRow, at: 0)
        }

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = AccessoryRowMetrics.spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let rowCount = CGFloat(rows.count)
        let height = rowCount * AccessoryRowMetrics.height
            + max(0, rowCount - 1) * AccessoryRowMetrics.spacing
        let container = NSView(
            frame: NSRect(x: 0, y: 0, width: 620, height: height))
        container.addSubview(stack)
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        constraints.append(contentsOf: rows.map {
            $0.widthAnchor.constraint(equalTo: container.widthAnchor)
        })
        NSLayoutConstraint.activate(constraints)

        view = container
        preferredContentSize = container.frame.size
    }

    // MARK: NSPrintPanelAccessorizing

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        var items: [[NSPrintPanel.AccessorySummaryKey: String]] = []
        if showsPrintSize {
            items.append([
                .itemName: NSLocalizedString(
                    "Font Size", comment: "Print panel summary item name"),
                .itemDescription: PrintSizeOptions.localizedLabel(for: pointSize),
            ])
        }
        if let exportFormat {
            items.insert([
                .itemName: NSLocalizedString(
                    "Format", comment: "Export format summary item name"),
                .itemDescription: exportFormat.title,
            ], at: 0)
        }
        return items
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        ["previewRevision"]
    }
}

/// Waits for the final paper settings before AppKit starts the print job.
private final class PaperPrintPanel: NSPrintPanel {
    var prepare: ((NSPrintInfo) async throws -> Void)?

    override func beginSheet(
        using printInfo: NSPrintInfo,
        on parentWindow: NSWindow,
        completionHandler handler: ((NSPrintPanel.Result) -> Void)? = nil
    ) {
        super.beginSheet(using: printInfo, on: parentWindow) { result in
            guard result == .printed else {
                handler?(result)
                return
            }
            Task {
                do {
                    try await self.prepare?(printInfo)
                    handler?(.printed)
                } catch {
                    parentWindow.presentError(error)
                    handler?(.cancelled)
                }
            }
        }
    }
}

/// A print panel adapted for PDF and document export.
///
/// AppKit publicly supports changing the default button title, but it has no
/// option for hiding the printer/preset section. On current macOS that section
/// is exposed by `PMPrintPanelController` as `printersSectionStackView`; look it
/// up dynamically and guard every lookup so a future AppKit change cannot
/// crash the app.
///
/// The controller also owns the PDF-services action that the panel's “Save as
/// PDF” menu item uses. Pointing the relabelled default button at that same
/// action gives it the exact native save behaviour without pre-setting a save
/// disposition (which would make `NSPrintOperation` skip this panel).
private final class ExportPrintPanel: NSPrintPanel {
    private let fileExportSource: FileExportSource?
    private(set) var selectedFormat: DocumentExportFormat

    private weak var parentWindow: NSWindow?
    private weak var printSheetWindow: NSWindow?
    private weak var printSheetController: NSWindowController?
    private var isObservingPrintSheet = false
    private var isShowingFileSavePanel = false
    private var didRemoveTopPocket = false

    /// `initialFormat` lets Export as PDF… open on PDF while still offering the
    /// other formats, rather than reopening on whatever was last exported.
    init(fileExportSource: FileExportSource? = nil,
         initialFormat: DocumentExportFormat? = nil) {
        self.fileExportSource = fileExportSource
        selectedFormat = fileExportSource == nil
            ? .pdf
            : (initialFormat ?? DocumentExportFormat.selected)
        super.init()
    }

    var formatForAccessory: DocumentExportFormat? {
        fileExportSource == nil ? nil : selectedFormat
    }

    func selectExportFormat(_ format: DocumentExportFormat) {
        guard fileExportSource != nil else { return }
        selectedFormat = format
        DocumentExportFormat.selected = format
        if let printSheetController {
            configureSaveButton(on: printSheetController)
        }
    }

    override func beginSheet(
        using printInfo: NSPrintInfo,
        on parentWindow: NSWindow,
        completionHandler handler: ((NSPrintPanel.Result) -> Void)? = nil
    ) {
        self.parentWindow = parentWindow
        didRemoveTopPocket = false
        observePrintSheet()

        super.beginSheet(using: printInfo, on: parentWindow) { [weak self] result in
            self?.stopObservingPrintSheet()
            handler?(result)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func observePrintSheet() {
        guard !isObservingPrintSheet else { return }
        isObservingPrintSheet = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(printSheetDidUpdate(_:)),
            name: NSWindow.didUpdateNotification,
            object: nil
        )
    }

    private func stopObservingPrintSheet() {
        guard isObservingPrintSheet else { return }
        NotificationCenter.default.removeObserver(self)
        parentWindow = nil
        printSheetWindow = nil
        printSheetController = nil
        isShowingFileSavePanel = false
        didRemoveTopPocket = false
        isObservingPrintSheet = false
    }

    @objc private func printSheetDidUpdate(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.isSheet,
              window.sheetParent === parentWindow,
              let controller = window.windowController,
              NSStringFromClass(type(of: controller))
                == "PMPrintPanelController"
        else { return }

        printSheetWindow = window
        printSheetController = controller

        // PrintingUI posts its first update synchronously while the sheet is
        // still invisible and unordered, but after windowDidLoad has installed
        // all controls and scroll pockets. Discover and transform the sheet at
        // that point so Printer/Presets never reach a composited frame.
        // PrintingUI revalidates its default button whenever print settings or
        // pagination change. With no selected printer that pass disables the
        // button, even though file export needs no printer. Reapply the native
        // PDF-services target after every sheet update for the sheet's entire
        // lifetime, rather than only when it first appears.
        configure(controller: controller)
    }

    private func configure(controller: NSWindowController) {
        if let scrollView = privateObject(
            named: "printOptionsScrollView", on: controller) as? NSScrollView {
            removeTopPocketIfNeeded(from: scrollView, controller: controller)
        }
        configureSaveButton(on: controller)
    }

    private func removeTopPocketIfNeeded(
        from scrollView: NSScrollView,
        controller: NSWindowController
    ) {
        guard !didRemoveTopPocket,
              let printerSection = privateObject(
                named: "printersSectionStackView", on: controller) as? NSView
        else { return }

        let collapsedTopInset = max(
            0,
            scrollView.additionalSafeAreaInsets.top
                - printerSection.frame.height
        )

        // PrintingUI separately registers this private view as the top
        // `NSScrollView` pocket. Edge 1 is the button pocket and must remain
        // intact for Save/Cancel.
        guard destroyTopScrollPocket(
            registeredFor: printerSection,
            from: scrollView,
            observer: controller
        ) else { return }

        let container = printerSection.superview
        printerSection.removeFromSuperview()
        container?.needsLayout = true
        container?.layoutSubtreeIfNeeded()

        var optionsInsets = scrollView.additionalSafeAreaInsets
        optionsInsets.top = collapsedTopInset
        scrollView.additionalSafeAreaInsets = optionsInsets
        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()
        didRemoveTopPocket = true
    }

    private func configureSaveButton(on controller: NSWindowController) {
        guard !isShowingFileSavePanel else { return }
        guard let saveButton = privateObject(
            named: "printButton", on: controller) as? NSButton
        else { return }

        saveButton.title = NSLocalizedString(
            "Save", comment: "Export button title")
        if fileExportSource != nil, !selectedFormat.usesPrintPipeline {
            saveButton.target = self
            saveButton.action = #selector(saveExportedFile(_:))
        } else {
            // Fail closed if a future PrintingUI version removes the private
            // PDF service rather than leaving a stale HTML action attached.
            saveButton.target = nil
            saveButton.action = nil
            saveButton.isEnabled = false
            guard let pdfServicesController = privateObject(
                named: "pdfServicesController", on: controller)
            else { return }
            let saveAction = NSSelectorFromString("doSaveAsPDF:")
            guard pdfServicesController.responds(to: saveAction) else { return }

            // Use the same private action as the panel's native “Save as PDF”
            // item. It opens Apple's NSSavePanel, updates the print
            // disposition/URL, and lets NSPrintOperation render the selected
            // pages to that file.
            saveButton.target = pdfServicesController
            saveButton.action = saveAction
        }
        saveButton.isEnabled = true
    }

    @objc private func saveExportedFile(_ sender: Any?) {
        let format = selectedFormat
        guard !isShowingFileSavePanel,
              !format.usesPrintPipeline,
              let fileExportSource,
              let printSheetWindow
        else { return }

        isShowingFileSavePanel = true
        let panel = NSSavePanel()
        panel.title = NSLocalizedString(
            "Export", comment: "Export panel title")
        panel.prompt = NSLocalizedString(
            "Export", comment: "Export panel confirmation button")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.allowedContentTypes = [format.contentType]
        panel.directoryURL =
            fileExportSource.sourceURL?.deletingLastPathComponent()
                ?? fileExportSource.assetBaseURL

        let sourceName =
            fileExportSource.sourceURL?.lastPathComponent
                ?? parentWindow?.title
                ?? NSLocalizedString(
                    "Untitled", comment: "Window title when no document is open")
        let baseName = (sourceName as NSString).deletingPathExtension
        let fileExtension = format.contentType.preferredFilenameExtension
            ?? format.rawValue
        panel.nameFieldStringValue = "\(baseName).\(fileExtension)"

        panel.beginSheetModal(for: printSheetWindow) { [weak self] response in
            guard let self else { return }
            self.isShowingFileSavePanel = false
            // NSSavePanel may invoke its completion while it is still ordered
            // onscreen. Detach it before restoring or ending the outer sheet.
            panel.orderOut(nil)
            guard response == .OK, let url = panel.url else {
                if let printSheetController = self.printSheetController {
                    self.configureSaveButton(on: printSheetController)
                }
                return
            }

            switch format {
            case .html:
                do {
                    try fileExportSource.writeHTML(to: url)
                } catch {
                    NSAlert(error: error).beginSheetModal(for: printSheetWindow)
                    return
                }
                self.dismissAfterFileExport()
            case .png:
                fileExportSource.writePNG(url) { [weak self] error in
                    if let error {
                        NSAlert(error: error).beginSheetModal(for: printSheetWindow)
                        return
                    }
                    self?.dismissAfterFileExport()
                }
            case .pdf:
                break
            }
        }
    }

    /// These formats bypass NSPrintOperation. End the outer panel as cancelled
    /// once the nested save sheet has detached, so no print job can spool and
    /// the document window can immediately take focus.
    private func dismissAfterFileExport() {
        DispatchQueue.main.async { [weak printSheetWindow] in
            guard let printSheetWindow,
                  let parent = printSheetWindow.sheetParent
            else { return }
            parent.endSheet(printSheetWindow, returnCode: .cancel)
        }
    }

    private func destroyTopScrollPocket(
        registeredFor printerSection: NSView,
        from scrollView: NSScrollView,
        observer: AnyObject
    ) -> Bool {
        let topEdge = 0
        let unregisterSelector = NSSelectorFromString(
            "unregisterPocketContainer:onEdge:"
        )
        let destroySelector = NSSelectorFromString("_destroyPocketForEdge:")
        let pocketSelector = NSSelectorFromString(
            "_pocketForEdge:makeIfNeeded:"
        )
        guard scrollView.responds(to: unregisterSelector),
              scrollView.responds(to: destroySelector),
              scrollView.responds(to: pocketSelector)
        else { return false }

        typealias GetPocketMethod = @convention(c) (
            AnyObject,
            Selector,
            Int,
            Bool
        ) -> Unmanaged<AnyObject>?

        let pocketImplementation = scrollView.method(for: pocketSelector)
        let getPocket = unsafeBitCast(
            pocketImplementation,
            to: GetPocketMethod.self
        )
        guard let topScrollPocket = getPocket(
            scrollView,
            pocketSelector,
            topEdge,
            false
        )?.takeUnretainedValue() as? NSView
        else { return false }

        typealias UnregisterPocketMethod = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            Int
        ) -> Void

        // PrintingUI observes the registered section to recompute the pocket
        // inset. Stop that exact observation before detaching the section.
        NotificationCenter.default.removeObserver(
            observer,
            name: NSView.frameDidChangeNotification,
            object: printerSection
        )

        let unregisterImplementation = scrollView.method(
            for: unregisterSelector
        )
        let unregister = unsafeBitCast(
            unregisterImplementation,
            to: UnregisterPocketMethod.self
        )
        unregister(
            scrollView,
            unregisterSelector,
            printerSection,
            topEdge
        )

        typealias DestroyPocketMethod = @convention(c) (
            AnyObject,
            Selector,
            Int
        ) -> Void

        let destroyImplementation = scrollView.method(for: destroySelector)
        let destroy = unsafeBitCast(
            destroyImplementation,
            to: DestroyPocketMethod.self
        )
        destroy(scrollView, destroySelector, topEdge)

        // `_destroyPocketForEdge:` clears AppKit's bookkeeping but currently
        // leaves the NSScrollPocket view (and its hard blur backdrop) attached
        // to the scroll view. Detach that exact retained edge-0 view too.
        topScrollPocket.removeFromSuperview()
        return true
    }

    private func privateObject(
        named getterName: String,
        on object: AnyObject
    ) -> AnyObject? {
        let getter = NSSelectorFromString(getterName)
        guard object.responds(to: getter),
              let result = object.perform(getter)
        else { return nil }
        return result.takeUnretainedValue()
    }
}

extension MarkdownWebView {
    /// Builds a print operation for the rendered document.
    ///
    /// `NSPrintOperation.run()` must never be used with a WKWebView: WebKit
    /// computes pagination asynchronously, so the synchronous path never learns
    /// the page count and can emit pages without bound. Only `runModal` is safe.
    private func makePrintOperation(for webView: WKWebView, from window: NSWindow,
                                    printInfo: NSPrintInfo = NSPrintInfo.shared) -> NSPrintOperation {
        let printInfo = printInfo.copy() as? NSPrintInfo ?? NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false

        let operation = webView.printOperation(with: printInfo)
        // The save panel appends the file extension to this title.
        operation.jobTitle = (window.title as NSString).deletingPathExtension
        // WKWebView's print view needs an explicit frame, otherwise AppKit
        // asserts when the operation tries to lay out at zero size.
        operation.view?.frame = webView.bounds
        operation.printPanel.options.insert(.showsPreview)
        return operation
    }

    private func captureExportSession(assetBaseURL: URL?) async throws -> DocumentExportSession {
        let configuration = WKWebViewConfiguration()
        let assets = MarkdownAssetScheme()
        assets.setBaseURL(assetBaseURL)
        configuration.setURLSchemeHandler(assets, forURLScheme: MarkdownAssetScheme.scheme)
        return try await DocumentExportSession.capture(from: webView, configuration: configuration)
    }

    /// File ▸ Export… — the same native preview used by PDF export, with a
    /// format selector in the Markdown Preview accessory pane.
    func exportDocument(
        markdown: String,
        sourceURL: URL?,
        assetBaseURL: URL?,
        from window: NSWindow
    ) {
        presentExportPanel(
            markdown: markdown,
            sourceURL: sourceURL,
            assetBaseURL: assetBaseURL,
            initialFormat: nil,
            from: window
        )
    }

    /// File ▸ Export as PDF… — the same panel and format list, but opening on
    /// PDF regardless of what was exported last.
    func exportPDF(
        markdown: String,
        sourceURL: URL?,
        assetBaseURL: URL?,
        from window: NSWindow
    ) {
        presentExportPanel(
            markdown: markdown,
            sourceURL: sourceURL,
            assetBaseURL: assetBaseURL,
            initialFormat: .pdf,
            from: window
        )
    }

    private func presentExportPanel(
        markdown: String,
        sourceURL: URL?,
        assetBaseURL: URL?,
        initialFormat: DocumentExportFormat?,
        from window: NSWindow
    ) {
        Task {
            var session: DocumentExportSession?
            do {
                let export = try await captureExportSession(assetBaseURL: assetBaseURL)
                session = export
                let exportView = try await export.webView(for: .pdf)
                let source = FileExportSource(
                    markdown: markdown,
                    sourceURL: sourceURL,
                    assetBaseURL: assetBaseURL,
                    writePNG: { url, completion in
                        Task {
                            do {
                                try await export.writePNG(to: url)
                                completion(nil)
                            } catch {
                                completion(error)
                            }
                        }
                    }
                )
                let panel = ExportPrintPanel(fileExportSource: source, initialFormat: initialFormat)
                let operation = makePrintOperation(for: exportView, from: window)
                let accessory = PrintSizeAccessoryController(exportFormat: panel.formatForAccessory)
                accessory.exportFormatDidChange = { [weak panel] format in
                    panel?.selectExportFormat(format)
                }
                panel.addAccessoryController(accessory)
                panel.options.insert(.showsPreview)
                operation.printPanel = panel
                prepareForPanelDrivenExport(operation)
                _ = await export.runPrintOperation(operation, from: window)
            } catch {
                session?.close()
                window.presentError(error)
            }
        }
    }

    /// File ▸ Print… — the system print panel, with the font size in a
    /// "Markdown Preview" accessory pane so the panel's own live page
    /// thumbnails preview the choice.
    func printDocument(assetBaseURL: URL?, from window: NSWindow) {
        Task {
            var session: DocumentExportSession?
            do {
                let export = try await captureExportSession(assetBaseURL: assetBaseURL)
                session = export
                let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
                let paperView = try await export.preparePaper(using: info, pointSize: PrintSizeOptions.pointSize)
                let operation = makePrintOperation(for: paperView, from: window, printInfo: info)
                let accessory = PrintSizeAccessoryController()
                accessory.preparePaper = { [weak operation] info, size in
                    let view = try await export.preparePaper(using: info, pointSize: size)
                    operation?.view?.frame = view.bounds
                }
                accessory.presentError = { window.presentError($0) }
                let panel = PaperPrintPanel()
                panel.prepare = { try await accessory.prepareForPrinting(using: $0) }
                panel.addAccessoryController(accessory)
                panel.options.insert(.showsPreview)
                operation.printPanel = panel
                _ = await export.runPrintOperation(operation, from: window)
            } catch {
                session?.close()
                window.presentError(error)
            }
        }
    }

    private func prepareForPanelDrivenExport(_ operation: NSPrintOperation) {
        // The PDF-services action sets these after the user chooses a URL.
        // Pre-setting `.save` makes NSPrintOperation bypass NSPrintPanel.
        operation.printInfo.jobDisposition = .spool
        operation.printInfo.dictionary().removeObject(
            forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString
        )
    }
}
