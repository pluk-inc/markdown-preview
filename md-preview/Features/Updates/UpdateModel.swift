//
//  UpdateModel.swift
//  md-preview
//
//  What the update capsule shows, shared by every document window. The
//  driver sets a phase with the buttons that answer Sparkle; the capsule
//  only reads it.
//

import Foundation
import Observation

@Observable
final class UpdateModel {

    enum Phase: Equatable {
        case idle
        case checking
        case available
        /// The fraction downloaded, or nil before the size is known.
        case downloading(Double?)
        case preparing(Double)
        case ready
        case installing
        case upToDate
        case failed
    }

    private(set) var phase: Phase = .idle
    /// The version on offer, or the error Sparkle gave; the capsule's tooltip.
    private(set) var detail: String?
    /// Download, or Relaunch Now.
    private(set) var primaryAction: (() -> Void)?
    /// The close button; nil hides it.
    private(set) var closeAction: (() -> Void)?

    @ObservationIgnored private var autoHide: Task<Void, Never>?
    /// Called when the capsule appears after being hidden, to add it to
    /// the open windows.
    @ObservationIgnored var didAppear: ((UpdateModel) -> Void)?

    /// Shows `phase` with these buttons, replacing the ones before.
    func show(_ phase: Phase, detail: String? = nil,
              primary: (() -> Void)? = nil, close: (() -> Void)? = nil) {
        autoHide?.cancel()
        autoHide = nil
        let wasHidden = self.phase == .idle
        self.phase = phase
        self.detail = detail
        primaryAction = primary
        closeAction = close
        if wasHidden, phase != .idle { didAppear?(self) }
        if phase == .upToDate {
            // Nothing to act on: it goes away by itself.
            autoHide = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled, self?.phase == .upToDate else { return }
                self?.performClose()
            }
        }
    }

    /// Progress within the same step; the buttons stay.
    func update(_ phase: Phase) {
        self.phase = phase
    }

    func hide() {
        show(.idle)
    }

    func performPrimary() {
        primaryAction?()
    }

    /// Hides the capsule first: Sparkle may answer the close by dismissing
    /// the session, which hides it too.
    func performClose() {
        let close = closeAction
        hide()
        close?()
    }
}
