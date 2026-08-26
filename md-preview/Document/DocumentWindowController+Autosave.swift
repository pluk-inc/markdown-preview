//
//  DocumentWindowController+Autosave.swift
//  md-preview
//
//  Automatic saving of edited documents.
//

import Cocoa

extension DocumentWindowController {
    // MARK: - Autosave

    func applyAutoSaveIntervalSetting() {
        guard hasUnsavedEditorChanges else { return }
        stopAutoSaveTimer()
        startAutoSaveTimerIfNeeded()
    }

    func startAutoSaveTimerIfNeeded() {
        guard autoSaveTimer == nil,
              currentFileURL != nil,
              hasUnsavedEditorChanges,
              let interval = AutoSaveSetting.interval else { return }
        let timerID = UUID()
        autoSaveTimerID = timerID
        autoSaveTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self, timerID] _ in
            Task { @MainActor [weak self] in
                guard let self, self.autoSaveTimerID == timerID else { return }
                self.autoSaveTimer = nil
                self.autoSaveTimerID = nil
                self.performAutomaticSave()
            }
        }
    }

    func stopAutoSaveTimer() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        autoSaveTimerID = nil
    }

    private func performAutomaticSave() {
        guard hasUnsavedEditorChanges,
              !isEditorCommitInFlight,
              currentFileURL != nil else { return }

        isPerformingAutomaticSave = true
        commitEdits(exitAfter: false) { [weak self] success in
            guard let self else { return }
            self.isPerformingAutomaticSave = false
            guard !success else { return }
            self.showAutoSaveFailure()
        }
    }

    private func showAutoSaveFailure() {
        autoSaveFeedbackResetWork?.cancel()
        autoSaveFeedbackResetWork = nil
        autoSaveFeedback = .failed

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.autoSaveFeedbackResetWork = nil
            self.autoSaveFeedback = .none
        }
        autoSaveFeedbackResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    func resetAutoSaveFeedback() {
        autoSaveFeedbackResetWork?.cancel()
        autoSaveFeedbackResetWork = nil
        autoSaveFeedback = .none
    }

    func updateWindowSubtitle() {
        switch autoSaveFeedback {
        case .failed:
            documentWindow.subtitle = NSLocalizedString(
                "Auto-save failed", comment: "Window subtitle after an automatic save failure")
        case .none:
            documentWindow.subtitle = hasUnsavedEditorChanges
                ? NSLocalizedString("Edited", comment: "Window subtitle for unsaved changes")
                : ""
        }
    }
}
