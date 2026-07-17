//
//  SystemDictationController.swift
//  Lorelei
//
//  Owns the Ctrl+Shift system-dictation flow: record, format, insert.
//  Never writes to the conversation log or command turn pipeline.
//  Listening UI (face / waveform) is driven by CompanionManager callbacks.
//

import AppKit
import Foundation

enum SystemDictationAnalyticsEvent: Equatable, Sendable {
    case started
    case inserted(
        usedFallbackText: Bool,
        appCategory: String,
        formatMs: Int,
        totalMs: Int,
        rawVisibleMs: Int,
        replacement: String
    )
    case copiedToClipboard(formatMs: Int, totalMs: Int, replacement: String)
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
    private let replacer: any DictationTextReplacing
    private let swapClipboard: (String, String) -> Bool
    private let rawInsertFirstEnabled: () -> Bool
    private let presentHUD: (String) -> Void
    private let trackAnalytics: (SystemDictationAnalyticsEvent) -> Void
    private let showOverlay: () -> Void
    private let hideOverlay: () -> Void
    private let markSessionFinished: () -> Void
    private let frontmostProcessID: () -> pid_t?
    private let frontmostAppContext: () -> DictationAppContext?
    /// False while a command turn or approval owns the toolbar - dictation
    /// must not start and clobber that runStatus.
    private let canStartSession: () -> Bool
    private let now: () -> ContinuousClock.Instant

    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var awaitingFinalTranscriptTask: Task<Void, Never>?
    private var didBeginFinalTranscriptHandling = false
    /// True from a successful press until format/insert (or silence) finishes.
    /// Mic dictation clears earlier on release; this blocks a second press from
    /// overlapping an in-flight cleanup/paste.
    private var isPipelineBusy = false
    private var targetProcessID: pid_t?
    private var targetAppContext: DictationAppContext?

    init(
        listener: any SystemDictationListening,
        formatter: any DictationTextFormatting,
        inserter: any DictationTextInserting,
        replacer: any DictationTextReplacing = AXDictationTextReplacer(),
        swapClipboard: @escaping (String, String) -> Bool = { raw, cleaned in
            DictationPasteboardSwap.swapIfStillRaw(rawText: raw, cleanedText: cleaned)
        },
        rawInsertFirstEnabled: @escaping () -> Bool = {
            !UserDefaults.standard.bool(forKey: "LoreleiDictationRawInsertFirstDisabled")
        },
        presentHUD: @escaping (String) -> Void,
        trackAnalytics: @escaping (SystemDictationAnalyticsEvent) -> Void = { _ in },
        showOverlay: @escaping () -> Void,
        hideOverlay: @escaping () -> Void,
        markSessionFinished: @escaping () -> Void = {},
        frontmostProcessID: @escaping () -> pid_t? = {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        },
        frontmostAppContext: @escaping () -> DictationAppContext? = {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return DictationAppContext(
                bundleIdentifier: app.bundleIdentifier,
                localizedName: app.localizedName
            )
        },
        canStartSession: @escaping () -> Bool = { true },
        now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.listener = listener
        self.formatter = formatter
        self.inserter = inserter
        self.replacer = replacer
        self.swapClipboard = swapClipboard
        self.rawInsertFirstEnabled = rawInsertFirstEnabled
        self.presentHUD = presentHUD
        self.trackAnalytics = trackAnalytics
        self.showOverlay = showOverlay
        self.hideOverlay = hideOverlay
        self.markSessionFinished = markSessionFinished
        self.frontmostProcessID = frontmostProcessID
        self.frontmostAppContext = frontmostAppContext
        self.canStartSession = canStartSession
        self.now = now
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
        guard !isPipelineBusy else { return }
        guard canStartSession() else { return }

        awaitingFinalTranscriptTask?.cancel()
        awaitingFinalTranscriptTask = nil
        didBeginFinalTranscriptHandling = false
        isPipelineBusy = true
        // Capture before overlay / prewarm can change frontmost focus.
        targetProcessID = frontmostProcessID()
        targetAppContext = frontmostAppContext()

        showOverlay()
        formatter.prewarm()
        trackAnalytics(.started)

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

        let wasListening = listener.isDictationInProgress
        listener.stopListening()
        hideOverlay()

        if !wasListening {
            // Never started recording (quick tap). Clear processing UI now.
            finishPipeline()
            return
        }

        // Real STT skips submitDraftText on empty/silence, so finish the UI
        // if no final transcript arrives within the finalize window.
        armAwaitingFinalTranscriptFallback()
    }

    private func armAwaitingFinalTranscriptFallback() {
        awaitingFinalTranscriptTask?.cancel()
        awaitingFinalTranscriptTask = Task { @MainActor [weak self] in
            // SpeechAnalyzer finalize window is ~1.8s; leave margin.
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            guard !self.didBeginFinalTranscriptHandling else { return }
            LoreleiDiagLog.log("systemDictation: no final transcript → end session UI")
            self.finishPipeline()
        }
    }

