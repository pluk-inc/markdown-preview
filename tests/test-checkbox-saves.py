"""Exercise production checkbox/save methods with real temporary files.

Like test-mode-transitions.py, extract controller methods because the app
controllers are not in the helper package. Only AppKit sheet presentation and
rendering are stand-ins; parsing, conflict decisions and disk writes are real.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'md-preview/Document/DocumentWindowController+EditSession.swift').read_text()


def extract(text, signature):
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


swift = r'''
import Foundation

enum Response { case alertFirstButtonReturn, alertSecondButtonReturn, cancel, OK }
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
final class Document {
    var contents = ""
    func replaceContents(markdown: String, fileURL: URL? = nil) { contents = markdown }
}
enum NSSound { static func beep() {} }
// What the session needs of an editor, as in production.
protocol DocumentEditor: AnyObject {
    var contentDidChange: (() -> Void)? { get set }
    var cancelRequested: (() -> Void)? { get set }
    func fetchMarkdown(_ completion: @escaping (String?) -> Void)
}
final class Editor: DocumentEditor {
    var markdown = ""
    var cancelRequested: (() -> Void)?
    var contentDidChange: (() -> Void)?
    var formattingDidChange: ((Int, Set<String>, String?) -> Void)?
    var pasteImageRequested: ((Int, Int) -> Void)?
    var imageClicked: ((URL) -> Void)?
    func fetchMarkdown(_ completion: @escaping (String?) -> Void) { completion(markdown) }
}
typealias EditorViewController = Editor
// The native renderer's view: another type than the web editor, as in
// production, with only what each editor has.
final class NativeEditor: DocumentEditor {
    var markdown = ""
    var cancelRequested: (() -> Void)?
    var contentDidChange: (() -> Void)?
    func fetchMarkdown(_ completion: @escaping (String?) -> Void) { completion(markdown) }
    // Edit Mode starts with a caret in the view.
    var caretsPlaced = 0
    func placeCaretInView() { caretsPlaced += 1 }
}
final class Window { func makeFirstResponder(_ responder: AnyObject?) {} }
final class Split {
    var isEditingDocument = false
    var editorViewController: Editor? = Editor()
    // The native renderer's view, when a case has one: it is the editor
    // then, and the web editor is not used.
    var nativeEditor: NativeEditor?
    var isNativeEditing = false
    var documentEditor: (any DocumentEditor)? { isNativeEditing ? nativeEditor : editorViewController }
    func enterNativeEditMode() -> NativeEditor? {
        guard let nativeEditor else { return nil }
        isEditingDocument = true
        isNativeEditing = true
        return nativeEditor
    }
    var onLiveMetadataNeedsRefresh: (() -> Void)?
    func updateInspectorSelection(_ text: String?) {}
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
    // Inspector refresh is outside the checkbox/save behavior under test.
    var pendingInspectorComputation: DispatchWorkItem?
    func invalidateInspectorRefresh() {}
    func scheduleInspectorRefresh(from editor: any DocumentEditor) {}
    func stopAutoSaveTimer() {}
    func startAutoSaveTimerIfNeeded() {}
    func updateFormattingSelection(heading: Int, commands: Set<String>) {}
    func pasteImage(at: Int, replacing: Int) {}
    func renameImage(at: URL) {}
    func showEditAccessory() {}
    func updateEditToolbarItem() {}
    func releaseDownloadPlaceholder() {}
    func exitEditMode(rerender: Bool, preserveUnsavedChanges: Bool,
                      hidesAccessoryAfterSwap: Bool, completion: () -> Void) {
        mainSplit?.isEditingDocument = false
        mainSplit?.isNativeEditing = false
        if rerender { rerenderCurrentPreview() }
        completion()
    }
    var isPerformingAutomaticSave = false
    // Received shares and release notes are read-only; not under test here.
    var isReadOnlyDocument = false
    var currentMarkdown: String?
    var currentFileURL: URL?
    var markdownDocument: Document? = Document()
    var documentWindow = Window()
    var rendered = ""
    func renderCurrentDocument(text: String, fileURL: URL) { rendered = text }
    func handleRename(to url: URL) { currentFileURL = url }
'''
for name in ['enterEditMode', 'beginEditorBaseline', 'editorContentDidChange', 'previewPendingEdits', 'diskFileState', 'saveEditedMarkdown', 'toggleTaskCheckbox', 'rerenderCurrentPreview',
             'presentExternalEditConflict', 'presentUnavailableFileConflict',
             'persistEditedMarkdown', 'write']:
    signature = ('private ' if name in ['presentExternalEditConflict', 'presentUnavailableFileConflict',
                                       'persistEditedMarkdown', 'write',
                                       'beginEditorBaseline', 'editorContentDidChange'] else '') + 'func ' + name + '('
    swift += extract(source, signature) + '\n'
swift += '}\n'
swift += extract((root / 'md-preview/Rendering/EscapingHTMLFormatter.swift').read_text(),
                 'nonisolated enum TaskCheckboxSource')
swift += r'''
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
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
// The native renderer's view as the editor: the session takes the text
// from it, wires only what each editor has, and leaves the web editor alone.
do {
    let c = try fixture("native")
    let native = NativeEditor()
    native.markdown = original
    c.mainSplit!.nativeEditor = native
    c.enterEditMode()
    precondition(c.isEditing && c.mainSplit!.documentEditor === native, "The native view must be the editor")
    precondition(native.contentDidChange != nil && native.cancelRequested != nil)
    precondition(native.caretsPlaced == 1, "Edit Mode in the native view must start with a caret")
    precondition(c.mainSplit!.editorViewController!.contentDidChange == nil,
                 "The web editor must not be wired in the native view's Edit Mode")
    let draft = original + "\nTyped in the native view\n"
    native.markdown = draft
    native.contentDidChange?()
    precondition(c.hasUnsavedEditorChanges && c.editorChangeRevision == 1)
    native.cancelRequested?()
    precondition(!c.isEditing, "Escape must leave Edit Mode")
    precondition(c.editorDraftMarkdown == draft && c.currentMarkdown == draft && c.rendered == draft,
                 "The draft must come from the native view")
    precondition(c.mainSplit!.editorViewController!.markdown != draft)
    precondition(tryDisk(c) == original, "A preview of the edits is no save")
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
print("PASS: checkbox disk writes, draft preview and editor reentry for all conflict choices, the native view as the editor, rename during conflict, missing-file navigation, permission-panel navigation")
'''
with tempfile.TemporaryDirectory(prefix='checkbox-save-tests-') as directory:
    path = Path(directory) / 'probe.swift'
    path.write_text(swift)
    subprocess.run(['swift', str(path)], check=True)
