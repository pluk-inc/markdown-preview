//
//  ThemesPopoverView.swift
//  md-preview
//
//  Content of the toolbar's "aA" popover: text size, appearance, and the
//  theme preset gallery in one place, with Customize leading to the
//  Customize Theme panel (fonts and reading layout). Driven by the shared
//  SettingsModel, so a preset or appearance picked here reaches every open
//  window exactly like a change made in the Settings window.
//

import SwiftUI

struct ThemesPopoverView: View {
    @Bindable private var model = SettingsModel.shared

    private let decreaseTextSize: () -> Void
    private let increaseTextSize: () -> Void
    private let currentZoom: () -> CGFloat
    private let openCustomize: () -> Void

    /// Where the document sits on the zoom scale, and whether the scale is
    /// on screen. It appears on a text-size tap and hides itself again, so
    /// it reads as feedback for the tap rather than permanent chrome.
    @State private var zoomStep = 0
    @State private var showsScale = false
    @State private var hideScaleTask: Task<Void, Never>?

    private static let scaleVisibleSeconds: Double = 2

    init(decreaseTextSize: @escaping () -> Void,
         increaseTextSize: @escaping () -> Void,
         currentZoom: @escaping () -> CGFloat,
         openCustomize: @escaping () -> Void) {
        self.decreaseTextSize = decreaseTextSize
        self.increaseTextSize = increaseTextSize
        self.currentZoom = currentZoom
        self.openCustomize = openCustomize
    }

    var body: some View {
        // Spacing is set per gap rather than by one stack value: the scale
        // needs the same small gap below it that it has above, while the
        // rest of the popover keeps the wider 12pt rhythm.
        VStack(spacing: 0) {
            Text(L("Themes & Settings"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Divider()
                .padding(.top, 12)

            // The scale belongs to the text-size control, so it sits in a
            // column with it and takes its width — the appearance button
            // stays top-aligned beside the capsule rather than centering
            // against the taller column.
            HStack(alignment: .top, spacing: 8) {
                VStack(spacing: 6) {
                    textSizeControl
                    zoomScale
                }
                appearanceButton
            }
            .padding(.top, 12)

            ThemePresetGallery(spacing: 8, cardInset: 2)
            .padding(.top, 6)

            Button(action: openCustomize) {
                Label(L("Customize"), systemImage: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .accessibilityLabel(L("Customize"))
            .padding(.top, 12)
        }
        // Generous side padding, with the popover's own width fixed — the
        // cards absorb it rather than the popover growing.
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .frame(width: 286)
        .onAppear {
            model.refreshFromExternalSources()
            // Known before the first tap so the scale is already correct
            // when it appears, rather than filling in a step late.
            zoomStep = MarkdownWebView.zoomStepIndex(for: currentZoom())
        }
        .onDisappear {
            hideScaleTask?.cancel()
        }
    }

    // MARK: - Text size

    /// The old toolbar zoom pair, relocated: a smaller and a larger "A"
    /// driving the same document zoom actions.
    private var textSizeControl: some View {
        HStack(spacing: 0) {
            textSizeButton(sampleSize: 12, title: L("Zoom Out"),
                           action: decreaseTextSize)
            Divider()
                .padding(.vertical, 9)
            textSizeButton(sampleSize: 17, title: L("Zoom In"),
                           action: increaseTextSize)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    /// One dot per zoom stop, filled up to the document's current stop —
    /// the scale Books shows under its text-size control. Centered on that
    /// control, and the row holds its height whether or not the dots are
    /// showing, so revealing them never moves anything.
    private var zoomScale: some View {
        HStack(spacing: 5) {
            ForEach(MarkdownWebView.zoomSteps.indices, id: \.self) { index in
                Circle()
                    .fill(index <= zoomStep
                          ? Color.primary.opacity(0.75)
                          : Color.primary.opacity(0.15))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // Exactly the dot diameter: no slack to make one gap read larger.
        .frame(height: 5)
        .opacity(showsScale ? 1 : 0)
        .animation(.easeInOut(duration: 0.18), value: showsScale)
        .accessibilityHidden(true)
    }

    /// Applies a text-size step, then shows the scale and restarts the
    /// countdown that hides it.
    private func changeTextSize(_ action: () -> Void) {
        action()
        zoomStep = MarkdownWebView.zoomStepIndex(for: currentZoom())
        showsScale = true
        hideScaleTask?.cancel()
        hideScaleTask = Task {
            try? await Task.sleep(for: .seconds(Self.scaleVisibleSeconds))
            guard !Task.isCancelled else { return }
            showsScale = false
        }
    }

    private func textSizeButton(sampleSize: CGFloat,
                                title: String,
                                action: @escaping () -> Void) -> some View {
        Button {
            changeTextSize(action)
        } label: {
            Text(verbatim: "A")
                .font(.system(size: sampleSize, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }

    // MARK: - Appearance

    /// One button cycling Automatic → Light → Dark, shown as the current
    /// mode's symbol. The three-thumbnail picker stays in Settings; the
    /// popover only needs the quick flip.
    private var appearanceButton: some View {
        let title = String(format: L("Appearance: %@"),
                           model.appearance.settingsTitle)
        return Button(action: cycleAppearance) {
            Image(systemName: appearanceSymbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 56, height: 48)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .help(title)
        .accessibilityLabel(title)
    }

    private var appearanceSymbol: String {
        switch model.appearance {
        case .automatic: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private func cycleAppearance() {
        let modes = AppearanceMode.allCases
        guard let index = modes.firstIndex(of: model.appearance) else { return }
        model.appearance = modes[(index + 1) % modes.count]
    }

}
