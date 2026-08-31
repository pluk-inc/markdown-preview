//
//  CustomizeThemeView.swift
//  md-preview
//
//  The Customize Theme sheet behind the toolbar popover's Customize button,
//  modeled on Apple Books: a live preview in the current theme colors, the
//  reading font list, a Bold Text switch, and — behind an explicit
//  Customize gate — line spacing, character spacing, word spacing and
//  margin sliders. It also carries the per-surface color wells, which is
//  where they moved when the Appearance settings pane went away.
//
//  A sheet on the document window rather than a separate window: every
//  control changes what that document looks like, and the reader needs the
//  page it belongs to still on screen behind it.
//
//  Font picks apply through SettingsModel immediately. Slider moves edit a
//  local draft so the preview tracks the drag, and commit on release —
//  every commit re-renders the open documents, which is too heavy per tick.
//  Every change is live, so the header's ✗ restores the values the sheet
//  opened with and ✓ keeps them.
//

import SwiftUI

struct CustomizeThemeView: View {
    @Bindable private var model = SettingsModel.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsFontList = false
    @State private var draft = ReaderLayoutSetting.current
    /// What to put back if the reader cancels, as it stood when the sheet
    /// was built.
    private let snapshot: Snapshot

    /// The sheet's fixed size, shared with the hosting controller so it does
    /// not have to measure the content itself.
    static let contentSize = CGSize(width: 660, height: 680)

    private let dismiss: () -> Void

    init(dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        let model = SettingsModel.shared
        snapshot = Snapshot(readerLayout: model.readerLayout,
                            documentFont: model.documentFont,
                            themeColors: model.themeColors)
    }

    /// Everything the sheet can change, as it stood when the sheet opened.
    private struct Snapshot {
        let readerLayout: ReaderLayoutSetting
        let documentFont: DocumentFontSetting
        let themeColors: ThemeColorsSetting
    }

