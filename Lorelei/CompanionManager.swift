//
//  CompanionManager.swift
//  Lorelei
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import Combine
import Foundation
import AVFoundation
import NaturalLanguage
import ScreenCaptureKit
import SwiftUI

@MainActor
protocol SpeechOutputing: AnyObject {
    func speak(_ text: String)
}

typealias CodexAppServerDesktopActionRunner = @MainActor (
    _ prompt: String,
    _ cwd: String
) async -> WorkspaceCommandResult

typealias CodexAppServerTransportFactory = @Sendable () async throws -> CodexAppServerTransporting

@MainActor
final class SpeechOutputClient: SpeechOutputing {
    private let synthesizer: AVSpeechSynthesizer

    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
    }

    func speak(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        // The default voice follows the system language and SILENTLY skips
        // text in other scripts (Japanese summaries were never spoken on an
        // English system). Pick a voice matching the text's dominant language.
        if let voice = Self.voice(forText: text) {
            utterance.voice = voice
        }
        synthesizer.speak(utterance)
    }

    static func voice(forText text: String) -> AVSpeechSynthesisVoice? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage else { return nil }

        let code = language.rawValue // e.g. "ja", "en"
        if let exact = AVSpeechSynthesisVoice(language: code) {
            return exact
        }
        return AVSpeechSynthesisVoice.speechVoices().first { voice in
            voice.language.hasPrefix("\(code)-") || voice.language == code
        }
    }
}

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

struct ConversationEntry: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
}

struct CompanionResponseTaskTracker {
    private(set) var currentTaskID: UUID?

    mutating func begin() -> UUID {
        let taskID = UUID()
        currentTaskID = taskID
        return taskID
    }

