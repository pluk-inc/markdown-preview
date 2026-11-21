import AppKit
import os

/// Keeps one reader web view with its empty page already loaded, so the
/// second and later document windows, and a window opened after the last
/// one was closed, skip WKWebView creation and the WebContent process
/// launch. The first document of a cold launch never waits for a spare: the
/// pool fills only after a document has painted or a window has closed,
/// because preparing a reader during launch competes with that document.
@MainActor
final class SpareReaderPool {
    static let shared = SpareReaderPool()

    /// Launch argument / default that turns the pool off, for A/B timing.
    private static let disabledDefaultsKey = "MarkdownPreview.disableSpareReader"
    /// Gives the painted document's lazy renderers the main thread first.
    private static let replenishDelay: DispatchTimeInterval = .seconds(1)

    private var spare: MarkdownWebView?
    private var spareSettings: ReaderRenderSettings?

    /// Off for A/B timing, and while the native renderer draws documents:
    /// a spare would start WebKit for a page nobody shows.
    private var isEnabled: Bool {
        !UserDefaults.standard.bool(forKey: Self.disabledDefaultsKey) && RendererSetting.current == .web
    }

    /// Hands over the spare, or a fresh reader when there is none. A spare
    /// whose empty page predates a settings change still has a running
    /// WebContent process, so it is kept but made to load the full page.
    func takeReader() -> MarkdownWebView {
        guard let spare else {
            logTake("fresh")
            return MarkdownWebView()
        }
        self.spare = nil
        if spareSettings != ReaderRenderSettings.current {
            spare.discardLoadedPage()
            logTake("stale-spare")
        } else {
            logTake(spare.isReadyAsSpare ? "spare" : "loading-spare")
        }
        return spare
    }

    /// Call once a document's content is on screen. Prepares a spare after a
    /// short idle delay, if there is none yet.
    func documentDidPaint() {
        guard isEnabled, spare == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.replenishDelay) { [weak self] in
            self?.prepareSpareIfNeeded()
        }
    }

    /// Prepares a spare now, if there is none. The spare stays while the
    /// app has no window: a reopen from the Dock then shows its text with
    /// the window, for about 30 MB of idle memory (one WebContent process
    /// with an empty page, and the GPU process it keeps alive).
    func prepareSpareIfNeeded() {
        guard isEnabled, spare == nil else { return }
        spareSettings = ReaderRenderSettings.current
        spare = MarkdownWebView(spare: true)
    }

    private func logTake(_ kind: String) {
        #if DEBUG
        Logger.perf.debug(
            "[mdp-perf-open] reader \(kind, privacy: .public) t=\(DispatchTime.now().uptimeNanoseconds, privacy: .public)"
        )
        #endif
    }
}