    var body: some View {
        VStack(spacing: 0) {
            previewPane
            Divider()
            Form {
                Section(L("Text")) {
                    fontHeaderRow
                    if showsFontList {
                        ForEach(DocumentFontSetting.allCases, id: \.self) { setting in
                            fontRow(setting)
                        }
                    }
                    Toggle(isOn: $draft.boldText) {
                        Label(L("Bold Text"), systemImage: "bold")
                    }
                    .onChange(of: draft.boldText) { commit() }
                }

                Section(L("Accessibility & Layout Options")) {
                    Toggle(L("Customize"), isOn: $draft.isCustomized)
                        .onChange(of: draft.isCustomized) { commit() }
                    if draft.isCustomized {
                        sliderRow(L("Line Spacing"),
                                  systemImage: "arrow.up.and.down.text.horizontal",
                                  value: $draft.lineSpacing,
                                  range: ReaderLayoutSetting.lineSpacingRange,
                                  display: { String(format: "%.2f", $0) })
                        sliderRow(L("Character Spacing"),
                                  systemImage: "arrow.left.and.right.text.vertical",
                                  value: $draft.characterSpacingPercent,
                                  range: ReaderLayoutSetting.characterSpacingRange)
                        sliderRow(L("Word Spacing"),
                                  systemImage: "text.word.spacing",
                                  value: $draft.wordSpacingPercent,
                                  range: ReaderLayoutSetting.wordSpacingRange)
                        sliderRow(L("Margins"),
                                  systemImage: "inset.filled.center.rectangle",
                                  value: $draft.marginsPercent,
                                  range: ReaderLayoutSetting.marginsRange)
                    }
                }

                // The colors the popover's preset cards write, exposed one
                // surface at a time. The presets live in the popover; this is
                // where a reader adjusts what a preset filled in.
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

                // A full-width destructive row rather than a trailing button:
                // it resets the whole look — theme, reading face and spacing —
                // not just the colors above it.
                Section {
                    Button {
                        model.resetReadingLook()
                    } label: {
                        Text(L("Reset Theme"))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.isReadingLookCustomized)
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        .onAppear {
            model.refreshFromExternalSources()
            draft = model.readerLayout
        }
        .onChange(of: model.readerLayout) {
            // Skipped when this is the echo of our own commit: assigning an
            // equal value still costs a whole body pass.
            guard draft != model.readerLayout else { return }
            draft = model.readerLayout
        }
    }

    private func commit() {
        model.readerLayout = draft
    }

    /// Restores what the sheet opened with and closes it. The ✗ button and
    /// Escape (via the hosting controller's `cancelOperation`) both land here.
    func cancel() {
        model.readerLayout = snapshot.readerLayout
        model.documentFont = snapshot.documentFont
        model.themeColors = snapshot.themeColors
        dismiss()
    }

    // MARK: - Header

    /// Books' header: cancel on the left, the title centered, done on the
    /// right. Both buttons close the sheet; only ✗ puts the old values back.
    private var header: some View {
        ZStack {
            Text(L("Customize Theme"))
                .font(.system(size: 13, weight: .semibold))
            HStack {
                circleButton("xmark", prominent: false,
                             title: L("Cancel"), action: cancel)
                Spacer()
                circleButton("checkmark", prominent: true,
                             title: L("Done"), action: dismiss)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
    }

    /// Liquid Glass circles on macOS 26 — Done takes the prominent, accent
    /// tinted variant, Cancel the clear one — falling back to drawn circles
    /// on macOS 15, which has no glass button style.
    private func circleButton(_ symbol: String,
                              prominent: Bool,
                              title: String,
                              action: @escaping () -> Void) -> some View {
        styledCircleButton(symbol, prominent: prominent, action: action)
            .help(title)
            .accessibilityLabel(title)
    }

    @ViewBuilder
    private func styledCircleButton(_ symbol: String,
                                    prominent: Bool,
                                    action: @escaping () -> Void) -> some View {
        if #available(macOS 26.0, *) {
            Group {
                if prominent {
                    Button(action: action) { glyph(symbol) }
                        .buttonStyle(.glassProminent)
                } else {
                    Button(action: action) { glyph(symbol) }
                        .buttonStyle(.glass)
                }
            }
            .buttonBorderShape(.circle)
        } else {
            Button(action: action) {
                glyph(symbol)
                    // The filled circle inverts with the appearance, so the
                    // glyph has to take the page color rather than white.
                    .foregroundStyle(prominent
                                     ? Color(nsColor: .textBackgroundColor)
                                     : Color.primary)
                    .background(
                        Circle().fill(prominent
                                      ? AnyShapeStyle(Color.primary.opacity(0.85))
                                      : AnyShapeStyle(Color.primary.opacity(0.08)))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: 26, height: 26)
    }

    // MARK: - Preview

    private var previewPane: some View {
        let scheme: ThemeColorScheme = colorScheme == .dark ? .dark : .light
        // Same fallback the colour wells below use, so with no overrides
        // stored the preview shows what the page actually renders.
        let page = Color(nsColor: model.themeColors.color(.windowBackground, scheme)
            ?? ThemeColorsSetting.defaultColor(.windowBackground, scheme))
        let text = Color(nsColor: model.themeColors.color(.textColor, scheme)
            ?? ThemeColorsSetting.defaultColor(.textColor, scheme))
        let weight: Font.Weight = draft.boldText ? .semibold : .regular
        let bodySize: CGFloat = 13
        // Approximations of the page CSS: SwiftUI lineSpacing is the extra
        // points between lines, kerning maps the percent to points. Word
        // spacing has no SwiftUI counterpart; the documents show it.
        let applied = draft.effective
        let extraLeading = bodySize * CGFloat(applied.lineSpacing - 1.0)
        let kerning = bodySize * CGFloat(applied.characterSpacingPercent / 100)
        let marginInset = 28 + CGFloat(applied.pageInset)
        // The header rides on the page color rather than a chrome strip of
        // its own, the way Books runs the sample page up under its buttons.
        return VStack(alignment: .leading, spacing: 14) {
            header
            Text(verbatim: "Aa")
                .font(model.documentFont.font(size: 34))
                .fontWeight(draft.boldText ? .bold : .medium)
                .foregroundStyle(text)
                .padding(.horizontal, 28)
            Text(L("Markdown reads the way you set it here — this paragraph previews the font, weight and spacing your documents will use."))
                .font(model.documentFont.font(size: bodySize))
                .fontWeight(weight)
                .kerning(kerning)
                .lineSpacing(extraLeading)
                .foregroundStyle(text)
                .padding(.horizontal, marginInset)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 24)
        .background(page)
    }

    // MARK: - Font list

    private var fontHeaderRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showsFontList.toggle() }
        } label: {
            HStack {
                Label(L("Font"), systemImage: "textformat")
                Spacer()
                Text(model.documentFont.title)
                    .foregroundStyle(.secondary)
                Image(systemName: showsFontList ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func fontRow(_ setting: DocumentFontSetting) -> some View {
        Button {
            model.documentFont = setting
        } label: {
            HStack {
                Text(setting.title)
                    .font(setting.font(size: 14))
                Spacer()
                if model.documentFont == setting {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .padding(.leading, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.documentFont == setting ? .isSelected : [])
    }

    // MARK: - Colors

    /// One well while the appearance is pinned (it edits the look on screen);
    /// separate labeled Light/Dark wells only in Automatic, where both
    /// schemes are reachable. Two always-visible wells confused more than
    /// they helped.
    private func colorRow(_ title: String, slot: ThemeColorSlot) -> some View {
        LabeledContent {
            HStack(spacing: 16) {
                switch model.appearance {
                case .light:
                    colorWell(L("Light"), slot: slot, scheme: .light, showsLabel: false)
                case .dark:
                    colorWell(L("Dark"), slot: slot, scheme: .dark, showsLabel: false)
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

    // MARK: - Sliders

    private func sliderRow(_ title: String,
                           systemImage: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           display: @escaping (Double) -> String = { "\(Int($0))%" })
        -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased(with: .current))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Slider(value: value, in: range) { editing in
                    if !editing { commit() }
                }
                Text(display(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
    }
}

/// Escape cancels the sheet.
///
/// `cancelOperation(_:)` is the mechanism AppKit routes Escape through, but it
/// starts at the first responder: once a control inside the SwiftUI content
/// holds focus — a slider, a font row, a colour well — the keystroke can be
/// swallowed before it reaches this controller. A key monitor scoped to this
/// sheet's own window catches those, and `NSApp.keyWindow` identity keeps
/// Escape typed into any other window out of it.
private final class SheetHostingController: NSHostingController<CustomizeThemeView> {
    var cancelHandler: (() -> Void)?
    private let escapeMonitor = EscapeKeyMonitor()

    override func viewDidAppear() {
        super.viewDidAppear()
        escapeMonitor.start { [weak self] in
            guard let self, let window = view.window, NSApp.keyWindow === window else {
                return false
            }
            cancelHandler?()
            return true
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        escapeMonitor.stop()
    }

    override func cancelOperation(_ sender: Any?) {
        cancelHandler?()
    }
}

// MARK: - Presentation

@MainActor
enum CustomizeThemeSheet {

    /// Presents the sheet on `window`, or brings the sheet it already has to
    /// the front. AppKit owns the card's chrome, so the view draws only its
    /// own header.
    static func present(on window: NSWindow) {
        // Only our own sheet counts as "already open": any other sheet (a
        // save panel, an alert) would otherwise make the button a silent
        // no-op that re-keys something unrelated.
        if let existing = window.attachedSheet,
           existing.contentViewController is SheetHostingController {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        guard window.attachedSheet == nil else { return }
        guard let host = window.contentViewController else { return }
        // The controller is built first and its root view replaced after, so
        // the dismiss closure can capture it weakly. Handing the closure a
        // captured local `var controller` instead would retain the hosting
        // controller through its own root view — a cycle that leaks the
        // whole sheet, view tree and colour snapshot on every open.
        let hosting = SheetHostingController(rootView: CustomizeThemeView(dismiss: {}))
        hosting.rootView = CustomizeThemeView { [weak hosting] in
            hosting?.dismiss(nil)
        }
        hosting.cancelHandler = { [weak hosting] in hosting?.rootView.cancel() }
        // Size set directly rather than through `sizingOptions`, which runs a
        // measuring layout pass before the view has a window.
        hosting.preferredContentSize = CustomizeThemeView.contentSize
        host.presentAsSheet(hosting)
    }
}
