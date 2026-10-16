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
    func beginSheetModal(for window: Int, completionHandler: @escaping (Response) -> Void) {
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
    func beginSheetModal(for window: Int, completionHandler: @escaping (Response) -> Void) {
        Self.pending = self
        Self.respond = completionHandler
    }
}
enum SaveConflictSheet {
    static var snapshots: [(draft: String, disk: String, changedAgain: Bool)] = []
    static func make(localMarkdown: String, externalMarkdown: String,
                     fileName: String, changedAgain: Bool) -> NSAlert {
        snapshots.append((localMarkdown, externalMarkdown, changedAgain))
        return NSAlert()
    }
}
final class Document {
    var contents = ""
    func replaceContents(markdown: String, fileURL: URL? = nil) { contents = markdown }
}
enum NSSound { static func beep() {} }
final class Editor {
    var markdown = ""
    var cancelRequested: (() -> Void)?
    var contentDidChange: (() -> Void)?
    var formattingDidChange: ((Int, [String]) -> Void)?
    var pasteImageRequested: ((Int, Int) -> Void)?
    var imageClicked: ((URL) -> Void)?
    func fetchMarkdown(_ completion: (String?) -> Void) { completion(markdown) }
}
final class Split {
    var isEditingDocument = false
    var editorViewController: Editor? = Editor()
    var onLiveMetadataNeedsRefresh: (() -> Void)?
    func enterEditMode(markdown: String, assetBaseURL: URL?, autofocus: Bool) -> Editor {
        isEditingDocument = true
        editorViewController!.markdown = markdown
        return editorViewController!
    }
}
final class Controller {
    enum DiskFileState { case unchanged(String), modified(String), missing, unreadable }
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
    func scheduleInspectorRefresh(from editor: Editor) {}
    func stopAutoSaveTimer() {}
    func startAutoSaveTimerIfNeeded() {}
    func updateFormattingSelection(heading: Int, commands: [String]) {}
    func pasteImage(at: Int, replacing: Int) {}
    func renameImage(at: URL) {}
    func showEditAccessory() {}
    func updateEditToolbarItem() {}
    func exitEditMode(rerender: Bool, preserveUnsavedChanges: Bool,
                      hidesAccessoryAfterSwap: Bool, completion: () -> Void) {
        mainSplit?.isEditingDocument = false
        if rerender { rerenderCurrentPreview() }
        completion()
    }
    var isPerformingAutomaticSave = false
    var currentMarkdown: String?
    var currentFileURL: URL?
    var markdownDocument: Document? = Document()
    var documentWindow = 0
    var rendered = ""
    var errors = 0
    func presentError(_ error: Error) { errors += 1 }
    func renderCurrentDocument(text: String, fileURL: URL) { rendered = text }
    func handleRename(to url: URL) { currentFileURL = url }
'''
for name in ['enterEditMode', 'previewPendingEdits', 'diskFileState', 'saveEditedMarkdown', 'toggleTaskCheckbox', 'rerenderCurrentPreview',
             'presentExternalEditConflict', 'presentUnavailableFileConflict',
             'persistEditedMarkdown', 'write']:
    signature = ('private ' if name in ['presentExternalEditConflict', 'presentUnavailableFileConflict',
                                       'persistEditedMarkdown', 'write'] else '') + 'func ' + name + '('
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

// The user must compare a second external write before either destructive
// choice can apply. Cancellation preserves both the local draft and disk.
for choice in [Response.alertFirstButtonReturn, .alertSecondButtonReturn] {
    let c = try fixture("changed-again-\(choice)")
    c.enterEditMode()
    let draft = original + "\nHuman draft\n"
    c.mainSplit!.editorViewController!.markdown = draft
    c.mainSplit!.editorViewController!.contentDidChange?()
    c.previewPendingEdits()
    try external.write(to: c.currentFileURL!, atomically: true, encoding: .utf8)
    c.toggleTaskCheckbox(onLine: 3, checked: true)
    precondition(SaveConflictSheet.snapshots.last!.disk == external)
    let newer = external + "\nAnother agent write\n"
    try newer.write(to: c.currentFileURL!, atomically: true, encoding: .utf8)
    respond(choice)
    precondition(tryDisk(c) == newer && c.editorDraftMarkdown == draft)
    precondition(SaveConflictSheet.snapshots.last!.changedAgain)
    precondition(SaveConflictSheet.snapshots.last!.disk == newer)
    precondition(SaveConflictSheet.snapshots.last!.draft == checked + "\nHuman draft\n")
    respond(.cancel)
    precondition(tryDisk(c) == newer && c.editorDraftMarkdown == draft)
    precondition(c.hasUnsavedEditorChanges)
    c.enterEditMode()
    precondition(c.mainSplit!.editorViewController!.markdown == draft)
}
for choice in [Response.alertFirstButtonReturn, .alertSecondButtonReturn] {
    let c = try fixture("removed-during-diff-\(choice)")
    try external.write(to: c.currentFileURL!, atomically: true, encoding: .utf8)
    c.toggleTaskCheckbox(onLine: 3, checked: true)
    try FileManager.default.removeItem(at: c.currentFileURL!)
    respond(choice)
    precondition(!FileManager.default.fileExists(atPath: c.currentFileURL!.path))
    precondition(c.errors == 1 && c.currentMarkdown == original)
}
let identical = try fixture("identical")
try checked.write(to: identical.currentFileURL!, atomically: true, encoding: .utf8)
identical.toggleTaskCheckbox(onLine: 3, checked: true)
precondition(NSAlert.respond == nil && tryDisk(identical) == checked)

// A permission sheet is another asynchronous boundary after diff review.
// Make the actual write fail, then change the file before granting access.
let guarded = try fixture("permission-after-diff")
try external.write(to: guarded.currentFileURL!, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: guarded.currentFileURL!.path)
try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
guarded.toggleTaskCheckbox(onLine: 3, checked: true)
respond(.alertFirstButtonReturn)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: guarded.currentFileURL!.path)
precondition(NSSavePanel.pending!.nameFieldStringValue == guarded.currentFileURL!.lastPathComponent)
let afterPermission = external + "\nChanged during save permission\n"
try afterPermission.write(to: guarded.currentFileURL!, atomically: true, encoding: .utf8)
NSSavePanel.pending!.url = guarded.currentFileURL
NSSavePanel.respond!(.OK)
precondition(tryDisk(guarded) == afterPermission)
precondition(SaveConflictSheet.snapshots.last!.disk == afterPermission)
respond(.cancel)
precondition(tryDisk(guarded) == afterPermission)

// The same guard applies when the permission panel opened for an ordinary
// save, before there was any external conflict to compare.
let ordinary = try fixture("permission-before-conflict")
try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ordinary.currentFileURL!.path)
try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
ordinary.toggleTaskCheckbox(onLine: 3, checked: true)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ordinary.currentFileURL!.path)
precondition(NSAlert.respond == nil)
precondition(NSSavePanel.pending!.nameFieldStringValue == ordinary.currentFileURL!.lastPathComponent)
try external.write(to: ordinary.currentFileURL!, atomically: true, encoding: .utf8)
NSSavePanel.pending!.url = ordinary.currentFileURL
NSSavePanel.respond!(.OK)
precondition(tryDisk(ordinary) == external)
precondition(SaveConflictSheet.snapshots.last!.disk == external)
respond(.cancel)
precondition(tryDisk(ordinary) == external)

print("PASS: checkbox disk writes, draft preview and editor reentry for all conflict choices, rename during conflict, missing-file navigation, permission-panel navigation")
print("PASS: compared snapshots, repeated external writes, preserved drafts, deleted files, identical changes and writes during permission prompts")
'''
with tempfile.TemporaryDirectory(prefix='checkbox-save-tests-') as directory:
    path = Path(directory) / 'probe.swift'
    path.write_text(swift)
    subprocess.run(['swift', str(path)], check=True)
