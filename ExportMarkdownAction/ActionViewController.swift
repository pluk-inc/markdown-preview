//
//  ActionViewController.swift
//  ExportMarkdownAction
//
//  Finder-hosted export for a selected Markdown file. The containing
//  Markdown Preview application is never launched.
//

import Cocoa
import UniformTypeIdentifiers

private nonisolated enum FinderActionConfiguration {
#if FINDER_ACTION_PDF
    static let presetFormat: DocumentExportFormat? = .pdf
#elseif FINDER_ACTION_PNG
    static let presetFormat: DocumentExportFormat? = .png
#elseif FINDER_ACTION_HTML
    static let presetFormat: DocumentExportFormat? = .html
#else
    /// The combined Export Markdown action keeps the format selector visible.
    static let presetFormat: DocumentExportFormat? = nil
#endif
}

private nonisolated enum MarkdownInputTypes {
    static let identifiers: Set<String> = [
        "net.daringfireball.markdown",
        "public.markdown",
        "net.ia.markdown",
        "com.unknown.md",
        "doc.md-preview.mdown",
        "doc.md-preview.mkd",
        "doc.md-preview.mkdn",
        "doc.md-preview.mdwn",
        "doc.md-preview.mdtxt",
        "doc.md-preview.mdtext",
    ]

    static let types = identifiers.map {
        UTType($0) ?? UTType(importedAs: $0)
    }

    static func supports(_ identifier: String) -> Bool {
        if identifiers.contains(identifier) {
            return true
        }
        guard let candidate = UTType(identifier) else {
            return false
        }
        return types.contains { candidate.conforms(to: $0) }
    }
}

private nonisolated enum ActionInputError: LocalizedError {
    case invalidSelection
    case unsupportedType
    case missingFile

    var errorDescription: String? {
        switch self {
        case .invalidSelection:
            return "Select exactly one Markdown file."
        case .unsupportedType:
            return "The selected file is not a supported Markdown document."
        case .missingFile:
            return "Finder did not provide the selected file."
        }
    }
}

private nonisolated struct LoadedMarkdownFile: Sendable {
    let url: URL
    let didStartSecurityScope: Bool
    let ownedTemporaryDirectory: URL?

    static func prepare(
        providerURL: URL,
        isInPlace: Bool,
        suggestedName: String?
    ) throws -> LoadedMarkdownFile {
        if isInPlace {
            return LoadedMarkdownFile(
                url: providerURL,
                didStartSecurityScope:
                    providerURL.startAccessingSecurityScopedResource(),
                ownedTemporaryDirectory: nil
            )
        }

        // Item-provider copies are deleted as soon as their callback returns.
        // Make an owned copy synchronously before crossing back to MainActor.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MarkdownPreviewFinderExport-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let proposedName = suggestedName ?? providerURL.lastPathComponent
        let safeName = URL(fileURLWithPath: proposedName)
            .lastPathComponent
        let destination = directory.appendingPathComponent(
            safeName.isEmpty ? "document.md" : safeName,
            isDirectory: false
        )

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var copyError: (any Error)?
        coordinator.coordinate(
            readingItemAt: providerURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try FileManager.default.copyItem(
                    at: coordinatedURL,
                    to: destination
                )
            } catch {
                copyError = error
            }
        }

        if let error = coordinationError ?? copyError as NSError? {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return LoadedMarkdownFile(
            url: destination,
            didStartSecurityScope: false,
            ownedTemporaryDirectory: directory
        )
    }

    func relinquish() {
        if didStartSecurityScope {
            url.stopAccessingSecurityScopedResource()
        }
        if let ownedTemporaryDirectory {
            try? FileManager.default.removeItem(
                at: ownedTemporaryDirectory)
        }
    }
}

final class ActionViewController: NSViewController {
    private let renderer = MarkdownWebView(
        frame: NSRect(x: 0, y: 0, width: 900, height: 1_200))

    private var loadingProgress: Progress?
    private var inputProvider: NSItemProvider?
    private var loadedFile: LoadedMarkdownFile?
    private var outputDirectory: URL?
    private var renderSettleTask: Task<Void, Never>?
    private var hasLoadedDocument = false
    private var hasStartedExport = false
    private var hasFinishedRequest = false

    override func loadView() {
        let root = NSView(
            frame: NSRect(x: 0, y: 0, width: 420, height: 96))
        root.wantsLayer = true
        root.layer?.masksToBounds = true

        // Finder already supplies the native Quick Action progress surface.
        // Keep only the renderer in our hosted view so users never see a
        // second, custom loading indicator.
        renderer.alphaValue = 0.01
        root.addSubview(renderer)

        preferredContentSize = root.frame.size
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !hasLoadedDocument, !hasStartedExport else {
            return
        }
        loadSelectedFile()
    }

