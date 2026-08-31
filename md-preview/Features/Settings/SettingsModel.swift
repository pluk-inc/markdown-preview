//
//  SettingsModel.swift
//  md-preview
//
//  The Settings model. Every value here is one the app already persists — this
//  only gives the existing preferences a home outside the menus and panels.
//
//  State goes through `SettingsModel` rather than `@AppStorage` because these
//  preferences aren't plain defaults: appearance lives in the app group shared
//  with the Quick Look extension, appearance and content width clear their key
//  at the default value, crash reporting starts and stops the Sentry SDK, and
//  anonymous usage analytics has its own capture lifecycle. Routing through
//  the existing types keeps one source of truth.
//

import Sparkle
import SwiftUI

// MARK: - Model

@Observable
@MainActor
final class SettingsModel {
    static let shared = SettingsModel()

    var appearance: AppearanceMode {
        didSet {
            guard !isRestoringExternalValues, appearance != oldValue else { return }
            appDelegate?.applyAppearanceSetting(appearance)
        }
    }

    var documentFont: DocumentFontSetting {
        didSet {
            guard !isRestoringExternalValues, documentFont != oldValue else { return }
            appDelegate?.applyDocumentFontSetting(documentFont)
        }
    }

    var readerLayout: ReaderLayoutSetting {
        didSet {
            guard !isRestoringExternalValues, readerLayout != oldValue else { return }
            appDelegate?.applyReaderLayoutSetting(readerLayout)
        }
    }

    var contentWidth: ContentWidthSetting {
        didSet {
            guard !isRestoringExternalValues, contentWidth != oldValue else { return }
            appDelegate?.applyContentWidthSetting(contentWidth)
        }
    }

    var autoSaveIntervalMinutes: Int {
        didSet {
            let normalized = AutoSaveSetting.clampedMinutes(autoSaveIntervalMinutes)
            guard normalized == autoSaveIntervalMinutes else {
                autoSaveIntervalMinutes = normalized
                return
            }
            guard !isRestoringExternalValues,
                  autoSaveIntervalMinutes != oldValue else { return }
            appDelegate?.applyAutoSaveIntervalSetting(autoSaveIntervalMinutes)
        }
    }

    /// Optional because ⌘+ / ⌘− can leave the stored zoom between the named
    /// stops; the picker then shows nothing selected rather than lying.
    var textSize: TextSizeSetting? {
        didSet {
            guard !isRestoringExternalValues, textSize != oldValue, let textSize else { return }
            appDelegate?.applyTextSizeSetting(textSize)
        }
    }

    var isAlwaysOnTop: Bool {
        didSet {
            guard !isRestoringExternalValues, isAlwaysOnTop != oldValue else { return }
            appDelegate?.applyAlwaysOnTopSetting(isAlwaysOnTop)
        }
    }

    /// A plain stored default with nothing to apply: it is read the next time
    /// a document opens, so unlike the settings above it has no fan-out.
    var opensDocumentsInTabs: Bool {
        didSet {
            guard !isRestoringExternalValues, opensDocumentsInTabs != oldValue else { return }
            TabOpeningPolicy.isEnabled = opensDocumentsInTabs
        }
    }

    var sendsCrashReports: Bool {
        didSet {
            guard !isRestoringExternalValues, sendsCrashReports != oldValue else { return }
            CrashReporter.isEnabled = sendsCrashReports
        }
    }

    var sharesAnonymousUsageAnalytics: Bool {
        didSet {
            guard !isRestoringExternalValues,
                  sharesAnonymousUsageAnalytics != oldValue else { return }
            UsageAnalyticsReporter.isEnabled = sharesAnonymousUsageAnalytics
        }
    }

    var themeColors: ThemeColorsSetting {
        didSet {
            guard !isRestoringExternalValues, themeColors != oldValue else { return }
            ThemeColorsSetting.current = themeColors
            appDelegate?.applyThemeColorsSetting()
        }
    }

    func setThemeColor(_ color: NSColor,
                       slot: ThemeColorSlot,
                       scheme: ThemeColorScheme) {
        var colors = themeColors
        colors.setColor(color, slot, scheme)
        themeColors = colors
    }

    /// Reset returns to the default preset, not to "no theme" — the app
    /// always has a theme applied.
    func resetThemeColors() {
        applyPreset(.defaultPreset)
    }

    /// The theme the reader last applied from a gallery. Remembered so Reset
    /// puts *that* theme back — hand-edited colors, a swapped face or moved
    /// sliders undo to the theme they were built on, rather than dropping the
    /// reader onto the default one.
    private static let appliedPresetKey = "MarkdownPreview.theme.appliedPreset"

