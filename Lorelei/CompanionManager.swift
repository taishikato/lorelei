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
        synthesizer.speak(AVSpeechUtterance(string: text))
    }
}

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
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
    private let codexExecutor: CodexExecutor
    private let codexAppServerDesktopActionRunner: CodexAppServerDesktopActionRunner?
    private let codexAppServerTransportFactory: CodexAppServerTransportFactory?
    private let speechOutput: SpeechOutputing
    private let audioFeedback: BuddyAudioFeedbacking
    private let runStatusIdleReturnDelay: Duration
    private var axDesktopActionExecutor: AXDesktopActionExecutor?
    private var codexAppServerExecutor: CodexAppServerExecutor?
    private var pendingCodexAppServerApproval: CheckedContinuation<CodexAppServerApprovalDecision, Never>?
    private var liveCodexAppServerTransport: CodexAppServerTransporting?
    private var activeTurn: (threadID: String, turnID: String)?
    private var outstandingSteerTranscripts: [Int: String] = [:]
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
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
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
        codexExecutor: CodexExecutor? = nil,
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
        self.codexExecutor = codexExecutor ?? CodexExecutor()
        self.overlayWindowManager = overlayWindowManager ?? OverlayWindowManager()
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedClaudeModel")
    }

    /// User preference for whether the Lorelei cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isBuddyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    func setBuddyCursorEnabled(_ enabled: Bool) {
        isBuddyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    func start() {
        refreshAllPermissions()
        print("🔑 Lorelei start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        if allPermissionsGranted && isBuddyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
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
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        _ = resolvePendingCodexAppServerApproval(.cancel)
        activeTurn = nil
        outstandingSteerTranscripts.removeAll()
        runStatusIdleReturnTask?.cancel()
        runStatusIdleReturnTask = nil
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
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Screen content permission is persisted — once the user has approved the
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
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    if allPermissionsGranted && !isOverlayVisible && isBuddyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
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
    /// user grants them in System Settings. Screen Recording is the exception —
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
                // Don't override .responding — the AI response pipeline
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
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
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

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isBuddyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .loreleiDismissPanel, object: nil)

            // Cancel any in-progress placeholder response from a previous utterance
            currentResponseTask?.cancel()
            clearDetectedElementLocation()
            _ = resolvePendingCodexAppServerApproval(.cancel)

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
        case .none:
            break
        }
    }

    // MARK: - Local Command Routing Pipeline

#if DEBUG
    func handleFinalTranscriptForTesting(_ transcript: String) {
        handleFinalTranscriptLocally(transcript)
    }
