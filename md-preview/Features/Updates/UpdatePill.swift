//
//  UpdatePill.swift
//  md-preview
//
//  The update capsule at the bottom trailing corner of a document window:
//  an icon, one short line, and at most one action and a close button. On
//  macOS 26 it is Liquid Glass; on macOS 15 a material capsule.
//

import AppKit
import SwiftUI

extension DocumentWindowController {
    /// Adds the capsule to this window once an update shows, so a window
    /// pays for the SwiftUI host only while there is something to show.
    func installUpdatePill(_ model: UpdateModel) {
        mainSplit?.installUpdatePill(model)
    }
}

struct UpdatePill: View {
    let model: UpdateModel
    /// Tells the host where the capsule is, so it takes clicks only there.
    var onCapsuleFrame: (CGRect) -> Void = { _ in }
    /// The width of the current step's row, which the glass follows; nil
    /// until the first step has laid out.
    @State private var rowWidth: CGFloat?

    private static let space = "UpdatePill"
    /// 40 points as drawn. The glass adds a 1-point rim outside its shape;
    /// the material capsule before macOS 26 draws inside it.
    private static var height: CGFloat {
        if #available(macOS 26.0, *) { 38 } else { 40 }
    }

    /// The hosting view, at the height of the capsule, for Auto Layout. The
    /// window sets its width, not the capsule: see `installUpdatePill`.
    static func host(_ model: UpdateModel) -> NSView {
        let host = PillHostingView(rootView: UpdatePill(model: model))
        // Built again once `host` exists, for the callback to capture.
        host.rootView = UpdatePill(model: model, onCapsuleFrame: { [weak host] in
            host?.capsuleFrame = $0
        })
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        return host
    }

