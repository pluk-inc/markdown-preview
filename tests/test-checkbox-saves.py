"""Exercise production checkbox/save and image-paste methods with real temporary files.

Like test-mode-transitions.py, extract controller methods because the app
controllers are not in the helper package. AppKit sheets, clipboard, editor
and rendering are stand-ins; controller decisions and disk writes are real.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'md-preview/Document/DocumentWindowController+EditSession.swift').read_text()
image_source = (root / 'md-preview/Document/DocumentWindowController+ImageHandling.swift').read_text()
asset_source = (root / 'md-preview/Rendering/MarkdownAssetResolution.swift').read_text()
editor_source = (root / 'md-preview/Features/Editor/EditorViewController.swift').read_text()


def extract(text, signature):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


swift = r'''
import AppKit
import UniformTypeIdentifiers

enum NSPasteboard {
    static let general = AppKit.NSPasteboard(name: .init(UUID().uuidString))
}
enum Response { case alertFirstButtonReturn, alertSecondButtonReturn, cancel, OK }
final class Window { var title = "" }
final class NSAlert {
    enum Style { case warning }
    var alertStyle = Style.warning
    var messageText = ""
    var informativeText = ""
    static var respond: ((Response) -> Void)?
    func addButton(withTitle: String) {}
    func beginSheetModal(for window: Window, completionHandler: @escaping (Response) -> Void) {
        NSAlert.respond = completionHandler
    }
}
final class NSSavePanel {
    var allowedContentTypes: [UTType] = []
    var allowsOtherFileTypes = false
    var canCreateDirectories = false
    var prompt = ""
    var directoryURL: URL?
    var nameFieldStringValue = ""
    var message = ""
    var url: URL?
    static var pending: NSSavePanel?
    static var respond: ((Response) -> Void)?
    func beginSheetModal(for window: Window, completionHandler: @escaping (Response) -> Void) {
        Self.pending = self
        Self.respond = completionHandler
    }
}
final class NSDocumentController {
    static let shared = NSDocumentController()
    func noteNewRecentDocumentURL(_ url: URL) {}
}
final class Document {
    var contents = ""
    func replaceContents(markdown: String, fileURL: URL? = nil) { contents = markdown }
}
enum NSSound { static func beep() {} }
final class AssetScheme {
    var baseURL: URL?
    func setBaseURL(_ url: URL?) { baseURL = url }
}
final class WebView {
    var scripts: [String] = []
    func evaluateJavaScript(_ script: String, completionHandler: ((Any?, Error?) -> Void)?) {
        scripts.append(script)
    }
}
final class Editor {
    var markdown = ""
    var currentAssetBaseURL: URL?
    let assetScheme = AssetScheme()
    let webView = WebView()
    var defersInsertions = false
    var pendingInsertions: [() -> Void] = []
    var cancelRequested: (() -> Void)?
    var contentDidChange: (() -> Void)?
    var formattingDidChange: ((Int, Set<String>, String?) -> Void)?
    var pasteImageRequested: ((Int, Int) -> Void)?
    var imageClicked: ((URL) -> Void)?
    func fetchMarkdown(_ completion: (String?) -> Void) { completion(markdown) }
    func load(markdown: String, assetBaseURL: URL?) { self.markdown = markdown }
    func insertMarkdown(_ text: String, from: Int, to: Int,
                        completion: ((Bool) -> Void)? = nil) {
        let insert = { [self] in
            markdown = (markdown as NSString).replacingCharacters(
                in: NSRange(location: from, length: to - from), with: text)
            contentDidChange?()
            completion?(true)
        }
        if defersInsertions { pendingInsertions.append(insert) } else { insert() }
    }
}
typealias EditorViewController = Editor
final class Split {
    var isEditingDocument = false
    var editorViewController: Editor? = Editor()
    var onLiveMetadataNeedsRefresh: (() -> Void)?
    func updateInspectorSelection(_ text: String?) {}
    func openFileURLDidChange(_ url: URL, markdown: String) {}
    func enterEditMode(markdown: String, assetBaseURL: URL?, autofocus: Bool) -> Editor {
        isEditingDocument = true
        editorViewController!.markdown = markdown
        return editorViewController!
    }
}
final class Controller {
    enum DiskFileState { case unchanged, modified(String), missing, unreadable }
    enum EditedMarkdownSaveResult { case saved, reloaded(String), cancelled }
    var mainSplit: Split? = Split()
    var isEditing: Bool { mainSplit?.isEditingDocument == true }
    var editorDraftMarkdown: String?
    var editorBaselineMarkdown: String?
    var editorChangeRevision = 0
    var hasUnsavedEditorChanges = false
    var inspectorRefreshSessionID = UUID()
    var isEditorCommitInFlight = false
    var pendingEditorCommitRequested = false
    var pendingCommitShouldExit = false
    var pendingCommitCompletions: [(Bool) -> Void] = []
    var pendingUntitledImagePastes: [(data: Data, from: Int, to: Int)] = []
    // Inspector refresh is outside the checkbox/save behavior under test.
    var pendingInspectorComputation: DispatchWorkItem?
    func invalidateInspectorRefresh() {}
    func scheduleInspectorRefresh(from editor: Editor) {}
    func stopAutoSaveTimer() {}
    func startAutoSaveTimerIfNeeded() {}
    func updateFormattingSelection(heading: Int, commands: Set<String>) {}
    var clipboardData: Data? {
        get { NSPasteboard.general.data(forType: .png) }
        set {
            NSPasteboard.general.clearContents()
            if let newValue { NSPasteboard.general.setData(newValue, forType: .png) }
        }
    }
    var imageErrors = 0
    func presentImageError(_ error: Error) { imageErrors += 1 }
    func presentImagePermissionPanel(_ data: Data, markdownURL: URL,
                                     editor: Editor, from: Int, to: Int,
                                     completion: ((Int?) -> Void)? = nil) {
        imageErrors += 1
        completion?(nil)
    }
    func renameImage(at: URL) {}
    func showEditAccessory() {}
    func updateEditToolbarItem() {}
    func exitEditMode(rerender: Bool, preserveUnsavedChanges: Bool = false,
                      hidesAccessoryAfterSwap: Bool = false, completion: () -> Void) {
        mainSplit?.isEditingDocument = false
        if rerender { rerenderCurrentPreview() }
        completion()
    }
    var isPerformingAutomaticSave = false
    // Documents opened from a share link are read-only; not under test here.
    var isReceivedShare = false
    var currentMarkdown: String?
    var currentFileURL: URL?
    var markdownDocument: Document? = Document()
    var documentWindow = Window()
    var rendered = ""
    func resetAutoSaveFeedback() {}
    func refreshOpenWithItem() {}
    func refreshOpenInLLMItem() {}
    func refreshOpenActionsItem() {}
    func startWatching(_ url: URL) {}
    func computeVisibleSidebars(markdown: String, fileURL: URL?, revision: Int, sessionID: UUID) {}
    func renderCurrentDocument(text: String, fileURL: URL) { rendered = text }
    func handleRename(to url: URL) { currentFileURL = url }
'''
for name in ['enterEditMode', 'previewPendingEdits', 'saveUntitledMarkdown', 'commitEdits',
             'performPendingEditorCommit', 'handleEditedMarkdownSaveResult', 'adoptExternalMarkdown',
             'completeSuccessfulEditorCommit', 'finishEditorCommit',
             'diskFileState', 'saveEditedMarkdown', 'toggleTaskCheckbox', 'rerenderCurrentPreview',
             'presentExternalEditConflict', 'presentUnavailableFileConflict',
             'persistEditedMarkdown', 'write']:
    signature = ('private ' if name in ['saveUntitledMarkdown', 'performPendingEditorCommit',
                                       'handleEditedMarkdownSaveResult', 'completeSuccessfulEditorCommit',
                                       'finishEditorCommit', 'presentExternalEditConflict', 'presentUnavailableFileConflict',
                                       'persistEditedMarkdown', 'write'] else '') + 'func ' + name + '('
    swift += extract(source, signature) + '\n'
swift += extract(source, 'private func performPendingEditorCommit(body:') + '\n'
swift += extract(image_source, 'func pasteImage(') + '\n'
swift += extract(image_source, 'private func pasteImage(') + '\n'
swift += extract(image_source, 'private func pasteUntitledImages(') + '\n'
swift += extract(image_source, 'private func insertPastedImage(') + '\n'
swift += extract(image_source, 'private func clipboardPNGData(') + '\n'
swift += '}\n'
swift += 'extension Editor {\n' + extract(editor_source, 'func updateAssetBaseURL(') + '\n}\n'
swift += 'enum MarkdownAssetResolution {\nstatic let scheme = "md-asset"\nstatic let rootBaseHref = "md-asset:///"\n'
for name in ['picturesDirectory', 'nextIntegerFileName', 'savePastedImage', 'markdownPath',
             'encodedMarkdownPath', 'relativePath', 'atomicWrite', 'baseHref']:
    swift += extract(asset_source, 'static func ' + name + '(') + '\n'
swift += '}\n'
swift += 'enum EditorHTML {\n' + extract(
    (root / 'md-preview/Features/Editor/EditorHTML.swift').read_text(),
    'static func jsStringLiteral(') + '\n}\n'
swift += extract((root / 'md-preview/Rendering/EscapingHTMLFormatter.swift').read_text(),
                 'nonisolated enum TaskCheckboxSource')
swift += r'''
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
defer { NSPasteboard.general.releaseGlobally() }
let original = "# Tasks\n\n- [ ] First\n- [x] Second\n"
let checked = "# Tasks\n\n- [x] First\n- [x] Second\n"
let external = original + "\nExternal change\n"
func fixture(_ name: String) throws -> Controller {
    let c = Controller()
    c.currentFileURL = directory.appendingPathComponent(name + ".md")
    c.currentMarkdown = original
    try original.write(to: c.currentFileURL!, atomically: true, encoding: .utf8)
    return c
}
func disk(_ c: Controller) throws -> String { try String(contentsOf: c.currentFileURL!, encoding: .utf8) }
func tryDisk(_ c: Controller) -> String { try! disk(c) }
func respond(_ response: Response) {
    let callback = NSAlert.respond!
    NSAlert.respond = nil
    callback(response)
}
let normal = try fixture("normal")
normal.toggleTaskCheckbox(onLine: 3, checked: true)
precondition(tryDisk(normal) == checked)
precondition(normal.currentMarkdown == checked && normal.rendered == checked)
normal.toggleTaskCheckbox(onLine: 3, checked: false)
precondition(tryDisk(normal) == original)

for choice in [Response.alertFirstButtonReturn, .alertSecondButtonReturn, .cancel] {
    let c = try fixture("conflict-\(choice)")
    try external.write(to: c.currentFileURL!, atomically: true, encoding: .utf8)
    c.toggleTaskCheckbox(onLine: 3, checked: true)
    precondition(tryDisk(c) == external, "No write before conflict decision")
    respond(choice)
    let expectedDisk = choice == .alertFirstButtonReturn ? checked : external
    let expectedPreview = choice == .cancel ? original : expectedDisk
    precondition(tryDisk(c) == expectedDisk)
    precondition(c.currentMarkdown == expectedPreview && c.rendered == expectedPreview)
}
// Exercise actual enter/preview methods, retaining an unsaved draft in Read Mode.
for choice in [Response.alertFirstButtonReturn, .alertSecondButtonReturn, .cancel] {
    let c = try fixture("draft-\(choice)")
    c.enterEditMode()
    let draft = original + "\nUnsaved paragraph\n"
    c.mainSplit!.editorViewController!.markdown = draft
    c.mainSplit!.editorViewController!.contentDidChange?()
    c.previewPendingEdits()
    precondition(c.editorDraftMarkdown == draft && c.hasUnsavedEditorChanges)
    c.toggleTaskCheckbox(onLine: 3, checked: true)
    respond(choice)
    let expected = choice == .alertFirstButtonReturn
        ? checked + "\nUnsaved paragraph\n" : choice == .cancel ? draft : original
    let expectedDisk = choice == .alertFirstButtonReturn ? expected : original
    precondition(tryDisk(c) == expectedDisk)
    precondition(c.hasUnsavedEditorChanges == (choice == .cancel))
    if choice != .cancel {
        precondition(c.editorDraftMarkdown == nil && c.editorBaselineMarkdown == nil)
        precondition(c.editorChangeRevision == 0)
    }
    c.enterEditMode()
    precondition(c.mainSplit!.editorViewController!.markdown == expected,
                 "Reentering Edit Mode must not resurrect the rejected draft")
    precondition(c.editorBaselineMarkdown == expectedDisk)
}
// A rename while either conflict choice waits must neither recreate the old
// file nor show an unsaved checkbox value under the renamed document.
for choice in [Response.alertFirstButtonReturn, .alertSecondButtonReturn] {
    let c = try fixture("rename-\(choice)")
    let old = c.currentFileURL!
    try external.write(to: old, atomically: true, encoding: .utf8)
    c.toggleTaskCheckbox(onLine: 3, checked: true)
    let moved = directory.appendingPathComponent("moved-\(choice).md")
    try FileManager.default.moveItem(at: old, to: moved)
    c.handleRename(to: moved)
    c.currentMarkdown = external
    respond(choice)
    precondition(!FileManager.default.fileExists(atPath: old.path))
    precondition(tryDisk(c) == external)
    precondition(c.currentMarkdown == external && c.rendered == external)
}
let missing = try fixture("missing")
let old = missing.currentFileURL!
try FileManager.default.removeItem(at: old)
missing.toggleTaskCheckbox(onLine: 3, checked: true)
let other = try fixture("other")
missing.currentFileURL = other.currentFileURL
missing.currentMarkdown = external
respond(.alertFirstButtonReturn)
precondition(!FileManager.default.fileExists(atPath: old.path))
precondition(tryDisk(other) == original)

// Force a permission-panel path with a nonexistent parent, then navigate away.
let permission = Controller()
permission.currentMarkdown = original
permission.currentFileURL = directory.appendingPathComponent("absent/file.md")
permission.toggleTaskCheckbox(onLine: 3, checked: true)
respond(.alertFirstButtonReturn)
precondition(NSSavePanel.respond != nil)
let chosen = directory.appendingPathComponent("chosen.md")
NSSavePanel.pending!.url = chosen
permission.currentFileURL = other.currentFileURL
permission.currentMarkdown = original
NSSavePanel.respond!(.OK)
precondition(!FileManager.default.fileExists(atPath: chosen.path))
precondition(tryDisk(other) == original)
NSSavePanel.respond = nil
NSSavePanel.pending = nil

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .calibratedRGB, bytesPerRow: 4, bitsPerPixel: 32)!
bitmap.setColor(.red, atX: 0, y: 0)
let imageData = bitmap.representation(using: .png, properties: [:])!
let untitled = Controller()
untitled.currentMarkdown = "Before selected after"
untitled.enterEditMode()
untitled.clipboardData = imageData
untitled.pasteImage(at: 7, replacing: 15)
guard let imageSavePanel = NSSavePanel.pending, let saveImageDocument = NSSavePanel.respond else {
    fatalError("Image paste into an untitled document must prompt to save, not silently return")
}
let imageDocumentURL = directory.appendingPathComponent("中文 Paste (1).md")
imageSavePanel.url = imageDocumentURL
NSSavePanel.respond = nil
NSSavePanel.pending = nil
// A save sheet can outlive the clipboard contents; use the image originally pasted.
untitled.clipboardData = nil
saveImageDocument(.OK)
let imagesDirectory = MarkdownAssetResolution.picturesDirectory(forMarkdownFile: imageDocumentURL)
let firstImage = imagesDirectory.appendingPathComponent("1.png")
let firstImagePath = MarkdownAssetResolution.markdownPath(for: firstImage, from: imageDocumentURL)!
let imageMarkdown = "Before ![1](\(firstImagePath)) after"
precondition(tryDisk(untitled) == imageMarkdown, "First paste must save the image reference at the original selection")
precondition(untitled.mainSplit!.editorViewController!.markdown == imageMarkdown)
precondition(try! Data(contentsOf: firstImage) == imageData, "Paste must retain the original image during Save")
let savedEditor = untitled.mainSplit!.editorViewController!
precondition(savedEditor.currentAssetBaseURL?.path == directory.path,
             "First Save must update the live editor's asset directory")
precondition(savedEditor.assetScheme.baseURL?.path == directory.path,
             "First Save must enable the editor's asset scheme")
precondition(savedEditor.webView.scripts.last?.contains(
    EditorHTML.jsStringLiteral(MarkdownAssetResolution.baseHref(forFolder: directory))) == true,
    "First Save must send the saved folder's href to the live page")
precondition(untitled.imageErrors == 0 && untitled.isEditing)
untitled.clipboardData = imageData
let end = (imageMarkdown as NSString).length
untitled.pasteImage(at: end, replacing: end)
precondition(NSSavePanel.pending == nil, "A saved document must not prompt to save on every image paste")
precondition(FileManager.default.fileExists(atPath: imagesDirectory.appendingPathComponent("2.png").path))
precondition(tryDisk(untitled).contains("/2.png)"))

for (selection, name) in [("selected", "queued"),
                          (String(repeating: "selected ", count: 12), "long-queued"),
                          ("", "empty-queued")] {
    let c = Controller()
    let prefix = "中文😀 Before "
    let draft = prefix + selection + " after"
    c.currentMarkdown = draft
    c.enterEditMode()
    let editor = c.mainSplit!.editorViewController!
    editor.defersInsertions = true
    c.clipboardData = imageData
    let from = prefix.utf16.count
    let to = from + selection.utf16.count
    c.pasteImage(at: from, replacing: to)
    let panel = NSSavePanel.pending!
    let save = NSSavePanel.respond!
    c.pasteImage(at: from, replacing: to)
    c.pasteImage(at: from, replacing: to)
    precondition(NSSavePanel.pending === panel, "Queued pastes must share the first save sheet")
    panel.url = directory.appendingPathComponent(name + ".md")
    NSSavePanel.pending = nil
    NSSavePanel.respond = nil
    c.clipboardData = nil
    save(.OK)
    for _ in 0..<3 {
        precondition(editor.pendingInsertions.count == 1,
                     "Each queued paste must wait for the preceding insertion")
        editor.pendingInsertions.removeFirst()()
    }
    let expected = prefix + (1...3).map { "![\($0)](\(name)-pictures/\($0).png)" }.joined() + " after"
    precondition(tryDisk(c) == expected && editor.markdown == expected,
                 "Queued pastes must preserve every image reference and the trailing text")
    precondition(editor.pendingInsertions.isEmpty && c.pendingUntitledImagePastes.isEmpty)
}

let cancelledPaste = Controller()
cancelledPaste.currentMarkdown = "Keep this draft"
cancelledPaste.enterEditMode()
cancelledPaste.clipboardData = imageData
cancelledPaste.pasteImage(at: 0, replacing: 0)
cancelledPaste.pasteImage(at: 0, replacing: 0)
let cancelImageSave = NSSavePanel.respond!
NSSavePanel.respond = nil
NSSavePanel.pending = nil
cancelImageSave(.cancel)
precondition(cancelledPaste.currentFileURL == nil && cancelledPaste.isEditing)
precondition(cancelledPaste.mainSplit!.editorViewController!.markdown == "Keep this draft")
precondition(!cancelledPaste.isEditorCommitInFlight)
precondition(cancelledPaste.pendingUntitledImagePastes.isEmpty,
             "Cancelling Save must discard every pending image paste")

cancelledPaste.clipboardData = Data([0x89, 0x50, 0x4e, 0x47])
cancelledPaste.pasteImage(at: 0, replacing: 0)
precondition(cancelledPaste.imageErrors == 1 && NSSavePanel.pending == nil,
             "Invalid image data must report an error before requesting a document location")
let tiff = bitmap.tiffRepresentation!
NSPasteboard.general.setData(tiff, forType: .tiff)
cancelledPaste.pasteImage(at: 0, replacing: 0)
precondition(cancelledPaste.imageErrors == 1 && NSSavePanel.pending != nil,
             "A malformed PNG must fall through to the valid TIFF representation")
NSPasteboard.general.clearContents()
NSSavePanel.respond!(.cancel)
NSSavePanel.respond = nil
NSSavePanel.pending = nil
print("PASS: untitled image paste, original clipboard and selection retention, first-save asset base, queued paste, cancellation, malformed PNG and TIFF fallback")
print("PASS: checkbox disk writes, draft preview and editor reentry for all conflict choices, rename during conflict, missing-file navigation, permission-panel navigation")
'''
with tempfile.TemporaryDirectory(prefix='checkbox-save-tests-') as directory:
    path = Path(directory) / 'probe.swift'
    path.write_text(swift)
    subprocess.run(['swift', str(path), str(Path(directory) / 'files')], check=True)
