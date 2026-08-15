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
//  at the default value, and crash reporting starts and stops the Sentry SDK.
//  Routing through the existing types keeps one source of truth.
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

    var contentWidth: ContentWidthSetting {
        didSet {
            guard !isRestoringExternalValues, contentWidth != oldValue else { return }
            appDelegate?.applyContentWidthSetting(contentWidth)
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

    var sendsCrashReports: Bool {
        didSet {
            guard !isRestoringExternalValues, sendsCrashReports != oldValue else { return }
            CrashReporter.isEnabled = sendsCrashReports
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
        textSize = TextSizeSetting.current
        sendsCrashReports = CrashReporter.isEnabled
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

    /// Re-reads values that menus, document zoom, Sparkle, or the crash reporter
    /// can change while the shared Settings model remains alive.
    func refreshFromExternalSources() {
        isRestoringExternalValues = true
        defer { isRestoringExternalValues = false }

        appearance = AppearanceMode.current
        contentWidth = ContentWidthSetting.current
        textSize = TextSizeSetting.current
        sendsCrashReports = CrashReporter.isEnabled
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
                Text(L("Layout"))
            } footer: {
                Text(L("Zooming a document window with ⌘+ and ⌘− changes this same size."))
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
