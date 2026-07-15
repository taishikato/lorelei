//
//  SystemDictationController.swift
//  Lorelei
//
//  Owns the Ctrl+Shift system-dictation flow: record, format, insert.
//  Never writes to the conversation log or command run-status pipeline.
//

import AppKit
import Foundation

enum SystemDictationAnalyticsEvent: Equatable, Sendable {
    case started
    case inserted(usedFallbackText: Bool)
    case copiedToClipboard
}

@MainActor
protocol SystemDictationListening: AnyObject {
    var isDictationInProgress: Bool { get }
    func startListening(
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async
    func stopListening()
}

@MainActor
final class BuddyDictationManagerSystemDictationListeningAdapter: SystemDictationListening {
    private let manager: BuddyDictationManager

    init(manager: BuddyDictationManager) {
        self.manager = manager
    }

    var isDictationInProgress: Bool {
        manager.isDictationInProgress
    }

    func startListening(
        updateDraftText: @escaping (String) -> Void,
        submitDraftText: @escaping (String) -> Void
    ) async {
        await manager.startPushToTalkFromKeyboardShortcut(
            currentDraftText: "",
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText
        )
    }

    func stopListening() {
        manager.stopPushToTalkFromKeyboardShortcut()
    }
}

@MainActor
final class SystemDictationController {
    private let listener: any SystemDictationListening
    private let formatter: any DictationTextFormatting
    private let inserter: any DictationTextInserting
    private let writeToPasteboard: (String) -> Void
    private let presentHUD: (String) -> Void
    private let trackAnalytics: (SystemDictationAnalyticsEvent) -> Void
    private let showOverlay: () -> Void
    private let hideOverlay: () -> Void

    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var isSessionActive = false

    init(
        listener: any SystemDictationListening,
        formatter: any DictationTextFormatting,
        inserter: any DictationTextInserting,
        writeToPasteboard: @escaping (String) -> Void,
        presentHUD: @escaping (String) -> Void,
        trackAnalytics: @escaping (SystemDictationAnalyticsEvent) -> Void = { _ in },
        showOverlay: @escaping () -> Void,
        hideOverlay: @escaping () -> Void
    ) {
        self.listener = listener
        self.formatter = formatter
        self.inserter = inserter
        self.writeToPasteboard = writeToPasteboard
        self.presentHUD = presentHUD
        self.trackAnalytics = trackAnalytics
        self.showOverlay = showOverlay
        self.hideOverlay = hideOverlay
    }

    func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            handlePressed()
        case .released:
            handleReleased()
        case .none:
            break
        }
    }

    private func handlePressed() {
        guard !listener.isDictationInProgress else { return }

        showOverlay()
        formatter.prewarm()
        trackAnalytics(.started)
        isSessionActive = true

        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = Task {
            await listener.startListening(
                updateDraftText: { _ in
                    // Partial transcripts stay hidden (waveform-only UI).
                },
                submitDraftText: { [weak self] finalTranscript in
                    Task { @MainActor in
                        await self?.handleFinalTranscript(finalTranscript)
                    }
                }
            )
        }
    }

    private func handleReleased() {
        // Cancel the pending start task in case the user released before
        // startListening began recording - same race fix as command PTT.
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        listener.stopListening()
        hideOverlay()
        isSessionActive = false
    }

    private func handleFinalTranscript(_ rawTranscript: String) async {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let formatterResult = await formatter.format(rawTranscript)
        let textToInsert: String
        let usedFallbackText: Bool
        switch formatterResult {
        case .formatted(let cleaned):
            textToInsert = cleaned
            usedFallbackText = false
        case .fallbackToRaw:
            textToInsert = rawTranscript
            usedFallbackText = true
        }

        let outcome = await inserter.insert(textToInsert)
        switch outcome {
        case .inserted:
            trackAnalytics(.inserted(usedFallbackText: usedFallbackText))
        case .noEditableTarget, .axError:
            writeToPasteboard(textToInsert)
            presentHUD("Copied to clipboard")
            trackAnalytics(.copiedToClipboard)
        }
    }
}
