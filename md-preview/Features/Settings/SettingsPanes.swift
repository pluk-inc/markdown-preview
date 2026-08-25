//
//  SettingsPanes.swift
//  md-preview
//
//  The Settings pages. Every value here is one the app already persists — this
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

private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

private var appDelegate: AppDelegate? {
    NSApp.delegate as? AppDelegate
}

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

    /// Applies a preset: writes its palette into every slot for both
    /// schemes and switches the app appearance to the preset's flavor so
    /// the native chrome matches. A `.system` preset keeps the Automatic
    /// appearance instead — its palettes carry both schemes.
    func applyPreset(_ preset: ThemePreset) {
        themeColors = preset.setting
        switch preset.flavor {
        case .light: appearance = .light
        case .dark: appearance = .dark
        case .system: appearance = .automatic
        }
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

// MARK: - General

struct GeneralSettingsView: View {
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                Picker(L("Font"), selection: $model.documentFont) {
                    ForEach(DocumentFontSetting.allCases, id: \.self) { setting in
                        Text(setting.title).tag(setting)
                    }
                }

                LabeledContent {
                    TextSizePicker(selection: $model.textSize)
                } label: {
                    Text(L("Text size"))
                    Text(L("Size of rendered Markdown in document windows."))
                }

                Picker(L("Content width"), selection: $model.contentWidth) {
                    ForEach(ContentWidthSetting.allCases, id: \.self) { setting in
                        Text(setting.title).tag(setting)
                    }
                }
            } header: {
                Text(L("Reading"))
            } footer: {
                Text(L("The font also applies to Quick Look previews. Zooming a document window with ⌘+ and ⌘− changes the text size."))
            }

            Section {
                Toggle(isOn: $model.isAlwaysOnTop) {
                    Text(L("Always on Top"))
                    Text(L("Keeps every Markdown Preview window in front of other apps, including windows you open later. A window in full screen is left alone until it comes back out."))
                }

                Toggle(isOn: $model.opensDocumentsInTabs) {
                    Text(L("Open documents in tabs"))
                    Text(L("A file opened from Finder joins the front window as a tab instead of getting one of its own — Open in New Window still opens a window."))
                }
            } header: {
                Text(L("Windows"))
            }

            Section {
                LabeledContent {
                    Picker("", selection: $model.autoSaveIntervalMinutes) {
                        Text(L("Never")).tag(AutoSaveSetting.disabledMinutes)
                        Text(L("30 seconds")).tag(AutoSaveSetting.thirtySeconds)
                        Text(L("1 minute")).tag(1)
                        ForEach([5, 10, 15, 30, 60], id: \.self) { minutes in
                            Text(String(format: L("%d minutes"), minutes))
                                .tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } label: {
                    Text(L("Automatic saving"))
                    Text(L("Save edited documents periodically."))
                }
            } header: {
                Text(L("Editing"))
            } footer: {
                Text(L("Automatic saving runs while a document has unsaved edits."))
            }

            Section {
                if model.openTargets.isEmpty {
                    LabeledContent(L("Open documents in")) {
                        Text(L("No apps available")).foregroundStyle(.secondary)
                    }
                } else {
                    Picker(L("Open documents in"), selection: $model.openTargetID) {
                        aiAppItems
                        editorItems
                    }
                }
            } header: {
                Text(L("Hand-off"))
            } footer: {
                Text(L("The app the Open button in the document toolbar uses first. Its menu still offers every other installed app."))
            }

            Section {
                LabeledContent(L("Command line tools")) {
                    Button(L("Install…")) {
                        appDelegate?.installCommandLineToolsFromSettings()
                    }
                }
            } footer: {
                Text(L("Adds mdp, md-preview, and markdown-preview to your PATH. Run it again after updating the app to refresh the commands."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
            model.reloadOpenTargets()
        }
    }

    @ViewBuilder
    private var aiAppItems: some View {
        let apps = model.openTargets.filter(\.isAIApp)
        if !apps.isEmpty {
            Section(L("AI apps")) {
                ForEach(apps) { choice in
                    openTargetRow(choice)
                }
            }
        }
    }

    @ViewBuilder
    private var editorItems: some View {
        let editors = model.openTargets.filter { !$0.isAIApp }
        if !editors.isEmpty {
            Section(L("Editors")) {
                ForEach(editors) { choice in
                    openTargetRow(choice)
                }
            }
        }
    }

    private func openTargetRow(_ choice: OpenTargetChoice) -> some View {
        HStack {
            Image(nsImage: choice.icon)
            Text(choice.title)
        }
        .tag(choice.id)
    }
}

// MARK: - Theme

/// Color overrides, one row per surface with a Light and a Dark well. A
/// deliberately small first set — presets and more surfaces come later on
/// the same storage.
struct ThemeSettingsView: View {
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        // Resolved once per pass: the footer, the Reset button, and every
        // card compare against it.
        let selected = selectedPreset
        Form {
            Section {
                HStack(alignment: .top) {
                    Text(L("Appearance"))
                        .fixedSize()
                    Spacer(minLength: 16)
                    HStack(spacing: 16) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Button {
                                model.appearance = mode
                            } label: {
                                AppearanceOptionView(
                                    title: mode.settingsTitle,
                                    mode: mode,
                                    isSelected: model.appearance == mode
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(mode.settingsTitle)
                            .accessibilityAddTraits(
                                model.appearance == mode ? [.isSelected] : []
                            )
                        }
                    }
                }
                .padding(.vertical, 4)
            } footer: {
                Text(L("Appearance also applies to Quick Look previews."))
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                    GridItem(.flexible(), spacing: 12)],
                          spacing: 12) {
                    ForEach(ThemePreset.builtIn) { preset in
                        presetCard(preset, isSelected: selected == preset)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text(L("Presets"))
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: L("Current theme: %@"),
                                selected.map { L($0.name) } ?? L("Custom colors")))
                    Text(L("A preset fills every color and switches the app to its light or dark look. Adjust individual colors below afterwards."))
                }
            }

            Section {
                colorRow(L("Window background"), slot: .windowBackground)
                colorRow(L("Code block background"), slot: .codeBlockBackground)
                colorRow(L("Text"), slot: .textColor)
                colorRow(L("Link"), slot: .linkColor)
            } header: {
                Text(L("Colors"))
            } footer: {
                Text(model.appearance == .automatic
                    ? L("Each color has a separate value for the Light and Dark appearance. Picking the default color removes the override.")
                    : L("Colors apply to the current appearance. Choose the Automatic appearance to set Light and Dark separately."))
            }

            Section {
                LabeledContent(L("Custom colors")) {
                    Button(L("Reset Colors")) {
                        model.resetThemeColors()
                    }
                    .disabled(selected == ThemePreset.defaultPreset)
                }
            } footer: {
                Text(L("Restores the default Normal theme."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }

    /// The preset the stored colors correspond to. Colors that were never
    /// customized count as the default preset — the app treats "no
    /// overrides" as the default theme, so the gallery always marks an
    /// active card. Hand-edited colors that match no preset return nil
    /// ("Custom colors").
    private var selectedPreset: ThemePreset? {
        if let match = ThemePreset.builtIn.first(where: { model.themeColors == $0.setting }) {
            return match
        }
        return model.themeColors.isCustomized ? nil : .defaultPreset
    }

    private func presetCard(_ preset: ThemePreset, isSelected: Bool) -> some View {
        let page = Self.color(hex: preset.palette.pageBackground)
        let text = Self.color(hex: preset.palette.text)
        let accent = Self.color(hex: preset.palette.accent)
        let badge: (symbol: String, color: Color) = switch preset.flavor {
        case .light: ("sun.max.fill", .orange)
        case .dark: ("moon.fill", .indigo)
        case .system: ("circle.lefthalf.filled", .secondary)
        }
        return Button {
            model.applyPreset(preset)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(L(preset.name))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(text)
                    Spacer(minLength: 4)
                    Image(systemName: badge.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(badge.color)
                }
                (Text("Lorem ipsum ").foregroundStyle(text.opacity(0.85))
                    + Text("dolor").bold().foregroundStyle(text)
                    + Text(" sit amet, ").foregroundStyle(text.opacity(0.85))
                    + Text("semper").foregroundStyle(accent)
                    + Text(" pharetra.").foregroundStyle(text.opacity(0.85)))
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(page)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                            lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(L(preset.name)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func color(hex: String) -> Color {
        guard let nsColor = ThemeColorsSetting.color(fromHex: hex) else {
            return .primary
        }
        return Color(nsColor: nsColor)
    }

    /// One well while the appearance is pinned (it edits the look on
    /// screen); separate labeled Light/Dark wells only in Automatic, where
    /// both schemes are reachable. Two always-visible wells confused more
    /// than they helped.
    private func colorRow(_ title: String, slot: ThemeColorSlot) -> some View {
        LabeledContent {
            HStack(spacing: 16) {
                switch model.appearance {
                case .light:
                    colorWell(L("Light"), slot: slot, scheme: .light,
                              showsLabel: false)
                case .dark:
                    colorWell(L("Dark"), slot: slot, scheme: .dark,
                              showsLabel: false)
                case .automatic:
                    colorWell(L("Light"), slot: slot, scheme: .light)
                    colorWell(L("Dark"), slot: slot, scheme: .dark)
                }
            }
        } label: {
            Text(title)
        }
    }

    private func colorWell(_ label: String,
                           slot: ThemeColorSlot,
                           scheme: ThemeColorScheme,
                           showsLabel: Bool = true) -> some View {
        HStack(spacing: 6) {
            if showsLabel {
                Text(label)
                    .foregroundStyle(.secondary)
            }
            ColorPicker(label, selection: colorBinding(slot: slot, scheme: scheme),
                        supportsOpacity: false)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }

    private func colorBinding(slot: ThemeColorSlot,
                              scheme: ThemeColorScheme) -> Binding<Color> {
        Binding(
            get: {
                let model = SettingsModel.shared
                let nsColor = model.themeColors.color(slot, scheme)
                    ?? ThemeColorsSetting.defaultColor(slot, scheme)
                return Color(nsColor: nsColor)
            },
            set: { newValue in
                SettingsModel.shared.setThemeColor(
                    NSColor(newValue), slot: slot, scheme: scheme
                )
            }
        )
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    if let appIcon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .frame(width: 64, height: 64)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Markdown Preview"))
                            .font(.title)
                            .fontWeight(.medium)

                        Text(versionSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 8)

                Button(L("Check for Updates")) {
                    appDelegate?.updaterController.updater.checkForUpdates()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

            Section {
                Toggle(L("Automatically check for updates"),
                       isOn: $model.checksForUpdatesAutomatically)
                Toggle(L("Automatically download updates"),
                       isOn: $model.downloadsUpdatesAutomatically)
                    .disabled(!model.checksForUpdatesAutomatically)
                LabeledContent(L("Last checked")) {
                    Text(lastCheckedSummary).foregroundStyle(.secondary)
                }
            } footer: {
                Text(L("Downloaded updates install the next time you quit Markdown Preview."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }

    private var versionSummary: String {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return String(format: L("Version %@ (%@)"), marketing, build)
    }

    private var lastCheckedSummary: String {
        guard let date = model.lastUpdateCheckDate else {
            return L("Never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @Bindable private var model = SettingsModel.shared

    var body: some View {
        Form {
            Section {
                Toggle(L("Send anonymous crash reports"), isOn: $model.sendsCrashReports)
            } footer: {
                Text(L("Crash reports contain diagnostic details such as stack traces and OS and app versions. They may include technical file paths; Markdown Preview does not deliberately attach document contents or personal information."))
            }

            Section {
                Toggle(L("Share anonymous usage analytics"),
                       isOn: $model.sharesAnonymousUsageAnalytics)
            } footer: {
                Text(L("When enabled, Markdown Preview sends at most one event per day when the app becomes active, linked to a random installation identifier. It also sends the app version, macOS major version, processor architecture, and locale country or region. This is used only to count daily and monthly active installations and understand basic platform compatibility. It does not send document contents, file names or paths, actions, screens, precise location, personal information, or advertising identifiers."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshFromExternalSources()
        }
    }
}

// MARK: - Text size

/// Three "Aa" samples drawn at the sizes they select.
///
/// Hand-built rather than a segmented `Picker` for two reasons: the segmented
/// style renders every item in the control's own font, which flattens the size
/// ramp that makes this control readable at a glance, and its optional-tag
/// matching selects the wrong segment. Nothing is highlighted when the stored
/// zoom sits between the stops.
struct TextSizePicker: View {
    @Binding var selection: TextSizeSetting?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TextSizeSetting.allCases, id: \.self) { size in
                Button {
                    selection = size
                } label: {
                    Text(verbatim: "Aa")
                        .font(.system(size: size.sampleFontSize))
                        .frame(width: 36, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selection == size
                                      ? Color.primary.opacity(0.1)
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(size.title)
                .accessibilityAddTraits(selection == size ? [.isSelected] : [])
            }
        }
    }
}

// MARK: - Appearance thumbnails

extension AppearanceMode {
    var settingsTitle: String {
        switch self {
        case .automatic: return L("Automatic")
        case .light: return L("Light")
        case .dark: return L("Dark")
        }
    }
}

/// Miniature window drawn in each appearance, the way System Settings previews
/// the choice instead of listing it in a pop-up.
struct AppearanceOptionView: View {
    let title: String
    let mode: AppearanceMode
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                switch mode {
                case .automatic:
                    HStack(spacing: 0) {
                        thumbnail(isDark: false).frame(width: 40).clipped()
                        thumbnail(isDark: true).frame(width: 40).clipped()
                    }
                case .light:
                    thumbnail(isDark: false)
                case .dark:
                    thumbnail(isDark: true)
                }
            }
            .frame(width: 80, height: 52)
            .clipShape(.rect(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )

            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func thumbnail(isDark: Bool) -> some View {
        let windowBackground = isDark ? Color(white: 0.15) : Color(white: 0.92)
        let pageBackground = isDark ? Color(white: 0.1) : Color.white
        let textColor = isDark ? Color(white: 0.28) : Color(white: 0.75)

        ZStack(alignment: .topLeading) {
            Rectangle().fill(windowBackground)

            HStack(spacing: 0) {
                // Sidebar, matching the document window's outline pane.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(textColor)
                            .frame(width: 14, height: 3)
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.leading, 4)
                .frame(width: 22)

                // Rendered Markdown: a heading rule over body lines.
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(textColor)
                        .frame(width: 26, height: 5)
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(textColor.opacity(0.6))
                            .frame(height: 2)
                    }
                    Spacer()
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(pageBackground))
                .padding(.top, 10)
                .padding(.trailing, 3)
                .padding(.bottom, 3)
            }

            HStack(spacing: 1.5) {
                Circle().fill(Color.red).frame(width: 4, height: 4)
                Circle().fill(Color.yellow).frame(width: 4, height: 4)
                Circle().fill(Color.green).frame(width: 4, height: 4)
            }
            .padding(.leading, 4)
            .padding(.top, 4)
        }
    }
}