    private func loadSelectedFile() {
        guard let context = extensionContext,
              context.inputItems.count == 1,
              let item = context.inputItems.first as? NSExtensionItem,
              let attachments = item.attachments,
              attachments.count == 1
        else {
            finish(with: ActionInputError.invalidSelection)
            return
        }

        let provider = attachments[0]
        guard let identifier = provider.registeredTypeIdentifiers.first(
            where: MarkdownInputTypes.supports)
        else {
            finish(with: ActionInputError.unsupportedType)
            return
        }
        inputProvider = provider

        let type = UTType(identifier) ?? UTType(importedAs: identifier)
        let suggestedName = provider.suggestedName
        loadingProgress = provider.loadFileRepresentation(
            for: type,
            openInPlace: true
        ) { [weak self] url, isInPlace, error in
            let result: Result<LoadedMarkdownFile, any Error>
            if let error {
                result = .failure(error)
            } else if let url {
                do {
                    result = .success(try LoadedMarkdownFile.prepare(
                        providerURL: url,
                        isInPlace: isInPlace,
                        suggestedName: suggestedName
                    ))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(ActionInputError.missingFile)
            }

            Task { @MainActor [weak self] in
                self?.didLoad(result)
            }
        }
    }

    private func didLoad(
        _ result: Result<LoadedMarkdownFile, any Error>
    ) {
        loadingProgress = nil
        guard !hasFinishedRequest else {
            if case .success(let file) = result {
                file.relinquish()
            }
            return
        }

        switch result {
        case .failure(let error):
            finish(with: error)
        case .success(let file):
            do {
                let markdown = try String(
                    contentsOf: file.url,
                    encoding: .utf8)
                loadedFile = file
                showExport(
                    markdown: markdown,
                    from: file.url)
            } catch {
                file.relinquish()
                finish(with: error)
            }
        }
    }

    private func showExport(markdown: String, from sourceURL: URL) {
        guard let window = view.window else {
            finish(with: ActionInputError.missingFile)
            return
        }

        hasLoadedDocument = true
        window.title = sourceURL.lastPathComponent

        renderer.contentDidReplace = { [weak self] in
            self?.scheduleExportAfterRenderingSettles()
        }
        renderer.heightDidChange = { [weak self] _ in
            guard self?.hasLoadedDocument == true else {
                return
            }
            self?.scheduleExportAfterRenderingSettles()
        }
        renderer.display(
            markdown: markdown,
            assetBaseURL: sourceURL.deletingLastPathComponent())
    }

    private func scheduleExportAfterRenderingSettles() {
        guard !hasStartedExport, !hasFinishedRequest else {
            return
        }
        renderSettleTask?.cancel()
        renderSettleTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(650))
            } catch {
                return
            }
            self?.beginExport()
        }
    }

    private func beginExport() {
        guard !hasStartedExport,
              !hasFinishedRequest,
              let file = loadedFile,
              let window = view.window
        else {
            return
        }

        hasStartedExport = true
        renderSettleTask = nil
        renderer.layoutSubtreeIfNeeded()
        renderer.webView.layoutSubtreeIfNeeded()

        let markdown: String
        do {
            markdown = try String(contentsOf: file.url, encoding: .utf8)
            outputDirectory = try FileManager.default.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: URL(
                    fileURLWithPath: NSHomeDirectory(),
                    isDirectory: true
                ),
                create: true
            )
        } catch {
            finish(with: error)
            return
        }

        guard let outputDirectory else {
            finish(with: ActionInputError.missingFile)
            return
        }

        renderer.exportDocumentForFinder(
            markdown: markdown,
            sourceURL: file.url,
            assetBaseURL: file.url.deletingLastPathComponent(),
            outputDirectory: outputDirectory,
            presetFormat: FinderActionConfiguration.presetFormat,
            from: window
        ) { [weak self] output in
            if let output {
                self?.finishRequest(returning: output)
            } else {
                self?.cancelRequest()
            }
        }
    }

    private func finishRequest(returning output: MarkdownExportOutput) {
        guard !hasFinishedRequest else {
            return
        }
        guard let inputProvider else {
            finish(with: ActionInputError.missingFile)
            return
        }
        hasFinishedRequest = true
        renderSettleTask?.cancel()
        renderSettleTask = nil
        loadingProgress?.cancel()
        loadingProgress = nil
        loadedFile?.relinquish()
        loadedFile = nil

        let outputURL = output.url
        let outputProvider = NSItemProvider()
        outputProvider.suggestedName = outputURL.lastPathComponent
        outputProvider.registerFileRepresentation(
            forTypeIdentifier: output.contentType.identifier,
            fileOptions: [.openInPlace],
            visibility: .all
        ) { completionHandler in
            completionHandler(outputURL, false, nil)
            return nil
        }

        let outputItem = NSExtensionItem()
        outputItem.attachments = [inputProvider, outputProvider]
        self.inputProvider = nil
        // Finder consumes the staged URL after this controller is dismissed.
        // Do not remove the replacement directory on the success path.
        outputDirectory = nil
        extensionContext?.completeRequest(
            returningItems: [outputItem],
            completionHandler: nil)
    }

    private func cancelRequest() {
        finish(with: NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError
        ))
    }

    private func finish(with error: any Error) {
        guard !hasFinishedRequest else {
            return
        }
        hasFinishedRequest = true
        renderSettleTask?.cancel()
        renderSettleTask = nil
        loadingProgress?.cancel()
        loadingProgress = nil
        loadedFile?.relinquish()
        loadedFile = nil
        inputProvider = nil
        if let outputDirectory {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        outputDirectory = nil
        extensionContext?.cancelRequest(withError: error)
    }
}
