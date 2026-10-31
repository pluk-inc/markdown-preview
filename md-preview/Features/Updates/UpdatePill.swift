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

    /// The hosting view, sized to the capsule, for Auto Layout.
    static func host(_ model: UpdateModel) -> NSView {
        let host = NSHostingView(rootView: UpdatePill(model: model))
        host.sizingOptions = [.intrinsicContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        return host
    }

    var body: some View {
        // Sized to the capsule, so the host is empty, and takes no clicks,
        // while nothing shows.
        ZStack {
            if model.phase != .idle {
                capsule
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: model.phase == .idle)
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            icon
                .font(.system(size: 16))
                .frame(width: 18, height: 18)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
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
            if showsAction, let actionTitle {
                Button(actionTitle) { model.performPrimary() }
                    .buttonStyle(PillActionStyle(tint: tint ?? .accentColor))
            }
            if model.closeAction != nil {
                Button { model.performClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(PillCloseStyle())
                .accessibilityLabel(L("Close"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, hasButtons ? 5 : 14)
        .frame(height: 38)
        .pillBackground()
        .help(model.detail ?? "")
        .accessibilityElement(children: .contain)
    }

    private var showsAction: Bool {
        actionTitle != nil && model.primaryAction != nil
    }

    private var hasButtons: Bool {
        showsAction || model.closeAction != nil
    }

    @ViewBuilder private var icon: some View {
        switch model.phase {
        case .available:
            Image(systemName: "arrow.down.square.fill")
                .foregroundStyle(.white, Color.blue)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.white, Color.green)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.secondary)
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
        switch model.phase {
        case .idle: ""
        case .checking: L("Checking for updates…")
        case .available: L("An update is available")
        case .downloading: L("Downloading update")
        case .preparing: L("Preparing update")
        case .ready: L("Update ready")
        case .installing: L("Installing update…")
        case .upToDate: L("You’re up to date")
        case .failed: L("Update failed")
        }
    }

    private var fraction: Double? {
        switch model.phase {
        case .downloading(let fraction?), .preparing(let fraction): fraction
        default: nil
        }
    }

    private var actionTitle: String? {
        switch model.phase {
        case .available: L("Download")
        case .ready: L("Relaunch Now")
        default: nil
        }
    }

    private var tint: Color? {
        switch model.phase {
        case .available: .blue
        case .ready: .green
        case .failed: .orange
        default: nil
        }
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
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
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
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(tint.opacity(configuration.isPressed ? 0.3 : isHovered ? 0.24 : 0.17),
                        in: Capsule())
            .contentShape(Capsule())
            .onHover { isHovered = $0 }
    }
}

private struct PillCloseStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .background(Color.primary.opacity(configuration.isPressed ? 0.16 : isHovered ? 0.12 : 0.07),
                        in: Circle())
            .contentShape(Circle())
            .onHover { isHovered = $0 }
    }
}

private extension View {
    @ViewBuilder func pillBackground() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        }
    }
}