    mutating func finishIfCurrent(_ taskID: UUID) -> Bool {
        guard currentTaskID == taskID else { return false }
        currentTaskID = nil
        return true
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var latestResultSummary: String?
    @Published private(set) var pendingApprovalTitle: String?
    @Published private(set) var debugLog = CompanionDebugLog()
    @Published private(set) var runStatus: LoreleiRunStatus = .idle
    @Published private(set) var streamText: String = ""
    @Published private(set) var conversationLog: [ConversationEntry] = []
    @Published private(set) var currentActivity: String?

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Claude's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager: any OverlayWindowManaging
    let workspaceSettingsStore: WorkspaceSettingsStore
    private let commandRouter = LoreleiCommandRouter()
    private let workspaceCommandExecutor = WorkspaceCommandExecutor()
    private let codexAppServerDesktopActionRunner: CodexAppServerDesktopActionRunner?
    private let codexAppServerTransportFactory: CodexAppServerTransportFactory?
    private let speechOutput: SpeechOutputing
    private let audioFeedback: BuddyAudioFeedbacking
    private let runStatusIdleReturnDelay: Duration
    private let transcribingWatchdogDelay: Duration
    private var axDesktopActionExecutor: AXDesktopActionExecutor?
    private var loreleiCursorOrbManager: LoreleiCursorOrbManager?
    private var codexAppServerExecutor: CodexAppServerExecutor?
    private var pendingCodexAppServerApproval: CheckedContinuation<CodexAppServerApprovalDecision, Never>?
    private var liveCodexAppServerTransport: CodexAppServerTransporting?
    private var activeTurn: (threadID: String, turnID: String)?
    private var outstandingSteerTranscripts: [Int: String] = [:]
    private var currentAssistantConversationEntryID: UUID?
    private var responseTaskTracker = CompanionResponseTaskTracker()
    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var runStatusIdleReturnTask: Task<Void, Never>?
    private var transcribingWatchdogTask: Task<Void, Never>?

    /// True when all required permissions are granted. Used by the panel to show
    /// a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    var missingPermissionNames: [String] {
        [
            (hasMicrophonePermission, "Microphone"),
            (hasAccessibilityPermission, "Accessibility"),
            (hasScreenRecordingPermission, "Screen Recording"),
            (hasScreenContentPermission, "Screen Content")
        ]
            .compactMap { isGranted, name in isGranted ? nil : name }
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Claude model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedClaudeModel") ?? "claude-sonnet-4-6"

    init(
        speechOutput: SpeechOutputing? = nil,
        workspaceSettingsStore: WorkspaceSettingsStore? = nil,
        codexAppServerDesktopActionRunner: CodexAppServerDesktopActionRunner? = nil,
        codexAppServerTransportFactory: CodexAppServerTransportFactory? = nil,
        runStatusIdleReturnDelay: Duration = .seconds(4),
        transcribingWatchdogDelay: Duration = .seconds(6),
        overlayWindowManager: (any OverlayWindowManaging)? = nil,
        audioFeedback: BuddyAudioFeedbacking? = nil
    ) {
        let resolvedSpeechOutput = speechOutput ?? SpeechOutputClient()
        self.speechOutput = resolvedSpeechOutput
        self.audioFeedback = audioFeedback ?? BuddyAudioFeedback(speechOutput: resolvedSpeechOutput)
        self.workspaceSettingsStore = workspaceSettingsStore ?? WorkspaceSettingsStore()
        self.codexAppServerDesktopActionRunner = codexAppServerDesktopActionRunner
        self.codexAppServerTransportFactory = codexAppServerTransportFactory
        self.runStatusIdleReturnDelay = runStatusIdleReturnDelay
        self.transcribingWatchdogDelay = transcribingWatchdogDelay
        self.overlayWindowManager = overlayWindowManager ?? OverlayWindowManager()
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Lorelei start - accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
    }

    func updateLatestResultSummary(_ summary: String?) {
        latestResultSummary = summary
        guard let summary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        recordDebugEvent("Result: \(Self.conciseDebugLine(summary))")
    }

    func acceptPendingApproval() {
        _ = resolvePendingCodexAppServerApproval(.accept)
    }

    func cancelPendingApproval() {
        guard resolvePendingCodexAppServerApproval(.cancel) else { return }
        updateLatestResultSummary("Cancelled.")
    }

    var debugLogText: String {
        debugLog.text
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        _ = resolvePendingCodexAppServerApproval(.cancel)
        activeTurn = nil
        outstandingSteerTranscripts.removeAll()
        runStatusIdleReturnTask?.cancel()
        runStatusIdleReturnTask = nil
        transcribingWatchdogTask?.cancel()
        transcribingWatchdogTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions - accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted - once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content - a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result - width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception -
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding - the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    if self.currentResponseTask == nil && self.isOverlayVisible {
                        self.overlayWindowManager.hideOverlay()
                        self.isOverlayVisible = false
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !buddyDictationManager.isDictationInProgress else { return }
            setRunStatusListening()

            if !isOverlayVisible {
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Do NOT cancel currentResponseTask here: pressing the shortcut
            // mid-turn is exactly how steering starts. Cancelling used to
            // kill the running turn, which invalidated the app-server
            // session, so every steer silently landed on a brand-new thread
            // with no memory of the conversation. Any needed cancellation
            // happens in routeFinalTranscriptAsNewTurn once we know the
            // transcript is NOT a steer.
            clearDetectedElementLocation()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        self?.handleFinalTranscriptLocally(finalTranscript)
                    }
                )
            }
        case .released:
            setRunStatusTranscribing()
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        case .none:
            break
        }
    }

    // MARK: - Local Command Routing Pipeline

#if DEBUG
    func handleFinalTranscriptForTesting(_ transcript: String) {
        handleFinalTranscriptLocally(transcript)
    }

    func handleDebugPrompt(_ prompt: String) {
        handleFinalTranscriptLocally(prompt)
    }