#endif

    func stopCurrentRun() {
        guard currentResponseTask != nil
            || pendingCodexAppServerApproval != nil
        else {
            return
        }

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
        case .released:
            setRunStatusTranscribing()
        case .none:
            break
        }
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
                    recordDebugEvent("Steered: \(Self.conciseDebugLine(transcript))")
                } catch {
                    outstandingSteerTranscripts.removeValue(forKey: requestID)
                    recordDebugEvent("Steer failed - starting a new turn")
                    routeFinalTranscriptAsNewTurn(transcript)
                }
            }
            return
        }

        routeFinalTranscriptAsNewTurn(transcript)
    }

    private func routeFinalTranscriptAsNewTurn(_ transcript: String) {
        currentResponseTask?.cancel()
        _ = resolvePendingCodexAppServerApproval(.cancel)
        lastTranscript = transcript
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
                let result = await codexExecutor.run(
                    .readOnly,
                    prompt: prompt,
                    workspacePath: workspaceSettingsStore.selectedWorkspacePath
                )
                guard !Task.isCancelled else { return }

                finishRun(with: result)
                return
            case .codexWorkspaceWrite(let prompt):
                let result = await codexExecutor.run(
                    .workspaceWrite,
                    prompt: CodexPromptBuilder.workspaceWritePrompt(for: prompt),
                    workspacePath: workspaceSettingsStore.selectedWorkspacePath
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

        return await withDesktopActionOverlayHidden {
            if let codexAppServerDesktopActionRunner = self.codexAppServerDesktopActionRunner {
                return await codexAppServerDesktopActionRunner(appServerPrompt, cwd)
            }

            let executor = self.sharedCodexAppServerExecutor()
            return await executor.runDesktopAction(prompt: appServerPrompt, cwd: cwd)
        }
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
        axDesktopActionExecutor = executor
        return executor
    }

    private func withDesktopActionOverlayHidden(
        _ operation: @escaping @MainActor () async -> WorkspaceCommandResult
    ) async -> WorkspaceCommandResult {
        let shouldRestoreOverlay = isOverlayVisible && isBuddyCursorEnabled
        transientHideTask?.cancel()
        transientHideTask = nil
        clearDetectedElementLocation()

        if isOverlayVisible {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }

        defer {
            if shouldRestoreOverlay && isBuddyCursorEnabled {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }
        }

        return await operation()
    }

    private func recordDebugEvent(_ line: String) {
        debugLog.append(line)
    }

    private func setRunStatusListening() {
        runStatusIdleReturnTask?.cancel()
        runStatusIdleReturnTask = nil
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
    }

    private func beginRunStatus() {
        runStatusIdleReturnTask?.cancel()
        runStatusIdleReturnTask = nil
        streamText = ""
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
            recordDebugEvent("Steer failed - starting a new turn")
            routeFinalTranscriptAsNewTurn(transcript)
        case .agentMessageDelta(let delta):
            streamText += delta
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
        let succeeded = result.status == .succeeded
        finishRunStatus(success: succeeded)
        audioFeedback.play(succeeded ? .runSucceeded : .runFailed, spokenSummary: result.summary)
    }

    private func finishRunStatus(success: Bool) {
        runStatusIdleReturnTask?.cancel()
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
        scheduleTransientHideIfNeeded()
    }

    private func runCodexScreenRequest(_ prompt: String) async -> WorkspaceCommandResult {
        let runner = CodexScreenContextRequestRunner(codexExecutor: codexExecutor)
        return await runner.run(
            prompt: prompt,
            workspacePath: workspaceSettingsStore.selectedWorkspacePath
        )
    }

    /// If the cursor is in transient mode (user toggled the cursor off),
    /// waits for any pointing animation to finish, then fades out the overlay
    /// after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isBuddyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

}

@MainActor
struct CodexScreenContextRequestRunner {
    private let fileManager: FileManager
    private let codexExecutor: CodexExecutor
    private let captureCursorScreen: @MainActor () async throws -> CompanionScreenCapture?
    private let isCancelled: () -> Bool
    private let makeTemporaryImageURL: () -> URL

    init(
        fileManager: FileManager = .default,
        codexExecutor: CodexExecutor? = nil,
        captureCursorScreen: @escaping @MainActor () async throws -> CompanionScreenCapture? = {
            try await CompanionScreenCaptureUtility.captureCursorScreenAsJPEG()
        },
        isCancelled: @escaping () -> Bool = { Task.isCancelled },
        makeTemporaryImageURL: (() -> URL)? = nil
    ) {
        self.fileManager = fileManager
        self.codexExecutor = codexExecutor ?? CodexExecutor()
        self.captureCursorScreen = captureCursorScreen
        self.isCancelled = isCancelled
        self.makeTemporaryImageURL = makeTemporaryImageURL ?? {
            fileManager.temporaryDirectory
                .appendingPathComponent("lorelei-screen-\(UUID().uuidString).jpg")
        }
    }

    func run(prompt: String, workspacePath: String?) async -> WorkspaceCommandResult {
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

            return await codexExecutor.run(
                .readOnly,
                prompt: prompt,
                workspacePath: workspacePath,
                imagePaths: [imageURL.path],
                removeImageInputsAfterRun: true,
                ephemeral: true
            )
        } catch {
            return WorkspaceCommandResult(
                summary: "Screen capture failed: \(error.localizedDescription)",
                status: .failed
            )
        }
    }
}