    var appliedPreset: ThemePreset {
        if let name = UserDefaults.standard.string(forKey: Self.appliedPresetKey),
           let stored = ThemePreset.builtIn.first(where: { $0.name == name }) {
            return stored
        }
        // No name recorded — the reader upgraded from a build that never
        // wrote one. Fall back to whichever preset their stored colors
        // match, so Reset returns them to the theme they are actually
        // reading in rather than to the default one.
        return selectedPreset ?? .defaultPreset
    }

    /// Applies a whole reading look at once — what the Customize Theme sheet
    /// hands over when the reader saves. Coalesced, so the open documents
    /// update once rather than once per dimension.
    func applyReadingLook(themeColors newColors: ThemeColorsSetting,
                          documentFont newFont: DocumentFontSetting,
                          readerLayout newLayout: ReaderLayoutSetting) {
        let apply = {
            self.themeColors = newColors
            self.documentFont = newFont
            self.readerLayout = newLayout
        }
        guard let appDelegate else { return apply() }
        appDelegate.withCoalescedPreviewReloads(apply)
    }

    /// The preset the stored colors correspond to. Colors that were never
    /// customized count as the default preset — the app treats "no
    /// overrides" as the default theme, so preset galleries always mark an
    /// active card. Hand-edited colors that match no preset return nil
    /// ("Custom colors").
    var selectedPreset: ThemePreset? {
        if let match = ThemePreset.builtIn.first(where: { themeColors == $0.setting }) {
            return match
        }
        return themeColors.isCustomized ? nil : .defaultPreset
    }

    /// Applies a preset: writes its palette into every slot for both
    /// schemes and switches the app appearance to the preset's flavor so
    /// the native chrome matches. A `.system` preset keeps the Automatic
    /// appearance instead — its palettes carry both schemes.
    func applyPreset(_ preset: ThemePreset) {
        guard let appDelegate else { return applyPresetValues(preset) }
        // One re-render for the whole look rather than one per dimension.
        appDelegate.withCoalescedPreviewReloads { applyPresetValues(preset) }
    }

    private func applyPresetValues(_ preset: ThemePreset) {
        UserDefaults.standard.set(preset.name, forKey: Self.appliedPresetKey)
        themeColors = preset.setting
        switch preset.flavor {
        case .light: appearance = .light
        case .dark: appearance = .dark
        case .system: appearance = .automatic
        }
        // A preset is a whole reading look, so it carries the face and the
        // body weight with it. The spacing sliders are the reader's own and
        // survive a preset change.
        documentFont = preset.font
        readerLayout.boldText = preset.boldText
    }

    var checksForUpdatesAutomatically: Bool {
        didSet {
            guard !isRestoringExternalValues,
                  checksForUpdatesAutomatically != oldValue else { return }
            updater?.automaticallyChecksForUpdates = checksForUpdatesAutomatically
        }
    }

    var downloadsUpdatesAutomatically: Bool {
        didSet {
            guard !isRestoringExternalValues,
                  downloadsUpdatesAutomatically != oldValue else { return }
            updater?.automaticallyDownloadsUpdates = downloadsUpdatesAutomatically
        }
    }

    private(set) var lastUpdateCheckDate: Date?

    /// Selected entry in the "Open documents in" picker, as an `OpenTargetChoice.id`.
    var openTargetID: String {
        didSet {
            guard !isRestoringOpenTarget,
                  openTargetID != oldValue,
                  let choice = openTargets.first(where: { $0.id == openTargetID }) else { return }
            switch choice.selection {
            case .editor(let candidate): OpenTargetCatalog.setDefaultEditor(candidate)
            case .llm(let candidate): OpenTargetCatalog.setDefaultLLM(candidate)
            }
            appDelegate?.refreshOpenTargetsInOpenDocuments()
        }
    }

    private(set) var openTargets: [OpenTargetChoice] = []

    /// Set while `reloadOpenTargets` mirrors the persisted default into the
    /// picker. Without it, merely opening the pane would write back a default
    /// the user never chose — and `resolveDefaultOpenAction` behaves
    /// differently once a kind is persisted.
    private var isRestoringOpenTarget = false
    private var isRestoringExternalValues = false
    private var updateObservations: [NSKeyValueObservation] = []

    private var updater: SPUUpdater? { appDelegate?.updaterController.updater }