#endif

    func stopCurrentRun() {
        guard currentResponseTask != nil
            || pendingCodexAppServerApproval != nil
        else {
            return
        }

        LoreleiAnalytics.capture(.runStopped)

        if let activeTurn,
           let liveCodexAppServerTransport,
           let codexAppServerExecutor {
            Task { @MainActor in
                do {
                    let requestID = await codexAppServerExecutor.reserveRequestID()
                    try await codexAppServerExecutor.sendInterruptRequest(
                        id: requestID,
                        threadID: activeTurn.threadID,
                        turnID: activeTurn.turnID,
                        transport: liveCodexAppServerTransport
                    )
                    cancelPendingCodexAppServerApprovalForStop()
                } catch {
                    await stopCurrentRunByInvalidatingSession()
                }
            }
            return
        }

        Task { @MainActor in
            await stopCurrentRunByInvalidatingSession()
        }
    }

    func startNewChatSession() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        _ = resolvePendingCodexAppServerApproval(.cancel)
        runStatusIdleReturnTask?.cancel()
        runStatusIdleReturnTask = nil
        cancelTranscribingWatchdog()
        activeTurn = nil
        outstandingSteerTranscripts.removeAll()
        conversationLog.removeAll()
        currentAssistantConversationEntryID = nil
        streamText = ""
        currentActivity = nil
        latestResultSummary = nil
        runStatus = .idle
        LoreleiAnalytics.capture(.newChatStarted)
        recordDebugEvent("New chat started")

        Task { @MainActor in
            await invalidateLiveCodexAppServerSessionWhenReady()
        }
    }

    private func stopCurrentRunByInvalidatingSession() async {
        await invalidateLiveCodexAppServerSessionWhenReady()
        currentResponseTask?.cancel()
        activeTurn = nil
        outstandingSteerTranscripts.removeAll()
        cancelPendingCodexAppServerApprovalForStop()
        finishRun(with: WorkspaceCommandResult(summary: "Stopped.", status: .failed))
    }

#if DEBUG
    func simulateShortcutTransitionForTesting(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            setRunStatusListening()
            if !isOverlayVisible {
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }
        case .released:
            setRunStatusTranscribing()
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        case .none:
            break
        }
    }

    func seedConversationEntryForTesting(role: ConversationEntry.Role, text: String) {
        appendConversationEntry(role: role, text: text)
    }