    private func handleFinalTranscript(_ rawTranscript: String) async {
        let totalStart = now()
        didBeginFinalTranscriptHandling = true
        awaitingFinalTranscriptTask?.cancel()
        awaitingFinalTranscriptTask = nil

        defer {
            LoreleiDiagLog.log("systemDictation: session finished")
            finishPipeline()
        }

        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        LoreleiDiagLog.log(
            "systemDictation: final transcript chars=\(trimmed.count) frontmost=\(Self.frontmostAppName())"
        )
        guard !trimmed.isEmpty else { return }

        guard rawInsertFirstEnabled() else {
            await runLegacyFormatThenInsert(rawTranscript, totalStart: totalStart)
            return
        }

        LoreleiDiagLog.log(
            "systemDictation: raw insert begin chars=\(rawTranscript.count) targetPID=\(targetProcessID.map(String.init) ?? "nil")"
        )
        let insertOutcome = await inserter.insert(
            rawTranscript,
            targetProcessID: targetProcessID
        )
        let rawVisibleMs = Self.milliseconds(from: totalStart, to: now())
        if case .leftOnClipboard = insertOutcome {
            presentHUD("Copied to clipboard")
        }

        LoreleiDiagLog.log("systemDictation: format begin")
        let formatStart = now()
        let formatterResult = await formatter.format(
            rawTranscript,
            appContext: targetAppContext
        )
        let formatMs = Self.milliseconds(from: formatStart, to: now())
        var usedFallbackText = false
        let replacement: String
        switch (formatterResult, insertOutcome) {
        case (.formatted(let cleaned), .inserted):
            let outcome = await replacer.replaceRawWithCleaned(
                rawText: rawTranscript,
                cleanedText: cleaned,
                targetProcessID: targetProcessID
            )
            replacement = outcome.rawValue
        case (.formatted(let cleaned), .leftOnClipboard) where cleaned == rawTranscript:
            replacement = DictationReplacementOutcome.keptIdentical.rawValue
        case (.formatted(let cleaned), .leftOnClipboard):
            replacement = swapClipboard(rawTranscript, cleaned)
                ? DictationReplacementOutcome.replaced.rawValue
                : DictationReplacementOutcome.keptCheckFailed.rawValue
        case (.fallbackToRaw(let reason), _):
            LoreleiDiagLog.log("systemDictation: format fallback reason=\(reason)")
            usedFallbackText = true
            replacement = "kept_format_fallback"
        }

        let totalMs = Self.milliseconds(from: totalStart, to: now())
        switch insertOutcome {
        case .inserted:
            LoreleiDiagLog.log(
                "systemDictation: raw-first done replacement=\(replacement) formatMs=\(formatMs) totalMs=\(totalMs) rawVisibleMs=\(rawVisibleMs)"
            )
            trackAnalytics(.inserted(
                usedFallbackText: usedFallbackText,
                appCategory: (targetAppContext?.category ?? .unknown).rawValue,
                formatMs: formatMs,
                totalMs: totalMs,
                rawVisibleMs: rawVisibleMs,
                replacement: replacement
            ))
        case .leftOnClipboard:
            trackAnalytics(.copiedToClipboard(
                formatMs: formatMs,
                totalMs: totalMs,
                replacement: replacement
            ))
        }
    }

    private func runLegacyFormatThenInsert(
        _ rawTranscript: String,
        totalStart: ContinuousClock.Instant
    ) async {
        LoreleiDiagLog.log("systemDictation: format begin")
        let formatStart = now()
        let formatterResult = await formatter.format(
            rawTranscript,
            appContext: targetAppContext
        )
        let formatMs = Self.milliseconds(from: formatStart, to: now())
        switch formatterResult {
        case .formatted(let cleaned):
            LoreleiDiagLog.log("systemDictation: format ok chars=\(cleaned.count)")
        case .fallbackToRaw(let reason):
            LoreleiDiagLog.log("systemDictation: format fallback reason=\(reason)")
        }

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

        LoreleiDiagLog.log(
            "systemDictation: insert begin chars=\(textToInsert.count) targetPID=\(targetProcessID.map(String.init) ?? "nil")"
        )
        let outcome = await inserter.insert(textToInsert, targetProcessID: targetProcessID)
        let totalMs = Self.milliseconds(from: totalStart, to: now())
        switch outcome {
        case .inserted:
            LoreleiDiagLog.log(
                "systemDictation: insert ok formatMs=\(formatMs) totalMs=\(totalMs)"
            )
            trackAnalytics(.inserted(
                usedFallbackText: usedFallbackText,
                appCategory: (targetAppContext?.category ?? .unknown).rawValue,
                formatMs: formatMs,
                totalMs: totalMs,
                rawVisibleMs: 0,
                replacement: "legacy_disabled"
            ))
        case .leftOnClipboard:
            LoreleiDiagLog.log(
                "systemDictation: paste failed → clipboard HUD formatMs=\(formatMs) totalMs=\(totalMs)"
            )
            presentHUD("Copied to clipboard")
            trackAnalytics(.copiedToClipboard(
                formatMs: formatMs,
                totalMs: totalMs,
                replacement: "legacy_disabled"
            ))
        }
    }

    private func finishPipeline() {
        isPipelineBusy = false
        targetProcessID = nil
        targetAppContext = nil
        markSessionFinished()
    }

    private static func frontmostAppName() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil"
    }

    private static func milliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Int {
        let duration = end - start
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