    private init() {
        let updater = (NSApp.delegate as? AppDelegate)?.updaterController.updater
        appearance = AppearanceMode.current
        contentWidth = ContentWidthSetting.current
        autoSaveIntervalMinutes = AutoSaveSetting.currentMinutes
        textSize = TextSizeSetting.current
        documentFont = DocumentFontSetting.current
        readerLayout = ReaderLayoutSetting.current
        isAlwaysOnTop = AlwaysOnTopPolicy.isEnabled
        opensDocumentsInTabs = TabOpeningPolicy.isEnabled
        sendsCrashReports = CrashReporter.isEnabled
        themeColors = ThemeColorsSetting.current
        sharesAnonymousUsageAnalytics = UsageAnalyticsReporter.isEnabled
        checksForUpdatesAutomatically = updater?.automaticallyChecksForUpdates ?? true
        downloadsUpdatesAutomatically = updater?.automaticallyDownloadsUpdates ?? false
        lastUpdateCheckDate = updater?.lastUpdateCheckDate
        openTargetID = ""
        reloadOpenTargets()

        if let updater {
            // Changing automatic checks can make Sparkle recalculate whether
            // automatic downloads are effective. Observe all three values so
            // the controls stay in sync with Sparkle's persisted settings.
            updateObservations = [
                updater.observe(\.automaticallyChecksForUpdates, options: [.new]) {
                    [weak self] updater, _ in
                    MainActor.assumeIsolated { self?.refreshUpdateSettings(from: updater) }
                },
                updater.observe(\.automaticallyDownloadsUpdates, options: [.new]) {
                    [weak self] updater, _ in
                    MainActor.assumeIsolated { self?.refreshUpdateSettings(from: updater) }
                },
                updater.observe(\.lastUpdateCheckDate, options: [.new]) {
                    [weak self] updater, _ in
                    MainActor.assumeIsolated { self?.refreshUpdateSettings(from: updater) }
                }
            ]
        }
    }

    private func refreshUpdateSettings(from updater: SPUUpdater) {
        let wasRestoringExternalValues = isRestoringExternalValues
        isRestoringExternalValues = true
        checksForUpdatesAutomatically = updater.automaticallyChecksForUpdates
        downloadsUpdatesAutomatically = updater.automaticallyDownloadsUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        isRestoringExternalValues = wasRestoringExternalValues
    }

    /// Re-reads values that menus, document zoom, a window's own toolbar,
    /// Sparkle, the crash reporter, or usage analytics can change while the
    /// shared Settings model remains alive.
    func refreshFromExternalSources() {
        isRestoringExternalValues = true
        defer { isRestoringExternalValues = false }

        appearance = AppearanceMode.current
        contentWidth = ContentWidthSetting.current
        autoSaveIntervalMinutes = AutoSaveSetting.currentMinutes
        textSize = TextSizeSetting.current
        documentFont = DocumentFontSetting.current
        readerLayout = ReaderLayoutSetting.current
        isAlwaysOnTop = AlwaysOnTopPolicy.isEnabled
        opensDocumentsInTabs = TabOpeningPolicy.isEnabled
        sendsCrashReports = CrashReporter.isEnabled
        themeColors = ThemeColorsSetting.current
        sharesAnonymousUsageAnalytics = UsageAnalyticsReporter.isEnabled
        if let updater { refreshUpdateSettings(from: updater) }
    }

    /// Re-reads installed apps and the persisted default. Called when the
    /// General pane appears so newly installed editors show up without a
    /// relaunch.
    func reloadOpenTargets() {
        let llmApps = OpenTargetCatalog.llmCandidates()
        let editors = OpenTargetCatalog.markdownEditorCandidates()

        openTargets =
            llmApps.map { OpenTargetChoice(llm: $0) }
            + editors.map { OpenTargetChoice(editor: $0) }

        let current = OpenTargetCatalog.resolveDefaultOpenAction(
            editors: editors,
            defaultEditor: OpenTargetCatalog.resolveDefaultEditor(among: editors),
            llmApps: llmApps,
            defaultLLM: OpenTargetCatalog.resolveDefaultLLM(among: llmApps)
        )
        guard let current else { return }

        let match = openTargets.first { choice in
            switch (choice.selection, current) {
            case let (.llm(lhs), .llm(rhs)): return lhs.target.id == rhs.target.id
            case let (.editor(lhs), .editor(rhs)): return OpenTargetCatalog.sameEditor(lhs, rhs)
            default: return false
            }
        }
        guard let match, match.id != openTargetID else { return }
        isRestoringOpenTarget = true
        openTargetID = match.id
        isRestoringOpenTarget = false
    }
}

struct OpenTargetChoice: Identifiable {
    let id: String
    let title: String
    let icon: NSImage
    let isAIApp: Bool
    let selection: OpenActionSelection

    @MainActor
    init(llm candidate: LLMCandidate) {
        id = "llm:\(candidate.target.id)"
        title = candidate.target.title
        icon = OpenTargetCatalog.icon(for: candidate.appURL, size: 16)
        isAIApp = true
        selection = .llm(candidate)
    }

    @MainActor
    init(editor candidate: EditorCandidate) {
        let canonicalPath = OpenTargetCatalog.canonicalAppURL(candidate.url).path
        id = "editor:\(candidate.bundleID ?? "unknown"):\(canonicalPath)"
        title = OpenTargetCatalog.displayName(for: candidate.url)
        icon = OpenTargetCatalog.icon(for: candidate.url, size: 16)
        isAIApp = false
        selection = .editor(candidate)
    }
}