#endif

    /// Routes final transcripts to Lorelei's current local workspace and Codex actions.
    private func handleFinalTranscriptLocally(_ transcript: String) {
        if let activeTurn,
           let liveCodexAppServerTransport,
           let codexAppServerExecutor {
            Task { @MainActor in
                let requestID = await codexAppServerExecutor.reserveSteerRequestID()
                outstandingSteerTranscripts[requestID] = transcript
                do {
                    try await codexAppServerExecutor.sendSteerRequest(
                        id: requestID,
                        threadID: activeTurn.threadID,
                        expectedTurnID: activeTurn.turnID,
                        prompt: transcript,
                        transport: liveCodexAppServerTransport
                    )
                    appendConversationEntry(role: .user, text: "↪ \(transcript)")
                    LoreleiAnalytics.capture(.steerSent)
                    LoreleiAnalytics.capture(.dictationCompleted(
                        transcriptCharacters: transcript.count,
                        viaSteer: true
                    ))
                    // Close the streaming assistant entry so the reply to
                    // the steer opens a NEW entry below it - otherwise all
                    // deltas keep appending to the pre-steer bubble and the
                    // steered line visually sinks to the bottom of the log.
                    currentAssistantConversationEntryID = nil
                    recordDebugEvent("Steered: \(Self.conciseDebugLine(transcript))")
                } catch {
                    outstandingSteerTranscripts.removeValue(forKey: requestID)
                    LoreleiAnalytics.capture(.steerFailed)
                    recordDebugEvent("Steer failed - starting a new turn")
                    routeFinalTranscriptAsNewTurn(transcript)
                }
            }
            return
        }

        routeFinalTranscriptAsNewTurn(transcript)
    }

    private func routeFinalTranscriptAsNewTurn(_ transcript: String, appendUserEntry: Bool = true) {
        currentResponseTask?.cancel()
        _ = resolvePendingCodexAppServerApproval(.cancel)
        lastTranscript = transcript
        if appendUserEntry {
            appendConversationEntry(role: .user, text: transcript)
        }
        currentAssistantConversationEntryID = nil
        LoreleiAnalytics.capture(.dictationCompleted(
            transcriptCharacters: transcript.count,
            viaSteer: false
        ))
        recordDebugEvent("Transcript: \(Self.conciseDebugLine(transcript))")
        let action = commandRouter.route(transcript)
        recordDebugEvent("Route: \(action.debugLabel)")
        let taskID = responseTaskTracker.begin()

        currentResponseTask = Task { @MainActor in
            defer { finishResponseTaskIfCurrent(taskID) }
            voiceState = .processing

            if case let .unsupported(message) = action {
                finishRun(with: WorkspaceCommandResult(summary: message, status: .failed))
                return
            }

            beginRunStatus()

            switch action {
            case .codexReadOnly(let prompt):
                let result = await runCodexAppServerTurn(
                    prompt: prompt,
                    sandboxPolicy: "readOnly"
                )
                guard !Task.isCancelled else { return }

                finishRun(with: result)
                return
            case .codexWorkspaceWrite(let prompt):
                let result = await runCodexAppServerTurn(
                    prompt: CodexPromptBuilder.workspaceWritePrompt(for: prompt),
                    sandboxPolicy: "workspaceWrite"
                )
                guard !Task.isCancelled else { return }

                finishRun(with: result)
                return
            case .codexDesktopAction(let prompt):
                let result = await runCodexAppServerDesktopAction(prompt: prompt)
                guard !Task.isCancelled else { return }

                finishRun(with: result)
                return
            case .codexScreen(let prompt):
                let result = await runCodexScreenRequest(prompt)
                guard !Task.isCancelled else { return }

                finishRun(with: result)
                return
            case .gitStatus, .gitDiff, .runTests, .unsupported:
                break
            }

            let result = await workspaceCommandExecutor.run(
                action,
                workspacePath: workspaceSettingsStore.selectedWorkspacePath
            )
            guard !Task.isCancelled else { return }

            finishRun(with: result)
        }
    }

    private func requestCodexAppServerApproval(
        _ request: CodexAppServerApprovalRequest
    ) async -> CodexAppServerApprovalDecision {
        await withCheckedContinuation { continuation in
            _ = resolvePendingCodexAppServerApproval(.cancel)
            pendingCodexAppServerApproval = continuation
            pendingApprovalTitle = request.title
            runStatusIdleReturnTask?.cancel()
            runStatusIdleReturnTask = nil
            runStatus = .needsApproval(request.title)
            LoreleiAnalytics.capture(.approvalRequested)
            recordDebugEvent("Waiting for App Server approval: \(request.title)")
            updateLatestResultSummary(request.detail)
            audioFeedback.play(.approvalRequested, spokenSummary: nil)
        }
    }

    private func resolvePendingCodexAppServerApproval(_ decision: CodexAppServerApprovalDecision) -> Bool {
        guard let continuation = pendingCodexAppServerApproval else { return false }
        pendingCodexAppServerApproval = nil
        pendingApprovalTitle = nil
        runStatus = .working(currentActivity ?? "Thinking…")
        switch decision {
        case .accept:
            recordDebugEvent("App Server approval accepted")
        case .cancel:
            recordDebugEvent("App Server approval cancelled")
        }
        LoreleiAnalytics.capture(.approvalResolved(accepted: decision == .accept))
        continuation.resume(returning: decision)
        return true
    }

    private func cancelPendingCodexAppServerApprovalForStop() {
        guard let continuation = pendingCodexAppServerApproval else { return }
        pendingCodexAppServerApproval = nil
        pendingApprovalTitle = nil
        recordDebugEvent("App Server approval cancelled")
        continuation.resume(returning: .cancel)
    }

    private func terminateLiveCodexAppServerTransportWhenReady() async {
        for _ in 0..<20 {
            if let transport = liveCodexAppServerTransport {
                await transport.terminate()
                liveCodexAppServerTransport = nil
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func invalidateLiveCodexAppServerSessionWhenReady() async {
        if let codexAppServerExecutor {
            await codexAppServerExecutor.invalidateSession()
            liveCodexAppServerTransport = nil
            return
        }

        await terminateLiveCodexAppServerTransportWhenReady()
    }

    private func runCodexAppServerDesktopAction(prompt: String) async -> WorkspaceCommandResult {
        let appServerPrompt = CodexPromptBuilder.desktopActionPrompt(for: prompt)
        let cwd = codexAppServerWorkingDirectory()
        recordDebugEvent("Codex App Server desktop action started")
        recordDebugEvent("Codex App Server cwd: \(cwd)")
        LoreleiAnalytics.capture(.turnStarted(sandboxPolicy: "desktopAction"))
        let turnStartedAt = Date()

        let result = await withDesktopActionOverlayHidden {
            if let codexAppServerDesktopActionRunner = self.codexAppServerDesktopActionRunner {
                return await codexAppServerDesktopActionRunner(appServerPrompt, cwd)
            }

            let executor = self.sharedCodexAppServerExecutor()
            return await executor.runDesktopAction(prompt: appServerPrompt, cwd: cwd)
        }

        LoreleiAnalytics.capture(.turnCompleted(
            success: result.status == .succeeded,
            durationSeconds: Date().timeIntervalSince(turnStartedAt)
        ))
        return result
    }

    private func runCodexAppServerTurn(
        prompt: String,
        sandboxPolicy: String,
        extraInput: [CodexAppServerTurnInputItem] = [],
        removeLocalImageInputsAfterRun: Bool = false
    ) async -> WorkspaceCommandResult {
        let cwd = codexAppServerWorkingDirectory()
        recordDebugEvent("Codex App Server turn started")
        recordDebugEvent("Codex App Server cwd: \(cwd)")
        LoreleiAnalytics.capture(.turnStarted(sandboxPolicy: sandboxPolicy))
        let turnStartedAt = Date()

        let result = await withDesktopActionOverlayHidden {
            let executor = self.sharedCodexAppServerExecutor()
            return await executor.runTurn(
                prompt: prompt,
                cwd: cwd,
                sandboxPolicy: sandboxPolicy,
                extraInput: extraInput,
                removeLocalImageInputsAfterRun: removeLocalImageInputsAfterRun
            )
        }

        LoreleiAnalytics.capture(.turnCompleted(
            success: result.status == .succeeded,
            durationSeconds: Date().timeIntervalSince(turnStartedAt)
        ))
        return result
    }

    private func sharedCodexAppServerExecutor() -> CodexAppServerExecutor {
        if let codexAppServerExecutor {
            return codexAppServerExecutor
        }

        let foregroundTool = CodexAppServerDesktopForegroundTool()
        let dynamicToolSpecsResolver = {
            [CodexAppServerDesktopForegroundTool.spec] + CodexAppServerDesktopToolSuite.toolSpecs()
        }
        let dynamicToolHandler: CodexAppServerDynamicToolHandler = { [weak self] request in
            if request.namespace == CodexAppServerDesktopForegroundTool.spec.namespace,
               request.tool == CodexAppServerDesktopForegroundTool.spec.name {
                return await foregroundTool.handle(request)
            }

            guard let self else {
                return CodexAppServerDynamicToolCallResult(
                    success: false,
                    contentText: "CompanionManager is no longer available for desktop tool handling."
                )
            }
            return await CodexAppServerDesktopToolSuite.handle(
                request,
                executor: self.sharedAXDesktopActionExecutor()
            )
        }
        let traceHandler: CodexAppServerTraceHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.recordDebugEvent("App Server: \(event.logLine)")
            }
        }
        let progressHandler: CodexAppServerTurnProgressHandler = { [weak self] progress in
            Task { @MainActor [weak self] in
                self?.handleCodexAppServerProgress(progress)
            }
        }
        let transportReadyHandler: @Sendable (CodexAppServerTransporting) -> Void = { [weak self] transport in
            Task { @MainActor [weak self] in
                self?.liveCodexAppServerTransport = transport
            }
        }
        let lifecycleHandler: CodexAppServerSessionLifecycleHandler = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.recordDebugEvent("App Server: \(event.logLine)")
            }
        }
        let approvalHandler: (CodexAppServerApprovalRequest) async -> CodexAppServerApprovalDecision = { [weak self] request in
            guard let self else { return .cancel }
            return await self.requestCodexAppServerApproval(request)
        }
        let executor: CodexAppServerExecutor
        if let codexAppServerTransportFactory {
            executor = CodexAppServerExecutor(
                makeTransport: codexAppServerTransportFactory,
                dynamicToolSpecsResolver: dynamicToolSpecsResolver,
                dynamicToolHandler: dynamicToolHandler,
                traceHandler: traceHandler,
                progressHandler: progressHandler,
                onTransportReady: transportReadyHandler,
                onSessionLifecycleEvent: lifecycleHandler,
                approvalHandler: approvalHandler
            )
        } else {
            executor = CodexAppServerExecutor(
                dynamicToolSpecsResolver: dynamicToolSpecsResolver,
                dynamicToolHandler: dynamicToolHandler,
                traceHandler: traceHandler,
                progressHandler: progressHandler,
                onTransportReady: transportReadyHandler,
                onSessionLifecycleEvent: lifecycleHandler,
                approvalHandler: approvalHandler
            )
        }
        codexAppServerExecutor = executor
        return executor
    }

    private func sharedAXDesktopActionExecutor() -> AXDesktopActionExecutor {
        if let axDesktopActionExecutor {
            return axDesktopActionExecutor
        }
        let executor = AXDesktopActionExecutor()
        let orbManager = loreleiCursorOrbManager ?? LoreleiCursorOrbManager()
        loreleiCursorOrbManager = orbManager
        executor.visualizer = orbManager
        axDesktopActionExecutor = executor
        return executor
    }

    private func withDesktopActionOverlayHidden(
        _ operation: @escaping @MainActor () async -> WorkspaceCommandResult
    ) async -> WorkspaceCommandResult {
        clearDetectedElementLocation()

        if isOverlayVisible {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }

        return await operation()
    }

    private func recordDebugEvent(_ line: String) {
        debugLog.append(line)
    }

    private func setRunStatusListening() {
        runStatusIdleReturnTask?.cancel()
        runStatusIdleReturnTask = nil
        cancelTranscribingWatchdog()
        let shouldPlayCue = runStatus != .listening
        runStatus = .listening
        if shouldPlayCue {
            audioFeedback.play(.listeningStarted, spokenSummary: nil)
        }
    }

    private func setRunStatusTranscribing() {
        runStatusIdleReturnTask?.cancel()
        runStatusIdleReturnTask = nil
        let shouldPlayCue = runStatus != .transcribing
        runStatus = .transcribing
        if shouldPlayCue {
            audioFeedback.play(.listeningEnded, spokenSummary: nil)
        }
        armTranscribingWatchdog()
    }

    /// Returns the toolbar to idle when a transcribe never produces a turn -
    /// e.g. a silent hold, or an input device that delivers no audio - so the
    /// status does not stay stuck on "Transcribing...". A real transcript
    /// starts a turn (moving runStatus to .working) well before this fires,
    /// and the guard keeps it from disturbing a running or steered turn.
    private func armTranscribingWatchdog() {
        transcribingWatchdogTask?.cancel()
        transcribingWatchdogTask = Task { @MainActor [weak self, transcribingWatchdogDelay] in
            try? await Task.sleep(for: transcribingWatchdogDelay)
            guard let self, !Task.isCancelled else { return }
            guard self.currentResponseTask == nil,
                  self.activeTurn == nil,
                  self.runStatus == .transcribing else { return }
            self.runStatus = .idle
        }
    }

    private func cancelTranscribingWatchdog() {
        transcribingWatchdogTask?.cancel()
        transcribingWatchdogTask = nil
    }

    private func beginRunStatus() {
        runStatusIdleReturnTask?.cancel()
        runStatusIdleReturnTask = nil
        cancelTranscribingWatchdog()
        streamText = ""
        currentAssistantConversationEntryID = nil
        currentActivity = nil
        runStatus = .working("Thinking…")
    }

    private func handleCodexAppServerProgress(_ progress: CodexAppServerTurnProgress) {
        switch progress {
        case .turnStarted(let threadID, let turnID):
            activeTurn = (threadID: threadID, turnID: turnID)
        case .turnEnded:
            activeTurn = nil
            outstandingSteerTranscripts.removeAll()
        case .steerFailed(let requestID, _):
            guard let transcript = outstandingSteerTranscripts.removeValue(forKey: requestID) else {
                return
            }
            LoreleiAnalytics.capture(.steerFailed)
            recordDebugEvent("Steer failed - starting a new turn")
            routeFinalTranscriptAsNewTurn(transcript, appendUserEntry: false)
        case .agentMessageDelta(let delta):
            streamText += delta
            appendAssistantDeltaToConversation(delta)
        case .toolCallStarted(let name):
            currentActivity = name
            runStatus = .working(name)
        case .toolCallCompleted(let name, _):
            if currentActivity == name {
                currentActivity = nil
            }
        }
    }

    private func finishRun(with result: WorkspaceCommandResult) {
        updateLatestResultSummary(result.summary)
        // The final summary is the whole turn's streamed text. When the log
        // was split by a steer, rewriting the (post-steer) entry with the
        // full turn text would duplicate everything above the split - if
        // the streamed deltas already cover the summary, leave the log as
        // rendered and only write summaries that add information (failures,
        // tool-only turns without deltas).
        if streamText.trimmingCharacters(in: .whitespacesAndNewlines)
            != result.summary.trimmingCharacters(in: .whitespacesAndNewlines) {
            updateAssistantConversationEntry(text: result.summary)
        }
        let succeeded = result.status == .succeeded
        finishRunStatus(success: succeeded)
        audioFeedback.play(succeeded ? .runSucceeded : .runFailed, spokenSummary: result.summary)
    }

    private func appendConversationEntry(role: ConversationEntry.Role, text: String) {
        let entry = ConversationEntry(id: UUID(), role: role, text: text)
        conversationLog.append(entry)
        if role == .assistant {
            currentAssistantConversationEntryID = entry.id
        }
        capConversationLog()
    }

    private func appendAssistantDeltaToConversation(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let currentAssistantConversationEntryID,
           let index = conversationLog.firstIndex(where: { $0.id == currentAssistantConversationEntryID }) {
            conversationLog[index].text += delta
        } else {
            appendConversationEntry(role: .assistant, text: delta)
        }
    }

    private func updateAssistantConversationEntry(text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let currentAssistantConversationEntryID,
           let index = conversationLog.firstIndex(where: { $0.id == currentAssistantConversationEntryID }) {
            conversationLog[index].text = text
        } else {
            appendConversationEntry(role: .assistant, text: text)
        }
    }

    private func capConversationLog() {
        let maximumConversationEntries = 200
        guard conversationLog.count > maximumConversationEntries else { return }
        conversationLog.removeFirst(conversationLog.count - maximumConversationEntries)
        if let currentAssistantConversationEntryID,
           !conversationLog.contains(where: { $0.id == currentAssistantConversationEntryID }) {
            self.currentAssistantConversationEntryID = nil
        }
    }

    private func finishRunStatus(success: Bool) {
        runStatusIdleReturnTask?.cancel()
        cancelTranscribingWatchdog()
        currentActivity = nil
        runStatus = .finished(success: success)
        runStatusIdleReturnTask = Task { @MainActor [runStatusIdleReturnDelay] in
            do {
                try await Task.sleep(for: runStatusIdleReturnDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            runStatus = .idle
            streamText = ""
        }
    }

    private static func conciseDebugLine(_ line: String, maxCharacters: Int = 240) -> String {
        let flattened = line
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > maxCharacters else { return flattened }
        let endIndex = flattened.index(flattened.startIndex, offsetBy: maxCharacters)
        return "\(flattened[..<endIndex])..."
    }

    private func codexAppServerWorkingDirectory() -> String {
        if let workspacePath = workspaceSettingsStore.selectedWorkspacePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !workspacePath.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: workspacePath, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return workspacePath
            }
        }

        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func finishResponseTaskIfCurrent(_ taskID: UUID) {
        guard responseTaskTracker.finishIfCurrent(taskID) else { return }
        voiceState = .idle
        currentResponseTask = nil
        liveCodexAppServerTransport = nil
        activeTurn = nil
        outstandingSteerTranscripts.removeAll()
    }

    private func runCodexScreenRequest(_ prompt: String) async -> WorkspaceCommandResult {
        let runner = CodexScreenContextRequestRunner()
        return await runner.run(
            prompt: prompt,
            workspacePath: workspaceSettingsStore.selectedWorkspacePath,
            runTurn: { [weak self] prompt, imagePath in
                guard let self else {
                    return WorkspaceCommandResult(summary: "CompanionManager is no longer available.", status: .failed)
                }
                return await self.runCodexAppServerTurn(
                    prompt: prompt,
                    sandboxPolicy: "readOnly",
                    extraInput: [.localImage(path: imagePath)],
                    removeLocalImageInputsAfterRun: true
                )
            }
        )
    }

}

