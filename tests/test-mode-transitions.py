"""Run real transition method bodies against controllable WebKit callbacks.

The app controller is not part of the helper Swift package. Extract its methods
unchanged (apart from access control) so these scheduling regressions exercise
production logic, rather than a second implementation of the state machine.
This does not replace native visual verification.
"""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'md-preview/Document/MainSplitViewController.swift').read_text()
def method(name):
    start = source.index('    ' + name)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private func', 'func')

swift = '''
import Foundation
struct SourceScrollAnchor {}
struct Deadline { static func now() -> Self { Self() }; static func +(lhs: Self, rhs: Double) -> Self { lhs } }
@MainActor enum DispatchQueue {
    static let main = Queue()
    final class Queue {
        var pending: [() -> Void] = []
        var deadlines: [() -> Void] = []
        func async(_ body: @escaping () -> Void) { pending.append(body) }
        func asyncAfter(deadline: Deadline, execute: @escaping () -> Void) { deadlines.append(execute) }
    }
}
@MainActor final class View {
    var alphaValue: Double = 1; var isHidden = false
    var translatesAutoresizingMaskIntoConstraints = true
}
@MainActor final class Host { func installEditorOverlay(_ editor: EditorViewController) {} }
@MainActor final class EditorViewController {
    let view = View()
    var editorDidBecomeReady: (() -> Void)?
    var anchorCallback: ((SourceScrollAnchor?) -> Void)?
    var scrollCallback: (() -> Void)?
    var findOverlay: View?
    func loadViewIfNeeded() {}
    func load(markdown: String, assetBaseURL: URL?) {}
    func applyPageZoom(_ zoom: Double) {}
    func fetchScrollAnchor(_ body: @escaping (SourceScrollAnchor?) -> Void) { anchorCallback = body }
    func applyScrollProgress(_ p: Double, sourceAnchor: SourceScrollAnchor?, completion: @escaping () -> Void) { scrollCallback = completion }
    func focusEditor() {}
}
@MainActor final class Preview {
    let view = View()
    var pendingAnchorRestored: (() -> Void)?
    var restoreCompletion: (() -> Void)?
    var pageZoom: Double = 1
    var scrollProgress: Double = 0
    func sourceScrollAnchor(_ completion: (SourceScrollAnchor?) -> Void) { completion(nil) }
    func prepareToRestoreSourceScrollAnchor(_ anchor: SourceScrollAnchor?) {}
    func restoreSourceScrollAnchor(_ anchor: SourceScrollAnchor, completion: (() -> Void)? = nil) { restoreCompletion = completion }
}
@MainActor final class Controller {
    var cachedEditorViewController: EditorViewController? = EditorViewController()
    var contentViewController: Preview? = Preview()
    var isEditorPreparing = false
    var isEditorVisible = false
    var isEditorExiting = false
    var pendingExitCompletions: [() -> Void] = []
    var layeredContentViewController: Host? = Host()
    var findOverlayView: View?
    var editorViewController: EditorViewController? { isEditingDocument ? cachedEditorViewController : nil }
    var editModeGeneration = UUID()
    var pendingSourceScrollAnchor: SourceScrollAnchor?
    var isSourceScrollAnchorResolved = true
    var isEditorDOMReady = true
    var pendingPreviewScrollProgress: Double = 0
    var shouldAutofocusEditor = false
    func refreshFindAfterModeChange() {}
'''
swift += '\n'.join(method(name) for name in [
    'var isEditingDocument:', 'func enterEditMode',
    'private func revealEditorIfPrepared', 'func exitEditMode'
]) + '\n}\n'
swift += '''
@MainActor func probe() {
    let a = Controller()
    a.isEditorPreparing = true
    a.cachedEditorViewController!.view.alphaValue = 0
    a.revealEditorIfPrepared(a.cachedEditorViewController!)
    let queuedEntry = a.cachedEditorViewController!.scrollCallback!
    var exitCount = 0
    a.exitEditMode(waitForPreviewRender: false, completion: { exitCount += 1 })
    queuedEntry()
    DispatchQueue.main.pending.forEach { $0() }
    precondition(!a.isEditorVisible, "Exit during preparation must cancel reveal")
    let exitGeneration = a.editModeGeneration
    _ = a.enterEditMode(markdown: "new entry")
    precondition(a.editModeGeneration == exitGeneration, "Entry invalidated a pending exit")
    precondition(a.isEditingDocument, "Pending exit lost its editing state")
    a.cachedEditorViewController!.anchorCallback?(SourceScrollAnchor())
    precondition(exitCount == 0, "Exit completed before restoration")
    a.contentViewController!.restoreCompletion?()
    precondition(exitCount == 1, "Exit completion was lost")
    precondition(!a.isEditingDocument, "Completed exit still reports editing")

    let b = Controller()
    b.isEditorVisible = true
    b.contentViewController!.view.isHidden = true
    var renderStarts = 0
    b.exitEditMode(waitForPreviewRender: true, completion: { renderStarts += 1 })
    b.cachedEditorViewController!.anchorCallback?(SourceScrollAnchor())
    precondition(renderStarts == 1, "Render-wait exit must start rendering before reveal")
    precondition(b.contentViewController!.view.isHidden, "Render-wait exit revealed too early")
    let oldDeadline = DispatchQueue.main.deadlines.last!
    b.contentViewController!.pendingAnchorRestored?()
    // A new entry completes before a second anchored exit begins.
    b.isEditorVisible = true
    b.contentViewController!.view.isHidden = true
    b.contentViewController!.pendingAnchorRestored = nil
    b.exitEditMode(waitForPreviewRender: true, completion: {})
    b.cachedEditorViewController!.anchorCallback?(SourceScrollAnchor())
    oldDeadline()
    precondition(b.contentViewController!.pendingAnchorRestored != nil, "Old deadline stole current callback")
    precondition(b.contentViewController!.view.isHidden, "Old deadline revealed preview")
    b.contentViewController!.pendingAnchorRestored?()
    precondition(!b.contentViewController!.view.isHidden, "Current restoration must reveal preview")

    let c = Controller()
    c.isEditorVisible = true
    c.contentViewController!.view.isHidden = true
    var completed = 0
    c.exitEditMode(waitForPreviewRender: false, completion: { completed += 1 })
    var duplicateCompleted = 0
    c.exitEditMode(waitForPreviewRender: false, completion: { duplicateCompleted += 1 })
    c.cachedEditorViewController!.anchorCallback?(SourceScrollAnchor())
    precondition(c.contentViewController!.view.isHidden, "Preview revealed before restoration")
    precondition(completed == 0 && duplicateCompleted == 0, "No-render exit completed too early")
    c.contentViewController!.restoreCompletion?()
    precondition(!c.contentViewController!.view.isHidden, "Completed restoration must reveal preview")
    precondition(c.cachedEditorViewController!.view.isHidden, "Completed exit must hide editor")
    c.contentViewController!.restoreCompletion?()
    precondition(completed == 1 && duplicateCompleted == 1, "Exit callbacks must settle exactly once")
    let d = Controller()
    d.isEditorVisible = true
    var immediate = 0
    d.exitEditMode(waitForPreviewRender: false, completion: { immediate += 1 })
    d.cachedEditorViewController!.anchorCallback?(nil)
    precondition(immediate == 1 && !d.isEditingDocument, "No-anchor exit must settle immediately")
    print("PASS: preparation cancellation, stale deadline rejection, and restoration ordering")
}
await probe()
'''
with tempfile.TemporaryDirectory(prefix='mode-review-probe-') as directory:
    path = Path(directory) / 'probe.swift'
    path.write_text(swift)
    subprocess.run(['swift', str(path)], check=True)
