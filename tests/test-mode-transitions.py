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
@MainActor final class View { var alphaValue: Double = 1; var isHidden = false }
@MainActor final class EditorViewController {
    let view = View()
    var editorDidBecomeReady: (() -> Void)?
    var anchorCallback: ((SourceScrollAnchor?) -> Void)?
    var scrollCallback: (() -> Void)?
    func fetchScrollAnchor(_ body: @escaping (SourceScrollAnchor?) -> Void) { anchorCallback = body }
    func applyScrollProgress(_ p: Double, sourceAnchor: SourceScrollAnchor?, completion: @escaping () -> Void) { scrollCallback = completion }
    func focusEditor() {}
}
@MainActor final class Preview {
    let view = View()
    var pendingAnchorRestored: (() -> Void)?
    var restoreCompletion: (() -> Void)?
    func prepareToRestoreSourceScrollAnchor(_ anchor: SourceScrollAnchor?) {}
    func restoreSourceScrollAnchor(_ anchor: SourceScrollAnchor, completion: (() -> Void)? = nil) { restoreCompletion = completion }
}
@MainActor final class Controller {
    var cachedEditorViewController: EditorViewController? = EditorViewController()
    var contentViewController: Preview? = Preview()
    var isEditorPreparing = false
    var isEditorVisible = false
    var editModeGeneration = UUID()
    var pendingSourceScrollAnchor: SourceScrollAnchor?
    var isSourceScrollAnchorResolved = true
    var isEditorDOMReady = true
    var pendingPreviewScrollProgress: Double = 0
    var shouldAutofocusEditor = false
    func refreshFindAfterModeChange() {}
'''
swift += method('private func revealEditorIfPrepared') + '\n' + method('func exitEditMode') + '\n}\n'
swift += '''
@MainActor func probe() {
    let a = Controller()
    a.isEditorPreparing = true
    a.cachedEditorViewController!.view.alphaValue = 0
    a.exitEditMode(waitForPreviewRender: true, completion: {})
    a.revealEditorIfPrepared(a.cachedEditorViewController!)
    a.cachedEditorViewController!.scrollCallback?()
    DispatchQueue.main.pending.forEach { $0() }
    precondition(!a.isEditorVisible, "Exit during preparation must cancel reveal")

    let b = Controller()
    b.isEditorVisible = true
    b.contentViewController!.view.isHidden = true
    b.exitEditMode(waitForPreviewRender: true, completion: {})
    b.cachedEditorViewController!.anchorCallback?(SourceScrollAnchor())
    let oldDeadline = DispatchQueue.main.deadlines.last!
    // A new entry completes before a second anchored exit begins.
    b.isEditorVisible = true
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
    c.exitEditMode(waitForPreviewRender: false, completion: {})
    c.cachedEditorViewController!.anchorCallback?(SourceScrollAnchor())
    precondition(c.contentViewController!.view.isHidden, "Preview revealed before restoration")
    c.contentViewController!.restoreCompletion?()
    precondition(!c.contentViewController!.view.isHidden, "Completed restoration must reveal preview")
    precondition(c.cachedEditorViewController!.view.isHidden, "Completed exit must hide editor")
    print("PASS: preparation cancellation, stale deadline rejection, and restoration ordering")
}
await probe()
'''
with tempfile.TemporaryDirectory(prefix='mode-review-probe-') as directory:
    path = Path(directory) / 'probe.swift'
    path.write_text(swift)
    subprocess.run(['swift', str(path)], check=True)