@MainActor
struct CodexScreenContextRequestRunner {
    private let fileManager: FileManager
    private let captureCursorScreen: @MainActor () async throws -> CompanionScreenCapture?
    private let isCancelled: () -> Bool
    private let makeTemporaryImageURL: () -> URL

    init(
        fileManager: FileManager = .default,
        captureCursorScreen: @escaping @MainActor () async throws -> CompanionScreenCapture? = {
            try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
        },
        isCancelled: @escaping () -> Bool = { Task.isCancelled },
        makeTemporaryImageURL: (() -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.captureCursorScreen = captureCursorScreen
        self.isCancelled = isCancelled
        self.makeTemporaryImageURL = makeTemporaryImageURL ?? {
            fileManager.temporaryDirectory
                .appendingPathComponent("lorelei-screen-\(UUID().uuidString).jpg")
        }
    }

    func run(
        prompt: String,
        workspacePath: String?,
        runTurn: @escaping @MainActor (String, String) async -> WorkspaceCommandResult
    ) async -> WorkspaceCommandResult {
        guard let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspacePath.isEmpty else {
            return WorkspaceCommandResult(summary: "No workspace selected.", status: .missingWorkspace)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspacePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return WorkspaceCommandResult(
                summary: "Workspace path is not a valid directory: \(workspacePath)",
                status: .failed
            )
        }

        do {
            let cursorScreenCapture = try await captureCursorScreen()
            guard !isCancelled() else {
                return WorkspaceCommandResult(summary: "Screen capture cancelled.", status: .cancelled)
            }

            guard let cursorScreenCapture else {
                return WorkspaceCommandResult(
                    summary: "Screen capture failed: no screen image was captured.",
                    status: .failed
                )
            }

            let imageURL = makeTemporaryImageURL()
            guard !isCancelled() else {
                return WorkspaceCommandResult(summary: "Screen capture cancelled.", status: .cancelled)
            }

            try cursorScreenCapture.imageData.write(to: imageURL, options: .atomic)

            guard !isCancelled() else {
                try? fileManager.removeItem(at: imageURL)
                return WorkspaceCommandResult(summary: "Screen capture cancelled.", status: .cancelled)
            }

            return await runTurn(prompt, imageURL.path)
        } catch {
            return WorkspaceCommandResult(
                summary: "Screen capture failed: \(error.localizedDescription)",
                status: .failed
            )
        }
    }
}