    var body: some View {
        // Trailing, like the window pins it: a longer step grows the
        // capsule to the left.
        ZStack(alignment: .bottomTrailing) {
            if model.phase != .idle {
                capsule
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) }
                        action: { onCapsuleFrame($0) }
                    .onDisappear {
                        onCapsuleFrame(.zero)
                        rowWidth = nil
                    }
                    // In from below; out in place, a quick blur and shrink.
                    .transition(AnyTransition.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .modifier(active: CloseEffect(closed: true),
                                           identity: CloseEffect(closed: false))))
            }
        }
        // Always the capsule's height too: a host that lost its height while
        // the capsule fades out would move the capsule down.
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .bottomTrailing)
        .coordinateSpace(.named(Self.space))
        .animation(model.phase == .idle ? .easeOut(duration: 0.12) : .spring(duration: 0.35, bounce: 0.15),
                   value: model.phase == .idle)
        // A new step blurs its icon, line and buttons in over the old ones;
        // download progress inside a step does not.
        .animation(Self.stepAnimation, value: step)
    }

    /// What the capsule shows: the model's step, or, while it fades out,
    /// the last one.
    private var shown: UpdateModel.Shown {
        model.phase == .idle ? model.lastShown
            : .init(phase: model.phase, hasPrimary: model.primaryAction != nil,
                    hasClose: model.closeAction != nil)
    }

    private var phase: UpdateModel.Phase { shown.phase }

    /// One curve for the swap and the width, so they end together.
    private static let stepAnimation = Animation.smooth(duration: 0.32)

    /// The phase without its progress, so only a change of step animates.
    private var step: Int {
        switch phase {
        case .idle: 0
        case .checking: 1
        case .available: 2
        case .downloading: 3
        case .preparing: 4
        case .ready: 5
        case .installing: 6
        case .upToDate: 7
        case .failed: 8
        case .updated: 9
        }
    }

    private var capsule: some View {
        // Sized to the current step's row, not to the old row while it blurs
        // out. The rows ride the leading edge and the capsule clips them, so
        // the new line moves in with the edge instead of waiting outside.
        ZStack(alignment: .leading) {
            row
                .id(step)
                .transition(.blurReplace)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    // The first step takes its width at once; the capsule
                    // only moves in from below. Later widths animate in the
                    // whole layout, so the capsule's position moves with its
                    // width and its trailing edge stays put.
                    if rowWidth == nil {
                        rowWidth = width
                    } else {
                        withAnimation(Self.stepAnimation) { rowWidth = width }
                    }
                }
        }
        .frame(width: rowWidth, height: Self.height, alignment: .leading)
        .clipShape(Capsule())
        .pillBackground(tint: tint)
        .help(model.detail ?? "")
        .accessibilityElement(children: .contain)
    }

    private var row: some View {
        HStack(spacing: 10) {
            // The icon sits closer to its line than the line to the buttons.
            HStack(spacing: 7) {
                icon
                    .font(.system(size: 16))
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint ?? .primary)
                    .lineLimit(1)
            }
            if let fraction {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    // Each changed digit rolls in and fades.
                    .contentTransition(.numericText(value: fraction))
                    .animation(.snappy(duration: 0.3), value: fraction)
                    // Room for "100%", so the capsule keeps its width.
                    .frame(minWidth: 34, alignment: .trailing)
            }
            if hasButtons {
                // The buttons sit closer to each other than to the text.
                HStack(spacing: 6) {
                    if showsAction, let actionTitle {
                        Button(actionTitle) { model.performPrimary() }
                            .buttonStyle(PillActionStyle(tint: tint ?? Self.accent))
                    }
                    if shown.hasClose {
                        Button { model.performClose() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(PillCloseStyle())
                        .accessibilityLabel(L("Close"))
                    }
                }
                .padding(.leading, 3)
            }
        }
        // Always its full width: a step with a longer line ("Update
        // installed.") must not squeeze the button into "Relaunc…".
        .fixedSize(horizontal: true, vertical: false)
        .padding(.leading, 13)
        // 24-point buttons in the capsule: 7 points all around them.
        .padding(.trailing, hasButtons ? 7 : 14)
        .frame(height: Self.height)
    }

    private var showsAction: Bool {
        actionTitle != nil && shown.hasPrimary
    }

    private var hasButtons: Bool {
        showsAction || shown.hasClose
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        // Filled symbols in one color: the arrow or check is a hole in the
        // shape, so the glass shows through it.
        case .available:
            Image(systemName: "arrow.down.app.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Self.accent)
        case .ready, .updated:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(.green)
        case .upToDate:
            // A light disc in Dark Mode, a dark one in Light Mode.
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.primary.opacity(0.85))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .downloading(let fraction?), .preparing(let fraction):
            ProgressRing(fraction: fraction)
        case .idle, .checking, .downloading(nil), .installing:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
        }
    }

    private var title: String {
        switch phase {
        case .idle: ""
        case .checking: L("Checking for updates")
        case .available: L("An update is available")
        case .downloading: L("Downloading update")
        case .preparing: L("Preparing update")
        case .ready: L("Update installed.")
        case .installing: L("Installing update…")
        case .upToDate: L("Markdown Preview is up to date")
        case .failed: L("Update failed")
        case .updated(let version): String(format: L("Updated to %@"), version)
        }
    }

    private var fraction: Double? {
        switch phase {
        case .downloading(let fraction?), .preparing(let fraction): fraction
        default: nil
        }
    }

    private var actionTitle: String? {
        switch phase {
        case .available: L("Download")
        case .ready: L("Relaunch Now")
        case .updated: L("What’s New")
        default: nil
        }
    }

    /// The accent chosen in System Settings › Appearance, not the app's
    /// asset catalog accent.
    static let accent = Color(nsColor: .controlAccentColor)

    /// One color for the icon, the text, the action button and the glass. An
    /// update on offer takes the reader's accent; ready and failed keep the
    /// colors that carry their meaning.
    private var tint: Color? {
        switch phase {
        case .available: Self.accent
        case .ready, .updated: .green
        case .failed: .orange
        default: nil
        }
    }
}

/// The capsule closing: it blurs, shrinks a little and fades where it is.
private struct CloseEffect: ViewModifier {
    let closed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(closed ? 0.94 : 1)
            .blur(radius: closed ? 4 : 0)
            .opacity(closed ? 0 : 1)
    }
}

/// The host spans the window's width; outside the capsule it lets clicks
/// through to the document below. (A hosting view is flipped, like the
/// SwiftUI frame it compares with.)
private final class PillHostingView: NSHostingView<UpdatePill> {
    var capsuleFrame: CGRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard capsuleFrame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

private struct ProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.35), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(UpdatePill.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.15), value: fraction)
        }
        .padding(1.5)
    }
}

private struct PillActionStyle: ButtonStyle {
    let tint: Color
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(tint.opacity(configuration.isPressed ? 0.3 : isHovered ? 0.24 : 0.17),
                        in: Capsule())
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
    }
}

/// Neutral gray in every step: only the action carries the color.
private struct PillCloseStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : isHovered ? 0.12 : 0.07),
                        in: Circle())
            .contentShape(Circle())
            .onHover { isHovered = $0 }
    }
}

private extension View {
    /// A trace of the tint over the glass, so the capsule leans toward the
    /// color of its text and buttons without looking colored.
    @ViewBuilder func pillBackground(tint: Color?) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint?.opacity(0.02)), in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .background((tint ?? .clear).opacity(0.02), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}
