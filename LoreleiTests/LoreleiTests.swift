//
//  LoreleiTests.swift
//  LoreleiTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import AppKit
import Combine
import Foundation
import CoreGraphics
@testable import Lorelei

@MainActor
struct LoreleiTests {

    @Test func speechAnalyzerReducerCombinesVolatileAndFinalizedText() async throws {
        var reducer = SpeechAnalyzerTranscriptReducer()

        reducer.applyVolatile("hel")
        #expect(reducer.currentTranscript == "hel")

        reducer.applyVolatile("hello wor")
        #expect(reducer.currentTranscript == "hello wor")

        reducer.applyFinalized("hello world")
        #expect(reducer.currentTranscript == "hello world")
        #expect(reducer.finalizedText == "hello world")
        #expect(reducer.volatileText.isEmpty)

        reducer.applyVolatile("again")
        #expect(reducer.currentTranscript == "hello world again")
    }

    @Test func speechAnalyzerReducerFinalizeIsIdempotentPerSegment() async throws {
        var reducer = SpeechAnalyzerTranscriptReducer()

        reducer.applyFinalized("open textedit")
        reducer.applyFinalized("type hello")

        #expect(reducer.finalizedText == "open textedit type hello")
    }

    @Test func defaultTranscriptionProviderUsesSpeechAnalyzer() async throws {
        let provider = BuddyTranscriptionProviderFactory.makeProvider(preferredProviderRawValue: nil)

        #expect(provider is SpeechAnalyzerTranscriptionProvider)
        #expect(!provider.requiresSpeechRecognitionPermission)
    }

    @Test func appleTranscriptionProviderConfigUsesSpeechAnalyzer() async throws {
        let provider = BuddyTranscriptionProviderFactory.makeProvider(preferredProviderRawValue: "apple")

        #expect(provider is SpeechAnalyzerTranscriptionProvider)
        #expect(!provider.requiresSpeechRecognitionPermission)
    }

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func workspaceSelectionPersistsOnePath() async throws {
        let defaults = UserDefaults(suiteName: "WorkspaceSettingsStoreTests")!
        defaults.removePersistentDomain(forName: "WorkspaceSettingsStoreTests")

        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = "/Users/example/Project"

        let reloadedStore = WorkspaceSettingsStore(defaults: defaults)
        #expect(reloadedStore.selectedWorkspacePath == "/Users/example/Project")
    }

    @Test func workspaceStoreLoadsExistingValueFromDefaults() async throws {
        let defaults = UserDefaults(suiteName: "WorkspaceSettingsStoreExistingValueTests")!
        defaults.removePersistentDomain(forName: "WorkspaceSettingsStoreExistingValueTests")
        defaults.set("/Users/example/ExistingProject", forKey: WorkspaceSettingsStore.selectedWorkspacePathDefaultsKey)

        let store = WorkspaceSettingsStore(defaults: defaults)

        #expect(store.selectedWorkspacePath == "/Users/example/ExistingProject")
    }

    @Test func clearingWorkspaceSelectionRemovesPersistedValue() async throws {
        let defaults = UserDefaults(suiteName: "WorkspaceSettingsStoreClearingTests")!
        defaults.removePersistentDomain(forName: "WorkspaceSettingsStoreClearingTests")

        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = "/Users/example/Project"
        store.clearSelectedWorkspacePath()

        let reloadedStore = WorkspaceSettingsStore(defaults: defaults)
        #expect(defaults.string(forKey: WorkspaceSettingsStore.selectedWorkspacePathDefaultsKey) == nil)
        #expect(reloadedStore.selectedWorkspacePath == nil)
    }

    @Test func workspacePathStatusRequiresExistingDirectory() async throws {
        let defaults = UserDefaults(suiteName: "WorkspaceSettingsStoreDirectoryStatusTests")!
        defaults.removePersistentDomain(forName: "WorkspaceSettingsStoreDirectoryStatusTests")
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = temporaryDirectory.path
        #expect(store.selectedWorkspaceStatus == .validDirectory(temporaryDirectory.path))
        #expect(store.canOpenSelectedWorkspace)

        store.selectedWorkspacePath = temporaryDirectory.appendingPathComponent("missing").path
        #expect(store.selectedWorkspaceStatus == .invalidDirectory(store.selectedWorkspacePath!))
        #expect(!store.canOpenSelectedWorkspace)
    }

    @Test func companionManagerUsesInjectedWorkspaceSettingsStore() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerWorkspaceSettingsStoreTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerWorkspaceSettingsStoreTests")
        let store = WorkspaceSettingsStore(defaults: defaults)

        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store
        )
        store.selectedWorkspacePath = "/Users/example/SharedProject"

        #expect(manager.workspaceSettingsStore.selectedWorkspacePath == "/Users/example/SharedProject")
    }

    @Test func companionManagerRunsDesktopActionThroughInjectedAppServerRunnerImmediately() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerDesktopActionRunnerTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerDesktopActionRunnerTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let recorder = AppServerDesktopActionRecorder(
            result: WorkspaceCommandResult(summary: "Opened through App Server.")
        )
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerDesktopActionRunner: recorder.run
        )

        manager.handleFinalTranscriptForTesting("Open chatgpt.com in a new tab on chrome browser")
        for _ in 0..<20 {
            if recorder.calls.count == 1,
               manager.latestResultSummary == "Opened through App Server." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.pendingApprovalTitle == nil)
        #expect(recorder.calls.count == 1)
        let call = try #require(recorder.calls.first)
        #expect(call.prompt.contains("Codex App Server"))
        #expect(call.prompt.contains("chatgpt.com"))
        #expect(call.prompt.contains("chrome browser"))
        #expect(call.prompt.contains("lorelei.desktop_snapshot"))
        #expect(call.prompt.contains("Call lorelei.foreground_app to bring the target app"))
        #expect(call.cwd == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(manager.latestResultSummary == "Opened through App Server.")
    }

    @Test func companionManagerRegistersDesktopToolSuiteWithForegroundTool() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerDesktopToolSuiteRegistrationTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerDesktopToolSuiteRegistrationTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Registered tools."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport }
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if manager.latestResultSummary == "Registered tools." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentLines.map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let threadStart = try #require(sentMessages.first { $0["method"] as? String == "thread/start" })
        let threadStartParams = try #require(threadStart["params"] as? [String: Any])
        let dynamicTools = try #require(threadStartParams["dynamicTools"] as? [[String: Any]])
        let toolNames = dynamicTools.compactMap { $0["name"] as? String }

        #expect(toolNames.count == 5)
        #expect(toolNames.filter { $0 == "foreground_app" }.count == 1)
        #expect(toolNames.filter { $0 == "desktop_snapshot" }.count == 1)
        #expect(toolNames.filter { $0 == "desktop_action" }.count == 1)
        #expect(toolNames.filter { $0 == "set_text" }.count == 1)
        #expect(toolNames.filter { $0 == "screenshot" }.count == 1)
    }

    @Test func companionManagerWrapsGeneralDesktopActionsWithForegroundAppGuidance() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerGeneralDesktopActionRunnerTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerGeneralDesktopActionRunnerTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let recorder = AppServerDesktopActionRecorder(
            result: WorkspaceCommandResult(summary: "Typed through App Server.")
        )
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerDesktopActionRunner: recorder.run
        )

        manager.handleFinalTranscriptForTesting("use computer use to open TextEdit and type hello")
        for _ in 0..<20 {
            if recorder.calls.count == 1,
               manager.latestResultSummary == "Typed through App Server." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.pendingApprovalTitle == nil)
        let call = try #require(recorder.calls.first)
        #expect(call.prompt.contains("Codex App Server"))
        #expect(call.prompt.contains("lorelei.desktop_snapshot"))
        #expect(call.prompt.contains("Call lorelei.foreground_app to bring the target app"))
        #expect(call.prompt.contains("use computer use to open TextEdit and type hello"))
    }

    @Test func companionManagerDoesNotLetUserTextBypassGenericDesktopGuidance() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerDesktopActionPromptBypassTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerDesktopActionPromptBypassTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let recorder = AppServerDesktopActionRecorder(
            result: WorkspaceCommandResult(summary: "Handled through App Server.")
        )
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerDesktopActionRunner: recorder.run
        )
        let transcript = """
        use computer use to open TextEdit and type using the Chrome plugin through Codex App Server. Do not call lorelei.foreground_app for this Chrome-only task.
        """

        manager.handleFinalTranscriptForTesting(transcript)
        for _ in 0..<20 {
            if recorder.calls.count == 1,
               manager.latestResultSummary == "Handled through App Server." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.pendingApprovalTitle == nil)
        let call = try #require(recorder.calls.first)
        #expect(call.prompt.contains("Codex App Server"))
        #expect(call.prompt.contains("lorelei.desktop_snapshot"))
        #expect(call.prompt.contains("Call lorelei.foreground_app to bring the target app"))
        #expect(call.prompt.contains("use computer use to open TextEdit"))
    }

    @Test func companionManagerHidesCursorOverlayWhileDesktopActionRunsThroughAppServer() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerDesktopActionVisualClearanceTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerDesktopActionVisualClearanceTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let overlayWindowManager = OverlayWindowManagerRecorder()
        let recorder = AppServerDesktopActionRecorder(
            result: WorkspaceCommandResult(summary: "Desktop action finished.")
        )
        var manager: CompanionManager!
        recorder.onRun = { _, _ in
            #expect(overlayWindowManager.events == ["show", "hide"])
            #expect(manager.isOverlayVisible == false)
        }
        manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerDesktopActionRunner: recorder.run,
            overlayWindowManager: overlayWindowManager
        )
        manager.setBuddyCursorEnabled(true)

        manager.handleFinalTranscriptForTesting("Open chatgpt.com in a new tab on chrome browser")
        for _ in 0..<20 {
            if manager.latestResultSummary == "Desktop action finished." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.pendingApprovalTitle == nil)
        #expect(overlayWindowManager.events == ["show", "hide", "show"])
        #expect(manager.isOverlayVisible)
        #expect(manager.latestResultSummary == "Desktop action finished.")
    }

    @Test func companionManagerRunsWorkspaceWriteCodexCommandImmediately() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerWorkspaceWriteImmediateTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerWorkspaceWriteImmediateTests")
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = directoryURL.path
        let recorder = CodexCommandRecorder(finalMessage: "Updated README.")
        let codexExecutor = CodexExecutor(
            codexExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            commandRunner: recorder.run
        )
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexExecutor: codexExecutor
        )

        manager.handleFinalTranscriptForTesting("update the readme")
        for _ in 0..<20 {
            if recorder.arguments != nil,
               manager.latestResultSummary == "Updated README." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.pendingApprovalTitle == nil)
        #expect(manager.latestResultSummary == "Updated README.")
        #expect(recorder.arguments?.contains("workspace-write") == true)
        #expect(recorder.arguments?.contains(CodexPromptBuilder.workspaceWritePrompt(for: "update the readme")) == true)
    }

    @Test func companionManagerRecordsDebugLogForImmediateDesktopAction() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerDebugLogDesktopActionTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerDebugLogDesktopActionTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let recorder = AppServerDesktopActionRecorder(
            result: WorkspaceCommandResult(summary: "Opened through App Server.")
        )
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerDesktopActionRunner: recorder.run
        )

        manager.handleFinalTranscriptForTesting("Open chatgpt.com in a new tab on chrome browser")
        for _ in 0..<20 {
            if manager.latestResultSummary == "Opened through App Server." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.pendingApprovalTitle == nil)
        #expect(manager.debugLogText.contains("Transcript: Open chatgpt.com in a new tab on chrome browser"))
        #expect(manager.debugLogText.contains("Route: Codex desktop action"))
        #expect(manager.debugLogText.contains("Codex App Server desktop action started"))
        #expect(manager.debugLogText.contains("Result: Opened through App Server."))
    }

    @Test func companionDebugLogKeepsMostRecentLines() throws {
        var log = CompanionDebugLog(maxLines: 3)

        log.append("one")
        log.append("two")
        log.append("three")
        log.append("four")

        #expect(log.lines == ["two", "three", "four"])
        #expect(log.text == "two\nthree\nfour")
    }

    @Test func loginItemRegistrationIsOptInByDefault() async throws {
        let defaults = UserDefaults(suiteName: "LoginItemRegistrationPolicyTests")!
        defaults.removePersistentDomain(forName: "LoginItemRegistrationPolicyTests")

        #expect(!LoginItemRegistrationPolicy.shouldRegisterOnLaunch(defaults: defaults))

        defaults.set(true, forKey: LoginItemRegistrationPolicy.enabledDefaultsKey)
        #expect(LoginItemRegistrationPolicy.shouldRegisterOnLaunch(defaults: defaults))
    }

    @Test func routerMapsShowGitStatusToStatus() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("show git status") == .gitStatus)
    }

    @Test func routerMapsWhatChangedToDiff() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("what changed?") == .gitDiff)
    }

    @Test func routerMapsRunTestsToTests() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("run tests") == .runTests)
    }

    @Test func routerMapsTestToTests() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("test") == .runTests)
    }

    @Test func routerMapsTestsToTests() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("tests") == .runTests)
    }

    @Test func routerReturnsUnsupportedForUnknownText() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("") == .unsupported("I didn't catch a command."))
    }

    @Test func routerMapsGenericReadOnlyQuestionToCodexReadOnly() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("why is auth failing?") == .codexReadOnly("why is auth failing?"))
    }

    @Test func routerMapsMutatingRequestToCodexWorkspaceWrite() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("fix the failing test") == .codexWorkspaceWrite("fix the failing test"))
    }

    @Test func routerMapsAdditionalMutatingRequestsToCodexWorkspaceWrite() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("update docs") == .codexWorkspaceWrite("update docs"))
        #expect(router.route("add a test") == .codexWorkspaceWrite("add a test"))
        #expect(router.route("rename file") == .codexWorkspaceWrite("rename file"))
    }

    @Test func routerPreservesClearLocalStatusDiffAndTestCommandsBeforeMutatingWords() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("status update") == .gitStatus)
        #expect(router.route("diff update") == .gitDiff)
        #expect(router.route("test update") == .runTests)
    }

    @Test func routerMapsScreenRequestToCodexScreen() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("look at my screen") == .codexScreen("look at my screen"))
    }

    @Test func routerDoesNotMapAmbiguousWhatDoYouSeeToCodexScreen() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("what do you see in this error?") == .codexReadOnly("what do you see in this error?"))
    }

    @Test func routerDoesNotMapAppWindowCommandToCodexScreen() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("open the app window") == .codexDesktopAction("open the app window"))
    }

    @Test func routerDoesNotMapDesktopCommandToCodexScreen() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("switch desktop") == .codexReadOnly("switch desktop"))
    }

    @Test func routerMapsClickRequestToCodexDesktopAction() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("click the submit button") == .codexDesktopAction("click the submit button"))
    }

    @Test func routerMapsBrowserOperationToCodexDesktopAction() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("open the browser and search for Swift concurrency") == .codexDesktopAction("open the browser and search for Swift concurrency"))
    }

    @Test func routerMapsBrowserRequestsToDesktopAction() async throws {
        let router = LoreleiCommandRouter()
        let openTranscript = "open gmail in chrome"
        let typingTranscript = "type hello into the search box in chrome"

        #expect(router.route(openTranscript) == .codexDesktopAction(openTranscript))
        #expect(router.route(typingTranscript) == .codexDesktopAction(typingTranscript))
    }

    @Test func routerMapsExplicitComputerUsePhraseToCodexDesktopAction() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("use computer use to open System Settings") == .codexDesktopAction("use computer use to open System Settings"))
    }

    @Test func workspaceWritePromptIncludesNoCommitGuard() async throws {
        let prompt = CodexPromptBuilder.workspaceWritePrompt(for: "fix the test")

        #expect(prompt.contains("Do not commit changes."))
        #expect(prompt.contains("fix the test"))
    }

    @Test func desktopActionPromptRequiresAppServerControlPlaneAndScopedDesktopActions() async throws {
        let prompt = CodexPromptBuilder.desktopActionPrompt(for: "open TextEdit and type hello")

        #expect(prompt.contains("Codex App Server"))
        #expect(prompt.contains("lorelei.desktop_snapshot"))
        #expect(prompt.contains("lorelei.desktop_action"))
        #expect(prompt.contains("lorelei.set_text"))
        #expect(prompt.contains("lorelei.screenshot"))
        #expect(prompt.contains("Do not simulate keyboard shortcuts."))
        #expect(prompt.contains("Do not commit changes."))
        #expect(!prompt.contains("non-interactive codex exec"))
        #expect(prompt.contains("open TextEdit and type hello"))
    }

    @Test func responseTaskTrackerIgnoresStaleTaskCleanup() async throws {
        var tracker = CompanionResponseTaskTracker()

        let oldTaskID = tracker.begin()
        let newTaskID = tracker.begin()
        let didFinishOldTask = tracker.finishIfCurrent(oldTaskID)
        let currentTaskIDAfterOldFinish = tracker.currentTaskID
        let didFinishNewTask = tracker.finishIfCurrent(newTaskID)

        #expect(!didFinishOldTask)
        #expect(currentTaskIDAfterOldFinish == newTaskID)
        #expect(didFinishNewTask)
        #expect(tracker.currentTaskID == nil)
    }

    @Test func speechStatusUsesShortAllowedPhrases() async throws {
        #expect(WorkspaceCommandResult(summary: "OK", status: .succeeded).spokenStatus == "Done")
        #expect(WorkspaceCommandResult(summary: "No workspace selected.", status: .missingWorkspace).spokenStatus == "No workspace selected")
        #expect(WorkspaceCommandResult(summary: "Failed", status: .failed).spokenStatus == "Failed")
    }

    @Test func firstSentenceCutsAtTerminatorAndCap() async throws {
        #expect(BuddyAudioFeedback.firstSentence("Opened Gmail. Then waited.") == "Opened Gmail.")
        #expect(BuddyAudioFeedback.firstSentence(String(repeating: "a", count: 300)).count == 120)
        #expect(BuddyAudioFeedback.firstSentence(String(repeating: "a", count: 300)).hasSuffix("…"))
        #expect(BuddyAudioFeedback.firstSentence("Gmailを開きました。次に…") == "Gmailを開きました。")
    }

    @Test func toolbarPanelFrameCentersAtTopOfScreen() async throws {
        let frame = LoreleiToolbarController.panelFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 2000, height: 1200),
            size: CGSize(width: 260, height: 36),
            topInset: 8
        )

        #expect(frame == CGRect(x: 870, y: 1156, width: 260, height: 36))
    }

    @Test func cursorCapsuleSitsRightOfCursor() async throws {
        let origin = BlueCursorView.capsuleOrigin(
            cursorPoint: CGPoint(x: 500, y: 500),
            capsuleSize: CGSize(width: 140, height: 34),
            screenFrame: CGRect(x: 0, y: 0, width: 2000, height: 1200)
        )

        #expect(origin == CGPoint(x: 518, y: 483))
    }

    @Test func cursorCapsuleFlipsLeftNearRightEdge() async throws {
        let origin = BlueCursorView.capsuleOrigin(
            cursorPoint: CGPoint(x: 1950, y: 500),
            capsuleSize: CGSize(width: 140, height: 34),
            screenFrame: CGRect(x: 0, y: 0, width: 2000, height: 1200)
        )

        #expect(origin == CGPoint(x: 1792, y: 483))
    }

    @Test func toolbarStatusLabelReflectsRunStatus() async throws {
        #expect(LoreleiToolbarView.statusLabel(for: .idle) == "Ready")
        #expect(LoreleiToolbarView.statusLabel(for: .listening) == "Listening…")
        #expect(LoreleiToolbarView.statusLabel(for: .transcribing) == "Transcribing…")
        #expect(LoreleiToolbarView.statusLabel(for: .working("lorelei.set_text")) == "lorelei.set_text")
        #expect(LoreleiToolbarView.statusLabel(for: .needsApproval("Run command")) == "Needs approval")
        #expect(LoreleiToolbarView.statusLabel(for: .finished(success: false)) == "Failed")
    }

    @Test func toolbarAutoExpandsOnApprovalRequest() async throws {
        let defaults = UserDefaults(suiteName: "ToolbarAutoExpansionApprovalTests")!
        defaults.removePersistentDomain(forName: "ToolbarAutoExpansionApprovalTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":44,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow control?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow."},{"label":"Decline","description":"Stop."}]}]}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )
        let controller = LoreleiToolbarController(companionManager: manager)

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if controller.isExpanded {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .needsApproval("Computer Use"))
        #expect(controller.isExpanded)
    }

    @Test func settingsPanelFrameFallsBackToScreenCenter() async throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let panelSize = CGSize(width: 320, height: 380)

        let nilAnchorFrame = MenuBarPanelManager.settingsPanelFrame(
            anchorFrame: nil,
            screenFrame: screenFrame,
            panelSize: panelSize
        )
        let offscreenAnchorFrame = MenuBarPanelManager.settingsPanelFrame(
            anchorFrame: CGRect(x: -500, y: 2000, width: 24, height: 24),
            screenFrame: screenFrame,
            panelSize: panelSize
        )

        #expect(nilAnchorFrame == CGRect(x: 840, y: 410, width: 320, height: 380))
        #expect(offscreenAnchorFrame == nilAnchorFrame)
    }

    @Test func workspaceExecutorReportsMissingWorkspaceWithoutRunningProcess() async throws {
        let executor = WorkspaceCommandExecutor()

        let result = await executor.run(.gitStatus, workspacePath: nil)

        #expect(result.summary == "No workspace selected.")
    }

    @Test func workspaceExecutorRunsStatusInTemporaryGitRepo() async throws {
        let repositoryURL = try makeTemporaryGitRepository()
        defer { try? FileManager.default.removeItem(at: repositoryURL) }
        let executor = WorkspaceCommandExecutor()

        let result = await executor.run(.gitStatus, workspacePath: repositoryURL.path)

        #expect(result.summary.contains("##"))
    }

    @Test func workspaceExecutorReportsNonGitWorkspaceFailure() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let executor = WorkspaceCommandExecutor()

        let result = await executor.run(.gitStatus, workspacePath: directoryURL.path)

        #expect(result.summary.contains("failed with exit code"))
        #expect(result.summary.localizedCaseInsensitiveContains("not a git repository"))
    }

    @Test func workspaceExecutorReportsRunningCommandTimeout() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let executor = WorkspaceCommandExecutor(
            commandTimeoutSeconds: 0.1,
            testCommandOverride: WorkspaceCommandTestHook(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"]
            )
        )

        let result = await executor.run(.gitStatus, workspacePath: directoryURL.path)

        #expect(result.summary == "Command timed out.")
    }

    @Test func workspaceProcessRunnerTimeoutCompletesWhenChildKeepsPipeOpen() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let runner = WorkspaceProcessRunner()

        let execution = await withTimeout(seconds: 1.0) {
            await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 3 & wait"],
                currentDirectoryURL: directoryURL,
                timeoutSeconds: 0.1
            )
        }

        #expect(execution != nil)
        guard let execution else { return }
        #expect(isTimedOut(execution.reason))
    }

    @Test func workspaceExecutorCancelsRunningCommand() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let executor = WorkspaceCommandExecutor(
            commandTimeoutSeconds: 5,
            testCommandOverride: WorkspaceCommandTestHook(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"]
            )
        )

        let task = Task {
            await executor.run(.gitStatus, workspacePath: directoryURL.path)
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        let result = await task.value

        #expect(result.summary == "Command cancelled.")
    }

    @Test func workspaceExecutorDoesNotLaunchAfterPrelaunchCancellation() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let launchCounter = LaunchCounter()
        let executor = WorkspaceCommandExecutor(
            commandTimeoutSeconds: 5,
            testCommandOverride: WorkspaceCommandTestHook(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["1"],
                prelaunchDelay: 0.3,
                onLaunch: {
                    launchCounter.increment()
                }
            )
        )

        let task = Task {
            await executor.run(.gitStatus, workspacePath: directoryURL.path)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        let result = await task.value

        #expect(result.summary == "Command cancelled.")
        #expect(launchCounter.value == 0)
    }

    @Test func workspaceExecutorReportsMissingTestCommandAsFailure() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let executor = WorkspaceCommandExecutor()

        let result = await executor.run(.runTests, workspacePath: directoryURL.path)

        #expect(result.summary == "No test command configured.")
        #expect(result.status == .failed)
        #expect(result.spokenStatus == "Failed")
    }

    @Test func workspaceExecutorDoesNotRunDesktopActionsLocally() async throws {
        let executor = WorkspaceCommandExecutor()

        let result = await executor.run(.codexDesktopAction("open https://chatgpt.com in Chrome"), workspacePath: nil)

        #expect(result.summary == "Codex commands are handled by CodexExecutor.")
        #expect(result.status == .succeeded)
    }

    @Test func codexExecutorBuildsReadOnlyCommand() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let recorder = CodexCommandRecorder(finalMessage: "Read-only answer")
        let executor = CodexExecutor(
            codexExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            commandRunner: recorder.run
        )

        let result = await executor.run(.readOnly, prompt: "explain the diff", workspacePath: directoryURL.path)

        #expect(result.summary == "Read-only answer")
        #expect(recorder.executableURL?.path == "/usr/local/bin/codex")
        #expect(recorder.currentDirectoryURL == directoryURL)
        #expect(recorder.arguments?.starts(with: ["exec", "--sandbox", "read-only", "--cd", directoryURL.path]) == true)
        #expect(recorder.arguments?.contains("--output-last-message") == true)
        #expect(recorder.outputLastMessagePath != nil)
    }

    @Test func codexExecutorBuildsReadOnlyCommandWithImageInput() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let imagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lorelei-test-\(UUID().uuidString).jpg")
            .path
        let recorder = CodexCommandRecorder(finalMessage: "Screen answer")
        let executor = CodexExecutor(
            codexExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            commandRunner: recorder.run
        )

        let result = await executor.run(
            .readOnly,
            prompt: "look at my screen",
            workspacePath: directoryURL.path,
            imagePaths: [imagePath],
            ephemeral: true
        )

        #expect(result.summary == "Screen answer")
        #expect(recorder.arguments?.starts(with: [
            "exec",
            "--ephemeral",
            "-i",
            imagePath,
            "--sandbox",
            "read-only",
            "--cd",
            directoryURL.path
        ]) == true)
        #expect(recorder.arguments?.contains("--output-last-message") == true)
        #expect(recorder.outputLastMessagePath != nil)
        #expect(recorder.arguments?.last == "look at my screen")
    }

    @Test func codexExecutorCleansUpImageInputsWhenRequested() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("lorelei-test-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: imageURL)
        let recorder = CodexCommandRecorder(finalMessage: "Screen answer")
        let executor = CodexExecutor(
            codexExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            commandRunner: recorder.run
        )

        let result = await executor.run(
            .readOnly,
            prompt: "look at my screen",
            workspacePath: directoryURL.path,
            imagePaths: [imageURL.path],
            removeImageInputsAfterRun: true
        )

        #expect(result.summary == "Screen answer")
        #expect(!FileManager.default.fileExists(atPath: imageURL.path))
    }

    @Test func screenContextRunnerDoesNotCaptureForInvalidWorkspace() async throws {
        let captureCounter = LaunchCounter()
        let missingWorkspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let recorder = CodexCommandRecorder(finalMessage: "Should not run")
        let executor = CodexExecutor(
            codexExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            commandRunner: recorder.run
        )
        let runner = CodexScreenContextRequestRunner(
            codexExecutor: executor,
            captureCursorScreen: {
                captureCounter.increment()
                return nil
            }
        )

        let result = await runner.run(prompt: "look at my screen", workspacePath: missingWorkspace.path)

        #expect(result.summary == "Workspace path is not a valid directory: \(missingWorkspace.path)")
        #expect(captureCounter.value == 0)
        #expect(recorder.arguments == nil)
    }

    @Test func screenContextRunnerCancelsBeforeWritingTempImage() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let captureCounter = LaunchCounter()
        let tempURLCounter = LaunchCounter()
        let recorder = CodexCommandRecorder(finalMessage: "Should not run")
        let executor = CodexExecutor(
            codexExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            commandRunner: recorder.run
        )
        let runner = CodexScreenContextRequestRunner(
            codexExecutor: executor,
            captureCursorScreen: {
                captureCounter.increment()
                return CompanionScreenCapture(
                    imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
                    label: "user's screen (cursor is here)",
                    isCursorScreen: true,
                    displayWidthInPoints: 100,
                    displayHeightInPoints: 100,
                    displayFrame: .zero,
                    screenshotWidthInPixels: 100,
                    screenshotHeightInPixels: 100
                )
            },
            isCancelled: { true },
            makeTemporaryImageURL: {
                tempURLCounter.increment()
                return FileManager.default.temporaryDirectory
                    .appendingPathComponent("should-not-be-created-\(UUID().uuidString).jpg")
            }
        )

        let result = await runner.run(prompt: "look at my screen", workspacePath: directoryURL.path)

        #expect(result.summary == "Screen capture cancelled.")
        #expect(captureCounter.value == 1)
        #expect(tempURLCounter.value == 0)
        #expect(recorder.arguments == nil)
    }

    @Test func codexExecutorBuildsWorkspaceWriteCommand() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let recorder = CodexCommandRecorder(finalMessage: "Write-mode answer")
        let executor = CodexExecutor(
            codexExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            commandRunner: recorder.run
        )

        let result = await executor.run(.workspaceWrite, prompt: "fix the test", workspacePath: directoryURL.path)

        #expect(result.summary == "Write-mode answer")
        #expect(recorder.arguments?.starts(with: [
            "--ask-for-approval",
            "never",
            "exec",
            "--sandbox",
            "workspace-write",
            "--cd",
            directoryURL.path
        ]) == true)
        #expect(recorder.arguments?.contains("--output-last-message") == true)
        #expect(recorder.outputLastMessagePath != nil)
    }

    @Test func launchEnvironmentPrependsNodeInstallPaths() async throws {
        let path = WorkspaceProcessRunner.launchEnvironment()["PATH"] ?? ""

        #expect(path.contains("/opt/homebrew/bin") || path.contains(".nvm/versions/node"))
    }

    @Test func codexLaunchCommandUsesSiblingNodeForNvmInstall() async throws {
        let codexURL = URL(fileURLWithPath: "/Users/taishi/.nvm/versions/node/v22.14.0/bin/codex")
        guard FileManager.default.isExecutableFile(atPath: codexURL.path) else { return }

        let launch = CodexExecutor.makeLaunchCommand(
            codexExecutableURL: codexURL,
            codexArguments: ["exec", "--help"]
        )

        #expect(launch.executableURL.lastPathComponent == "node")
        #expect(launch.arguments.first?.hasSuffix("codex.js") == true)
        #expect(launch.arguments.dropFirst().starts(with: ["exec", "--help"]))
    }

    @Test func codexExecutableLocatorUsesDefaultsOverride() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let codexURL = directoryURL.appendingPathComponent("codex")
        try "#!/bin/sh\n".write(to: codexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codexURL.path
        )
        let defaults = UserDefaults(suiteName: "CodexExecutableLocatorTests")!
        defaults.removePersistentDomain(forName: "CodexExecutableLocatorTests")
        defaults.set(codexURL.path, forKey: CodexExecutableLocator.executablePathDefaultsKey)

        let locator = CodexExecutableLocator(defaults: defaults)

        #expect(locator.resolve() == codexURL)
    }

    @Test func appServerLaunchUsesDefaultStdioTransport() async throws {
        let codexURL = URL(fileURLWithPath: "/usr/local/bin/codex")

        let launch = CodexAppServerLaunch.make(
            codexExecutableURL: codexURL
        )

        #expect(launch.executableURL == codexURL)
        #expect(launch.arguments == ["app-server"])
    }

    @Test func stdioTransportRoundTripsOneJSONLineThroughChildProcess() async throws {
        let transport = try await CodexAppServerStdioTransport.make(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )

        try await transport.send(line: "{\"id\":1,\"method\":\"initialize\"}")
        let echoed = try await transport.nextLine()

        #expect(echoed == "{\"id\":1,\"method\":\"initialize\"}")
        await transport.terminate()
    }

    @Test func stdioTransportAppendsExactlyOneNewlinePerSend() async throws {
        let transport = try await CodexAppServerStdioTransport.make(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: []
        )

        try await transport.send(line: "{\"a\":1}\n")
        try await transport.send(line: "{\"b\":2}")
        let first = try await transport.nextLine()
        let second = try await transport.nextLine()

        #expect(first == "{\"a\":1}")
        #expect(second == "{\"b\":2}")
        await transport.terminate()
    }

    @Test func stdioTransportReturnsNilAfterChildExits() async throws {
        let transport = try await CodexAppServerStdioTransport.make(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: []
        )

        let line = try await transport.nextLine()

        #expect(line == nil)
        await transport.terminate()
    }

    @Test func appServerInitializedNotificationMatchesGeneratedProtocolShape() throws {
        let notification = CodexAppServerProtocol.initializedNotification()

        #expect(notification["method"] as? String == "initialized")
        #expect(!notification.keys.contains("params"))
    }

    @Test func appServerTurnStartIncludesTextElementsAndGranularApprovalPolicy() throws {
        let request = CodexAppServerProtocol.turnStartRequest(
            id: 3,
            threadID: "thread-1",
            prompt: "open TextEdit",
            cwd: "/Users/example"
        )
        let params = try #require(request["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])
        let textInput = try #require(input.first)
        let approvalPolicy = try #require(params["approvalPolicy"] as? [String: Any])
        let granular = try #require(approvalPolicy["granular"] as? [String: Any])

        #expect(textInput["type"] as? String == "text")
        #expect(textInput["text"] as? String == "open TextEdit")
        #expect((textInput["text_elements"] as? [Any])?.isEmpty == true)
        #expect(granular["sandbox_approval"] as? Bool == true)
        #expect(granular["rules"] as? Bool == true)
        #expect(granular["skill_approval"] as? Bool == true)
        #expect(granular["request_permissions"] as? Bool == true)
        #expect(granular["mcp_elicitations"] as? Bool == true)
    }

    @Test func appServerTurnStartRequestPinsModelToGPT55() throws {
        let request = CodexAppServerProtocol.turnStartRequest(
            id: 3,
            threadID: "thread-1",
            prompt: "open Gmail",
            cwd: "/Users/example"
        )
        let params = try #require(request["params"] as? [String: Any])

        #expect(params["model"] as? String == "gpt-5.5")
    }

    @Test func appServerThreadStartSendsNoPluginConfig() throws {
        let request = CodexAppServerProtocol.threadStartRequest(id: 2, cwd: "/Users/example")
        let params = try #require(request["params"] as? [String: Any])

        #expect(params["config"] == nil)
    }

    @Test func appServerThreadStartCanRegisterDynamicTools() throws {
        let request = CodexAppServerProtocol.threadStartRequest(
            id: 2,
            cwd: "/Users/example",
            dynamicTools: [
                CodexAppServerDynamicToolSpec(
                    name: "foreground_app",
                    namespace: "lorelei",
                    description: "Bring an app onscreen.",
                    inputSchema: .object([
                        "type": .string("object"),
                        "properties": .object([
                            "bundleIdentifier": .object([
                                "type": .string("string")
                            ])
                        ])
                    ])
                )
            ]
        )
        let params = try #require(request["params"] as? [String: Any])
        let dynamicTools = try #require(params["dynamicTools"] as? [[String: Any]])
        let tool = try #require(dynamicTools.first)
        let inputSchema = try #require(tool["inputSchema"] as? [String: Any])

        #expect(tool["name"] as? String == "foreground_app")
        #expect(tool["namespace"] as? String == "lorelei")
        #expect(tool["description"] as? String == "Bring an app onscreen.")
        #expect(inputSchema["type"] as? String == "object")
    }

    @Test func foregroundDynamicToolSpecRegistersLoreleiForegroundApp() throws {
        let spec = CodexAppServerDesktopForegroundTool.spec

        #expect(spec.name == "foreground_app")
        #expect(spec.namespace == "lorelei")
        #expect(spec.description.contains("current macOS Space"))

        guard case .object(let schema) = spec.inputSchema else {
            Issue.record("Expected object input schema.")
            return
        }
        guard case .object(let properties) = schema["properties"] else {
            Issue.record("Expected schema properties.")
            return
        }

        #expect(schema["type"] == .string("object"))
        #expect(properties["appName"] != nil)
        #expect(properties["bundleIdentifier"] != nil)
        #expect(properties["url"] != nil)
        #expect(properties["maxSpaceSwitches"] != nil)
    }

    @Test func foregroundDynamicToolOpensURLActivatesAndReturnsWhenWindowAlreadyOnscreen() async throws {
        let recorder = ForegroundEnvironmentRecorder(onscreenResults: [true])
        let tool = CodexAppServerDesktopForegroundTool(environment: recorder.environment())

        let result = await tool.handle(foregroundToolRequest(arguments: .object([
            "appName": .string("Google Chrome"),
            "bundleIdentifier": .string("com.google.Chrome"),
            "url": .string("https://chatgpt.com")
        ])))

        #expect(result.success)
        #expect(textContent(result)?.contains("Google Chrome") == true)
        #expect(textContent(result)?.contains("onscreen") == true)
        #expect(recorder.events == [
            "open:https://chatgpt.com:Google Chrome:com.google.Chrome",
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome"
        ])
    }

    @Test func foregroundDynamicToolCyclesSpacesUntilTargetWindowIsOnscreen() async throws {
        let recorder = ForegroundEnvironmentRecorder(onscreenResults: [false, false, true])
        let tool = CodexAppServerDesktopForegroundTool(environment: recorder.environment())

        let result = await tool.handle(foregroundToolRequest(arguments: .object([
            "appName": .string("Google Chrome"),
            "bundleIdentifier": .string("com.google.Chrome"),
            "maxSpaceSwitches": .number(3)
        ])))

        #expect(result.success)
        #expect(recorder.spaceDirections == [.right, .right])
        #expect(recorder.events == [
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome",
            "switch:right",
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome",
            "switch:right",
            "activate:Google Chrome:com.google.Chrome",
            "check:Google Chrome:com.google.Chrome"
        ])
    }

    @Test func foregroundDynamicToolReportsMissingTarget() async throws {
        let recorder = ForegroundEnvironmentRecorder(onscreenResults: [])
        let tool = CodexAppServerDesktopForegroundTool(environment: recorder.environment())

        let result = await tool.handle(foregroundToolRequest(arguments: .object([:])))

        #expect(!result.success)
        #expect(textContent(result)?.contains("appName or bundleIdentifier") == true)
        #expect(recorder.events.isEmpty)
    }

    @Test func codexExecutorReportsMissingWorkspace() async throws {
        let recorder = CodexCommandRecorder(finalMessage: "Should not run")
        let executor = CodexExecutor(
            codexExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            commandRunner: recorder.run
        )

        let result = await executor.run(.readOnly, prompt: "explain this", workspacePath: nil)

        #expect(result.summary == "No workspace selected.")
        #expect(recorder.arguments == nil)
    }

    @Test func codexExecutorReportsMissingExecutable() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let recorder = CodexCommandRecorder(finalMessage: "Should not run")
        let executor = CodexExecutor(
            codexExecutableResolver: { nil },
            commandRunner: recorder.run
        )

        let result = await executor.run(.readOnly, prompt: "explain this", workspacePath: directoryURL.path)

        #expect(result.summary.contains("Codex executable was not found."))
        #expect(recorder.arguments == nil)
    }

    @Test func appServerProtocolParsesThreadStartResponse() throws {
        let line = """
        {"id":1,"result":{"thread":{"id":"thread-1"}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .threadStarted(requestID: 1, threadID: "thread-1"))
    }

    @Test func appServerProtocolParsesAgentMessageDelta() throws {
        let line = """
        {"method":"item/agentMessage/delta","params":{"delta":"Opened TextEdit."}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .agentMessageDelta("Opened TextEdit."))
    }

    @Test func appServerProtocolParsesToolUserInputRequest() throws {
        let line = """
        {"id":42,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow Codex to control Google Chrome?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow this action."},{"label":"Decline","description":"Stop this action."}]}]}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .approvalRequest(
            CodexAppServerApprovalRequest(
                requestID: 42,
                kind: .toolUserInput,
                title: "Computer Use",
                detail: "Allow Codex to control Google Chrome?",
                acceptPayload: .toolUserInput(questionID: "approval", answer: "Accept"),
                declinePayload: .toolUserInput(questionID: "approval", answer: "Decline")
            )
        ))
    }

    @Test func appServerProtocolParsesCommandApprovalRequest() throws {
        let line = """
        {"id":43,"method":"item/commandExecution/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-2","reason":"Need to open a local app.","command":"/usr/bin/open -a TextEdit","cwd":"/Users/example"}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .approvalRequest(
            CodexAppServerApprovalRequest(
                requestID: 43,
                kind: .commandExecution,
                title: "Codex command approval",
                detail: "Need to open a local app.\n/usr/bin/open -a TextEdit",
                acceptPayload: .commandDecision("accept"),
                declinePayload: .commandDecision("cancel")
            )
        ))
    }

    @Test func appServerProtocolParsesMcpElicitationRequestAsApproval() throws {
        let line = """
        {"id":0,"method":"mcpServer/elicitation/request","params":{"threadId":"thread-1","turnId":"turn-1","serverName":"example-server","mode":"form","_meta":null,"message":"Allow Codex to inspect Google Chrome?","requestedSchema":{"type":"object","properties":{}}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .approvalRequest(
            CodexAppServerApprovalRequest(
                requestID: 0,
                kind: .mcpElicitation,
                title: "MCP server approval",
                detail: "Allow Codex to inspect Google Chrome?\nServer: example-server",
                acceptPayload: .mcpElicitationAccept,
                declinePayload: .mcpElicitationDecline
            )
        ))
    }

    @Test func appServerProtocolParsesPermissionsApprovalRequest() throws {
        let line = """
        {"id":46,"method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-3","startedAtMs":1779912000000,"cwd":"/Users/example","reason":"Need network access for this desktop action.","permissions":{"network":{"enabled":true},"fileSystem":null}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .approvalRequest(
            CodexAppServerApprovalRequest(
                requestID: 46,
                kind: .permissions,
                title: "Codex permissions approval",
                detail: "Need network access for this desktop action.\nPermissions: network",
                acceptPayload: .permissionsGranted(
                    .object([
                        "network": .object([
                            "enabled": .bool(true)
                        ])
                    ]),
                    scope: "turn"
                ),
                declinePayload: .permissionsDenied
            )
        ))
    }

    @Test func appServerProtocolParsesDynamicToolCallRequest() throws {
        let line = """
        {"id":47,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","namespace":"lorelei","tool":"foreground_app","arguments":{"bundleIdentifier":"com.google.Chrome","url":"https://chatgpt.com"}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .dynamicToolCall(
            CodexAppServerDynamicToolCallRequest(
                requestID: 47,
                callID: "call-1",
                namespace: "lorelei",
                tool: "foreground_app",
                arguments: .object([
                    "bundleIdentifier": .string("com.google.Chrome"),
                    "url": .string("https://chatgpt.com")
                ])
            )
        ))
    }

    @Test func appServerDynamicToolCallResponseUsesContentItems() throws {
        let response = CodexAppServerProtocol.dynamicToolCallResponse(
            id: 47,
            result: CodexAppServerDynamicToolCallResult(
                success: true,
                contentText: "Chrome is onscreen."
            )
        )
        let result = try #require(response["result"] as? [String: Any])
        let contentItems = try #require(result["contentItems"] as? [[String: Any]])
        let firstItem = try #require(contentItems.first)

        #expect(response["id"] as? Int == 47)
        #expect(result["success"] as? Bool == true)
        #expect(firstItem["type"] as? String == "inputText")
        #expect(firstItem["text"] as? String == "Chrome is onscreen.")
    }

    @Test func dynamicToolCallResponseEncodesImageContentItems() throws {
        let response = CodexAppServerProtocol.dynamicToolCallResponse(
            id: 48,
            result: CodexAppServerDynamicToolCallResult(
                success: true,
                contentItems: [
                    .text("done"),
                    .image(dataURL: "data:image/png;base64,AA==")
                ]
            )
        )
        let result = try #require(response["result"] as? [String: Any])
        let contentItems = try #require(result["contentItems"] as? [[String: Any]])

        #expect(contentItems.count == 2)
        #expect(contentItems[0]["type"] as? String == "inputText")
        #expect(contentItems[0]["text"] as? String == "done")
        #expect(contentItems[1]["type"] as? String == "inputImage")
        #expect(contentItems[1]["imageUrl"] as? String == "data:image/png;base64,AA==")
    }

    @Test func desktopToolSuiteRegistersSnapshotActionAndSetTextSpecs() throws {
        let specs = CodexAppServerDesktopToolSuite.toolSpecs()

        #expect(specs.map(\.namespace) == ["lorelei", "lorelei", "lorelei", "lorelei"])
        #expect(specs.map(\.name) == ["desktop_snapshot", "desktop_action", "set_text", "screenshot"])

        let snapshotSpec = try #require(specs.first { $0.name == "desktop_snapshot" })
        let actionSpec = try #require(specs.first { $0.name == "desktop_action" })
        let setTextSpec = try #require(specs.first { $0.name == "set_text" })
        let screenshotSpec = try #require(specs.first { $0.name == "screenshot" })

        guard case .object(let snapshotSchema) = snapshotSpec.inputSchema,
              case .object(let snapshotProperties) = snapshotSchema["properties"],
              case .object(let actionSchema) = actionSpec.inputSchema,
              case .object(let actionProperties) = actionSchema["properties"],
              case .object(let setTextSchema) = setTextSpec.inputSchema,
              case .object(let setTextProperties) = setTextSchema["properties"] else {
            Issue.record("Expected object schemas with properties.")
            return
        }

        #expect(snapshotSchema["type"] == .string("object"))
        #expect(snapshotProperties["app"] != nil)
        #expect(actionSchema["required"] == .array([.string("elementId"), .string("action")]))
        #expect(setTextSchema["required"] == .array([.string("elementId"), .string("text")]))
        #expect(screenshotSpec.description.contains("Fallback"))
        #expect(screenshotSpec.description.contains("lorelei.desktop_snapshot"))

        guard case .object(let actionProperty) = actionProperties["action"],
              case .array(let actionEnum) = actionProperty["enum"],
              case .object(let modeProperty) = setTextProperties["mode"],
              case .array(let modeEnum) = modeProperty["enum"] else {
            Issue.record("Expected enum schemas for action and mode.")
            return
        }

        #expect(actionProperties["elementId"] != nil)
        #expect(actionEnum == [.string("press"), .string("focus"), .string("raise")])
        #expect(setTextProperties["elementId"] != nil)
        #expect(setTextProperties["text"] != nil)
        #expect(modeEnum == [.string("replace"), .string("insert")])
    }

    @Test func desktopToolSuiteSnapshotReturnsTreeText() async throws {
        let executor = FakeDesktopActionExecutor()

        let defaultResult = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(tool: "desktop_snapshot", arguments: .object([:])),
            executor: executor
        )
        let appResult = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(tool: "desktop_snapshot", arguments: .object(["app": .string("TextEdit")])),
            executor: executor
        )

        #expect(defaultResult.success)
        #expect(defaultResult.contentItems == [.text("[e1] AXWindow \"Demo\" (0,0 100x100)")])
        #expect(appResult.success)
        #expect(appResult.contentItems == [.text("[e1] AXWindow \"Demo\" (0,0 100x100)")])
        #expect(executor.snapshotAppNames == [nil, "TextEdit"])
    }

    @Test func desktopToolSuiteActionResolvesElementAndReportsOutcome() async throws {
        let executor = FakeDesktopActionExecutor()

        let result = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(
                tool: "desktop_action",
                arguments: .object([
                    "elementId": .string("e2"),
                    "action": .string("press")
                ])
            ),
            executor: executor
        )

        #expect(result.success)
        #expect(result.contentItems == [.text("ok")])
        #expect(executor.performCalls.count == 1)
        #expect(executor.performCalls.first?.0 == .press)
        #expect(executor.performCalls.first?.1 == "e2")
    }

    @Test func desktopToolSuiteSetTextDefaultsToReplaceMode() async throws {
        let executor = FakeDesktopActionExecutor()

        let defaultResult = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(
                tool: "set_text",
                arguments: .object([
                    "elementId": .string("e2"),
                    "text": .string("Hello")
                ])
            ),
            executor: executor
        )
        let insertResult = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(
                tool: "set_text",
                arguments: .object([
                    "elementId": .string("e2"),
                    "text": .string(" there"),
                    "mode": .string("insert")
                ])
            ),
            executor: executor
        )

        #expect(defaultResult.success)
        #expect(insertResult.success)
        #expect(executor.setTextCalls.count == 2)
        #expect(executor.setTextCalls[0].0 == "Hello")
        #expect(executor.setTextCalls[0].1 == "e2")
        #expect(executor.setTextCalls[0].2 == .replace)
        #expect(executor.setTextCalls[1].0 == " there")
        #expect(executor.setTextCalls[1].1 == "e2")
        #expect(executor.setTextCalls[1].2 == .insert)
    }

    @Test func desktopToolSuiteReportsStaleElementAsToolFailure() async throws {
        let executor = FakeDesktopActionExecutor()
        executor.outcome = DesktopActionOutcome(
            success: false,
            message: DesktopActionError.staleElementID("e9").toolMessage
        )

        let result = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(
                tool: "desktop_action",
                arguments: .object([
                    "elementId": .string("e9"),
                    "action": .string("press")
                ])
            ),
            executor: executor
        )

        #expect(!result.success)
        #expect(result.contentItems == [.text("Unknown or stale elementId 'e9'. Call lorelei.desktop_snapshot again before acting.")])
    }

    @Test func desktopToolSuiteRejectsUnknownToolName() async throws {
        let executor = FakeDesktopActionExecutor()

        let result = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(tool: "desktop_spin", arguments: .object([:])),
            executor: executor
        )

        #expect(!result.success)
        #expect(textContent(result)?.contains("desktop_spin") == true)
    }

    @Test func desktopToolSuiteScreenshotReturnsImageItem() async throws {
        let executor = FakeDesktopActionExecutor()
        executor.screenshotResult = .success(Data([0x89, 0x50, 0x4e, 0x47]))

        let result = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(tool: "screenshot", arguments: .object([:])),
            executor: executor
        )

        #expect(result.success)
        #expect(result.contentItems.count == 1)
        guard case .image(let dataURL) = result.contentItems.first else {
            Issue.record("Expected screenshot to return an image content item.")
            return
        }
        #expect(dataURL.hasPrefix("data:image/png;base64,"))
    }

    @Test func desktopToolSuiteScreenshotFailureIsToolFailure() async throws {
        let executor = FakeDesktopActionExecutor()
        executor.screenshotResult = .failure(.captureFailed("no permission"))

        let result = await CodexAppServerDesktopToolSuite.handle(
            desktopToolRequest(tool: "screenshot", arguments: .object([:])),
            executor: executor
        )

        #expect(!result.success)
        #expect(textContent(result)?.contains("no permission") == true)
    }

    @Test func axSerializerAssignsDepthFirstIDsAndFormatsLines() throws {
        let root = DesktopUINode(
            role: "AXWindow",
            title: "Demo",
            value: nil,
            frame: CGRect(x: 0, y: 25, width: 1024, height: 743),
            isEnabled: true,
            isFocused: false,
            children: [
                DesktopUINode(
                    role: "AXGroup",
                    title: "Toolbar",
                    value: nil,
                    frame: nil,
                    isEnabled: true,
                    isFocused: false,
                    children: [
                        DesktopUINode(
                            role: "AXButton",
                            title: "Save",
                            value: nil,
                            frame: nil,
                            isEnabled: false,
                            isFocused: false,
                            children: []
                        )
                    ]
                ),
                DesktopUINode(
                    role: "AXTextArea",
                    title: nil,
                    value: "Hello",
                    frame: nil,
                    isEnabled: true,
                    isFocused: true,
                    children: []
                )
            ]
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(root, assigningIDsInto: &registry)

        #expect(result.text == """
        [e1] AXWindow "Demo" (0,25 1024x743)
          [e2] AXGroup "Toolbar"
            [e3] AXButton "Save" disabled
          [e4] AXTextArea value="Hello" focused
        """)
        #expect(result.elementCount == 4)
        #expect(registry == ["e1": 0, "e2": 1, "e3": 2, "e4": 3])
    }

    @Test func axSerializerPromotesChildrenOfBareStructuralNodes() throws {
        let root = DesktopUINode(
            role: "AXGroup",
            title: nil,
            value: nil,
            frame: nil,
            isEnabled: true,
            isFocused: false,
            children: [
                DesktopUINode(
                    role: "AXButton",
                    title: "First",
                    value: nil,
                    frame: nil,
                    isEnabled: true,
                    isFocused: false,
                    children: []
                ),
                DesktopUINode(
                    role: "AXSplitGroup",
                    title: nil,
                    value: nil,
                    frame: nil,
                    isEnabled: true,
                    isFocused: false,
                    children: [
                        DesktopUINode(
                            role: "AXButton",
                            title: "Second",
                            value: nil,
                            frame: nil,
                            isEnabled: true,
                            isFocused: false,
                            children: []
                        )
                    ]
                )
            ]
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(root, assigningIDsInto: &registry)

        #expect(result.text == """
        [e1] AXButton "First"
        [e2] AXButton "Second"
        """)
        #expect(result.elementCount == 2)
        #expect(registry == ["e1": 0, "e2": 1])
    }

    @Test func axSerializerTruncatesLongValuesAndElementCount() throws {
        let longValue = String(repeating: "a", count: 90)
        let children = (0..<401).map { index in
            DesktopUINode(
                role: "AXButton",
                title: "Button \(index)",
                value: nil,
                frame: nil,
                isEnabled: true,
                isFocused: false,
                children: []
            )
        }
        let root = DesktopUINode(
            role: "AXWindow",
            title: "Demo",
            value: longValue,
            frame: CGRect(x: 10.4, y: 20.6, width: 300.2, height: 200.8),
            isEnabled: true,
            isFocused: false,
            children: children
        )
        var registry: [String: Int] = [:]

        let result = AXDesktopActionExecutor.serialize(root, assigningIDsInto: &registry)
        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let expectedValue = String(repeating: "a", count: 79) + "…"

        #expect(lines.first == "[e1] AXWindow \"Demo\" value=\"\(expectedValue)\" (10,21 300x201)")
        #expect(lines.last == "… truncated (2 elements omitted)")
        #expect(result.elementCount == 400)
        #expect(registry.count == 400)
        #expect(registry["e1"] == 0)
        #expect(registry["e400"] == 399)
        #expect(registry["e401"] == nil)
    }

    @Test func axExecutorRejectsActionsWithUnknownElementID() async throws {
        let executor = AXDesktopActionExecutor(hasAccessibilityPermission: { true })

        let outcome = await executor.perform(.press, elementID: "e9")

        #expect(!outcome.success)
        #expect(outcome.message == DesktopActionError.staleElementID("e9").toolMessage)
    }

    @Test func axExecutorReportsMissingAccessibilityPermission() async throws {
        let executor = AXDesktopActionExecutor(hasAccessibilityPermission: { false })

        let result = await executor.snapshot(appName: nil)

        #expect(result == .failure(.accessibilityPermissionMissing))
    }

    @Test func appServerExecutorAnswersMcpElicitationApprovalWithZeroID() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":0,"method":"mcpServer/elicitation/request","params":{"threadId":"thread-1","turnId":"turn-1","serverName":"example-server","mode":"form","_meta":null,"message":"Allow Codex to use Google Chrome?","requestedSchema":{"type":"object","properties":{}}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Approved and done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .accept }
        )

        let result = await executor.runDesktopAction(prompt: "inspect Chrome", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(result.summary == "Approved and done")
        #expect(await transport.sentLines.contains { line in
            line.contains(#""id":0"#)
                && line.contains(#""action":"accept""#)
                && line.contains(#""content":{}"#)
        })
    }

    @Test func appServerExecutorAnswersPermissionsApproval() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":46,"method":"item/permissions/requestApproval","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-3","startedAtMs":1779912000000,"cwd":"/Users/example","reason":"Need network access.","permissions":{"network":{"enabled":true},"fileSystem":null}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Approved permissions and done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .accept }
        )

        let result = await executor.runDesktopAction(prompt: "open a URL", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(result.summary == "Approved permissions and done")

        let responseLine = try #require(await transport.sentLines.first { line in
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return root["id"] as? Int == 46
        })
        let response = try #require(try JSONSerialization.jsonObject(with: Data(responseLine.utf8)) as? [String: Any])
        let responseResult = try #require(response["result"] as? [String: Any])
        let permissions = try #require(responseResult["permissions"] as? [String: Any])
        let network = try #require(permissions["network"] as? [String: Any])

        #expect(network["enabled"] as? Bool == true)
        #expect(permissions["fileSystem"] == nil)
        #expect(responseResult["scope"] as? String == "turn")
    }

    @Test func appServerExecutorReportsFailedMcpToolCallEvenWhenTurnCompletes() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"item-1","type":"mcpToolCall","status":"failed","server":"example-server","tool":"get_app_state","result":{"content":[{"type":"text","text":"Example server error"}],"isError":true}}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"I could not read the Google Chrome window."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .accept }
        )

        let result = await executor.runDesktopAction(prompt: "inspect Chrome", cwd: "/Users/example")

        #expect(result.status == .failed)
        #expect(result.summary == "I could not read the Google Chrome window.")
    }

    @Test func appServerProtocolParsesGeneratedTurnCompletedShape() throws {
        let line = """
        {"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"itemsView":"all","status":"failed","error":null,"startedAt":null,"completedAt":null,"durationMs":null}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .turnCompleted(status: "failed"))
    }

    @Test func appServerProtocolParsesWaitingOnApprovalStatus() throws {
        let line = """
        {"method":"thread/status/changed","params":{"threadId":"thread-1","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .threadWaitingOnApproval(true))
    }

    @Test func appServerProtocolFailsFastForUnsupportedServerRequests() throws {
        let line = """
        {"id":45,"method":"item/unknown/request","params":{"threadId":"thread-1","turnId":"turn-1"}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .unsupportedServerRequest(requestID: 45, method: "item/unknown/request"))
    }

    @Test func appServerExecutorStartsThreadAndTurn() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "open TextEdit", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(result.summary == "Done")
        #expect(await transport.sentMethods == ["initialize", "initialized", "thread/start", "turn/start"])
    }

    @Test func appServerSessionReusesTransportAcrossTurns() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"First"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Second"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let factoryCallCount = AsyncCounter()
        let executor = CodexAppServerExecutor(
            makeTransport: {
                await factoryCallCount.increment()
                return transport
            },
            approvalHandler: { _ in .cancel }
        )

        let first = await executor.runDesktopAction(prompt: "first", cwd: "/Users/example")
        let didTerminateAfterFirstTurn = await transport.didTerminate
        let second = await executor.runDesktopAction(prompt: "second", cwd: "/Users/example")

        #expect(first.status == .succeeded)
        #expect(first.summary == "First")
        #expect(second.status == .succeeded)
        #expect(second.summary == "Second")
        #expect(await factoryCallCount.value == 1)
        #expect(!didTerminateAfterFirstTurn)
        let sentMessages = try await transport.sentJSONMessages()
        let turnStarts = sentMessages.filter { $0["method"] as? String == "turn/start" }
        #expect(turnStarts.map { $0["id"] as? Int } == [3, 4])
    }

    @Test func appServerSessionRespawnsWhenCwdChanges() async throws {
        let firstTransport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"First"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let secondTransport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-2"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Second"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let factory = AppServerTransportFactoryRecorder(transports: [firstTransport, secondTransport])
        let executor = CodexAppServerExecutor(
            makeTransport: { try await factory.next() },
            approvalHandler: { _ in .cancel }
        )

        _ = await executor.runDesktopAction(prompt: "first", cwd: "/Users/example/one")
        _ = await executor.runDesktopAction(prompt: "second", cwd: "/Users/example/two")

        #expect(await factory.callCount == 2)
        #expect(await firstTransport.didTerminate)
        let sentMessages = try await secondTransport.sentJSONMessages()
        let threadStart = try #require(sentMessages.first { $0["method"] as? String == "thread/start" })
        let params = try #require(threadStart["params"] as? [String: Any])
        #expect(params["cwd"] as? String == "/Users/example/two")
    }

    @Test func appServerSessionRetriesOnceOnDeadTransport() async throws {
        let deadTransport = ThrowingSendCodexAppServerTransport()
        let healthyTransport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-2"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Recovered"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let factory = AppServerTransportFactoryRecorder(transports: [deadTransport, healthyTransport])
        let executor = CodexAppServerExecutor(
            makeTransport: { try await factory.next() },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "recover", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(result.summary == "Recovered")
        #expect(await factory.callCount == 2)
        #expect(await deadTransport.didTerminate)
    }

    @Test func appServerStopInvalidatesSession() async throws {
        let firstTransport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        ])
        let secondTransport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-2"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Fresh"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let factory = AppServerTransportFactoryRecorder(transports: [firstTransport, secondTransport])
        let executor = CodexAppServerExecutor(
            // 0.3s, not a knife-edge 0.01s: the timer must lose the race against
            // consuming the scripted session/turn lines, or the turn never starts
            // and the timeout-shape contract cannot hold.
            turnTimeoutSeconds: 0.3,
            makeTransport: { try await factory.next() },
            approvalHandler: { _ in .cancel }
        )

        let stopped = await executor.runDesktopAction(prompt: "stop", cwd: "/Users/example")
        let fresh = await executor.runDesktopAction(prompt: "fresh", cwd: "/Users/example")

        #expect(stopped.status == .failed)
        #expect(stopped.summary.contains("Codex App Server command timed out."))
        #expect(fresh.status == .succeeded)
        #expect(fresh.summary == "Fresh")
        #expect(await factory.callCount == 2)
    }

    @Test func appServerExecutorAnswersToolUserInputApproval() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":44,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow control?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow."},{"label":"Decline","description":"Stop."}]}]}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Approved and done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            approvalHandler: { _ in .accept }
        )

        let result = await executor.runDesktopAction(prompt: "click submit", cwd: "/Users/example")

        #expect(result.status == .succeeded)
        #expect(result.summary == "Approved and done")
        #expect(await transport.sentLines.contains { $0.contains(#""id":44"#) && $0.contains(#""Accept"#) })
    }

    @Test func appServerExecutorTimesOutSilentServer() async throws {
        let transport = HangingCodexAppServerTransport()
        let executor = CodexAppServerExecutor(
            // 0.3s, not a knife-edge 0.01s: the timer must lose the race against
            // consuming the scripted session/turn lines, or the turn never starts
            // and the timeout-shape contract cannot hold.
            turnTimeoutSeconds: 0.3,
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "open TextEdit", cwd: "/Users/example")

        #expect(result.summary.contains("Codex App Server command timed out."))
        #expect(result.status == .failed)
        #expect(await transport.didTerminate)
    }

    @Test func appServerExecutorIncludesProtocolTraceWhenTimeoutHappensAfterThreadStart() async throws {
        let transport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        ])
        let executor = CodexAppServerExecutor(
            // 0.3s, not a knife-edge 0.01s: the timer must lose the race against
            // consuming the scripted session/turn lines, or the turn never starts
            // and the timeout-shape contract cannot hold.
            turnTimeoutSeconds: 0.3,
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "open Chrome", cwd: "/Users/example")

        #expect(result.status == .failed)
        #expect(result.summary.contains("Codex App Server command timed out."))
        #expect(result.summary.contains("Trace:"))
        #expect(result.summary.contains("outbound initialize#1"))
        #expect(result.summary.contains("inbound threadStarted#2:thread-1"))
        #expect(result.summary.contains("outbound turn/start#3"))
    }

    @Test func appServerExecutorReportsTimeoutWhenTransportReadThrowsAfterTermination() async throws {
        let transport = ThrowingAfterTerminateCodexAppServerTransport()
        let executor = CodexAppServerExecutor(
            // 0.3s, not a knife-edge 0.01s: the timer must lose the race against
            // consuming the scripted session/turn lines, or the turn never starts
            // and the timeout-shape contract cannot hold.
            turnTimeoutSeconds: 0.3,
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "open TextEdit", cwd: "/Users/example")

        #expect(result.summary.contains("Codex App Server command timed out."))
        #expect(result.status == .failed)
        #expect(await transport.didTerminate)
    }

    @Test func appServerExecutorReportsUndeliveredApprovalRequestOnTimeout() async throws {
        let transport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"thread/status/changed","params":{"threadId":"thread-1","status":{"type":"active","activeFlags":["waitingOnApproval"]}}}"#
        ])
        // 0.3s (not a knife-edge 0.01s): the scripted lines - including the
        // waitingOnApproval status the hint depends on - must be consumed
        // before the timer fires now that the timeout also covers session
        // establishment.
        let executor = CodexAppServerExecutor(
            turnTimeoutSeconds: 0.3,
            makeTransport: { transport },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "inspect TextEdit", cwd: "/Users/example")

        #expect(result.summary.contains("Codex App Server is waiting for approval, but no approval request was delivered."))
        #expect(result.status == .failed)
        #expect(await transport.didTerminate)
    }

    @Test func appServerExecutorRegistersAndAnswersDynamicToolCalls() async throws {
        let dynamicTool = CodexAppServerDynamicToolSpec(
            name: "foreground_app",
            namespace: "lorelei",
            description: "Bring an app onscreen.",
            inputSchema: .object(["type": .string("object")])
        )
        let dynamicToolRequestRecorder = StringRecorder()
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":47,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","namespace":"lorelei","tool":"foreground_app","arguments":{"bundleIdentifier":"com.google.Chrome"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Foregrounded and done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            dynamicToolSpecsResolver: { [dynamicTool] },
            dynamicToolHandler: { request in
                dynamicToolRequestRecorder.record(request.tool)
                return CodexAppServerDynamicToolCallResult(
                    success: true,
                    contentText: "Google Chrome is onscreen."
                )
            },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "foreground Chrome", cwd: "/Users/example")

        #expect(result.summary == "Foregrounded and done")
        #expect(dynamicToolRequestRecorder.values == ["foreground_app"])
        let sentMessages = try await transport.sentLines.map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let threadStart = try #require(sentMessages.first { $0["method"] as? String == "thread/start" })
        let threadStartParams = try #require(threadStart["params"] as? [String: Any])
        let dynamicTools = try #require(threadStartParams["dynamicTools"] as? [[String: Any]])
        let firstDynamicTool = try #require(dynamicTools.first)
        #expect(firstDynamicTool["name"] as? String == "foreground_app")

        let dynamicToolResponse = try #require(sentMessages.first { $0["id"] as? Int == 47 })
        let responseResult = try #require(dynamicToolResponse["result"] as? [String: Any])
        #expect(responseResult["success"] as? Bool == true)
        #expect((responseResult["contentItems"] as? [[String: Any]])?.first?["text"] as? String == "Google Chrome is onscreen.")
    }

    @Test func appServerExecutorRecordsProtocolAndDynamicToolTraceEvents() async throws {
        let dynamicTool = CodexAppServerDynamicToolSpec(
            name: "foreground_app",
            namespace: "lorelei",
            description: "Bring an app onscreen.",
            inputSchema: .object(["type": .string("object")])
        )
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":47,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","namespace":"lorelei","tool":"foreground_app","arguments":{"bundleIdentifier":"com.google.Chrome"}}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let recorder = AppServerTraceRecorder()
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            dynamicToolSpecsResolver: { [dynamicTool] },
            dynamicToolHandler: { _ in
                CodexAppServerDynamicToolCallResult(
                    success: true,
                    contentText: "Google Chrome is onscreen."
                )
            },
            traceHandler: { event in
                recorder.record(event)
            },
            approvalHandler: { _ in .cancel }
        )

        _ = await executor.runDesktopAction(prompt: "foreground Chrome", cwd: "/Users/example")

        let eventLines = Set(recorder.eventLines)
        #expect(eventLines.contains("outbound initialize#1"))
        #expect(eventLines.contains("inbound response#1"))
        #expect(eventLines.contains("inbound dynamicToolCall#47:lorelei.foreground_app"))
        #expect(eventLines.contains("dynamicToolStarted 47:lorelei.foreground_app"))
        #expect(eventLines.contains("dynamicToolCompleted 47:lorelei.foreground_app:success=true"))
        #expect(eventLines.contains("outbound response#47"))
    }

    @Test func executorReportsProgressForDeltasAndToolCalls() async throws {
        let dynamicTool = CodexAppServerDynamicToolSpec(
            name: "desktop_snapshot",
            namespace: "lorelei",
            description: "Read the desktop.",
            inputSchema: .object(["type": .string("object")])
        )
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"id":47,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"call-1","namespace":"lorelei","tool":"desktop_snapshot","arguments":{}}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let recorder = AppServerProgressRecorder()
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            dynamicToolSpecsResolver: { [dynamicTool] },
            dynamicToolHandler: { _ in
                CodexAppServerDynamicToolCallResult(success: true, contentText: "snapshot")
            },
            progressHandler: { progress in
                recorder.record(progress)
            },
            approvalHandler: { _ in .cancel }
        )

        _ = await executor.runDesktopAction(prompt: "inspect desktop", cwd: "/Users/example")

        #expect(recorder.progress == [
            .agentMessageDelta("Hel"),
            .agentMessageDelta("lo"),
            .toolCallStarted(name: "lorelei.desktop_snapshot"),
            .toolCallCompleted(name: "lorelei.desktop_snapshot", success: true)
        ])
    }

    @Test func companionManagerTracksRunStatusThroughVoiceTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerRunStatusVoiceTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerRunStatusVoiceTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        // Record every transition instead of polling: the scripted turn can
        // finish faster than any polling interval, so transient states like
        // .working would otherwise be missed nondeterministically.
        let recorder = RunStatusRecorder()
        let statusCancellable = manager.$runStatus.sink { recorder.record($0) }
        defer { statusCancellable.cancel() }

        manager.simulateShortcutTransitionForTesting(.pressed)
        #expect(manager.runStatus == .listening)

        manager.simulateShortcutTransitionForTesting(.released)
        #expect(manager.runStatus == .transcribing)

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<200 {
            if recorder.statuses.contains(.finished(success: true)) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let statuses = recorder.statuses
        #expect(statuses.contains(.finished(success: true)))
        #expect(isOrderedSubsequence(
            [.listening, .transcribing, .working("Thinking…"), .finished(success: true)],
            of: statuses
        ))
        #expect(manager.streamText == "Hello")
    }

    @Test func companionManagerPlaysCuesThroughVoiceTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerAudioVoiceTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerAudioVoiceTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.simulateShortcutTransitionForTesting(.pressed)
        manager.simulateShortcutTransitionForTesting(.released)
        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<200 {
            if audioFeedback.events.contains(where: { $0.cue == .runSucceeded }) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(audioFeedback.events.map(\.cue) == [.listeningStarted, .listeningEnded, .runSucceeded])
        #expect(audioFeedback.events.last?.spokenSummary == "Hello")
    }

    private func isOrderedSubsequence(
        _ expected: [LoreleiRunStatus],
        of recorded: [LoreleiRunStatus]
    ) -> Bool {
        var remaining = expected[...]
        for status in recorded {
            if status == remaining.first {
                remaining = remaining.dropFirst()
            }
        }
        return remaining.isEmpty
    }

    @Test func companionManagerShowsNeedsApprovalStatusDuringApprovalBridge() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerApprovalRunStatusTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerApprovalRunStatusTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":44,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow control?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow."},{"label":"Decline","description":"Stop."}]}]}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(5)
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .needsApproval("Computer Use"))

        manager.acceptPendingApproval()
        for _ in 0..<20 {
            if case .working = manager.runStatus {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .working("Thinking…"))
        await transport.enqueue(#"{"method":"item/agentMessage/delta","params":{"delta":"Approved"}}"#)
        await transport.enqueue(#"{"method":"turn/completed","params":{"status":"completed"}}"#)
    }

    @Test func companionManagerStopTerminatesLiveTransport() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerStopRunTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerStopRunTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        let recorder = RunStatusRecorder()
        let statusCancellable = manager.$runStatus.sink { recorder.record($0) }
        defer { statusCancellable.cancel() }

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if recorder.statuses.contains(.working("Thinking…")) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.stopCurrentRun()
        for _ in 0..<20 {
            if await transport.didTerminate {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await transport.didTerminate)
        #expect(manager.latestResultSummary == "Stopped.")
        #expect(manager.runStatus == .finished(success: false))
    }

    @Test func companionManagerPlaysFailureCueOnStop() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerAudioStopTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerAudioStopTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if manager.runStatus == .working("Thinking…") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.stopCurrentRun()

        #expect(audioFeedback.events.contains(BuddyAudioFeedbackRecorder.Event(cue: .runFailed, spokenSummary: "Stopped.")))
    }

    @Test func companionManagerPlaysApprovalCue() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerAudioApprovalTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerAudioApprovalTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":44,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow control?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow."},{"label":"Decline","description":"Stop."}]}]}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(audioFeedback.events.filter { $0.cue == .approvalRequested }.count == 1)
        #expect(audioFeedback.events.first { $0.cue == .approvalRequested }?.spokenSummary == nil)
    }

    @Test func companionManagerStopWithoutRunIsNoOp() {
        let defaults = UserDefaults(suiteName: "CompanionManagerStopWithoutRunTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerStopWithoutRunTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.stopCurrentRun()

        #expect(manager.runStatus == .idle)
        #expect(manager.latestResultSummary == nil)
        #expect(manager.pendingApprovalTitle == nil)
    }

    private func makeTemporaryGitRepository() throws -> URL {
        let repositoryURL = try makeTemporaryDirectory()
        try runGitTestCommand(["init"], in: repositoryURL)
        return repositoryURL
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    private func runGitTestCommand(_ arguments: [String], in directoryURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directoryURL
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func isTimedOut(_ reason: WorkspaceProcessExecution.Reason) -> Bool {
        if case .timedOut = reason {
            return true
        }
        return false
    }

    private func foregroundToolRequest(
        arguments: CodexAppServerJSONValue
    ) -> CodexAppServerDynamicToolCallRequest {
        CodexAppServerDynamicToolCallRequest(
            requestID: 47,
            callID: "call-1",
            namespace: "lorelei",
            tool: "foreground_app",
            arguments: arguments
        )
    }

    private func desktopToolRequest(
        tool: String,
        arguments: CodexAppServerJSONValue,
        namespace: String? = "lorelei"
    ) -> CodexAppServerDynamicToolCallRequest {
        CodexAppServerDynamicToolCallRequest(
            requestID: 47,
            callID: "call-1",
            namespace: namespace,
            tool: tool,
            arguments: arguments
        )
    }

    private func textContent(_ result: CodexAppServerDynamicToolCallResult) -> String? {
        guard result.contentItems.count == 1,
              case .text(let text) = result.contentItems[0] else {
            return nil
        }
        return text
    }
}

@MainActor
private final class FakeDesktopActionExecutor: DesktopActionExecuting {
    var snapshotResult: Result<DesktopSnapshotResult, DesktopActionError> =
        .success(DesktopSnapshotResult(text: "[e1] AXWindow \"Demo\" (0,0 100x100)", elementCount: 1))
    var performCalls: [(DesktopElementAction, String)] = []
    var setTextCalls: [(String, String, DesktopSetTextMode)] = []
    var outcome = DesktopActionOutcome(success: true, message: "ok")
    var screenshotResult: Result<Data, DesktopActionError> = .success(Data([0x89, 0x50]))
    var snapshotAppNames: [String?] = []

    func snapshot(appName: String?) async -> Result<DesktopSnapshotResult, DesktopActionError> {
        snapshotAppNames.append(appName)
        return snapshotResult
    }

    func perform(_ action: DesktopElementAction, elementID: String) async -> DesktopActionOutcome {
        performCalls.append((action, elementID))
        return outcome
    }

    func setText(
        _ text: String,
        elementID: String,
        mode: DesktopSetTextMode
    ) async -> DesktopActionOutcome {
        setTextCalls.append((text, elementID, mode))
        return outcome
    }

    func screenshot() async -> Result<Data, DesktopActionError> {
        screenshotResult
    }
}

@MainActor
private final class CodexCommandRecorder {
    private let finalMessage: String
    private(set) var executableURL: URL?
    private(set) var arguments: [String]?
    private(set) var currentDirectoryURL: URL?

    init(finalMessage: String) {
        self.finalMessage = finalMessage
    }

    var outputLastMessagePath: String? {
        guard let arguments,
              let optionIndex = arguments.firstIndex(of: "--output-last-message"),
              arguments.indices.contains(optionIndex + 1) else {
            return nil
        }
        return arguments[optionIndex + 1]
    }

    func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeoutSeconds: TimeInterval,
        prelaunchDelay: TimeInterval,
        onLaunch: (@Sendable () -> Void)?
    ) async -> WorkspaceProcessExecution {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryURL = currentDirectoryURL

        if let outputPath = outputLastMessagePath {
            try? finalMessage.write(toFile: outputPath, atomically: true, encoding: .utf8)
        }

        return WorkspaceProcessExecution(reason: .exited(0), stdout: "", stderr: "")
    }
}

private final class LaunchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        let value = count
        lock.unlock()
        return value
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private actor AsyncCounter {
    private var count = 0

    var value: Int {
        count
    }

    func increment() {
        count += 1
    }
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(_ value: String) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }
}

private actor FakeCodexAppServerTransport: CodexAppServerTransporting {
    private var lines: [String]
    private var recordedSentLines: [String] = []
    private var terminated = false

    init(lines: [String]) {
        self.lines = lines
    }

    var sentLines: [String] {
        recordedSentLines
    }

    var sentMethods: [String] {
        sentLines.compactMap { line in
            guard let data = line.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = root["method"] as? String else {
                return nil
            }
            return method
        }
    }

    var didTerminate: Bool {
        terminated
    }

    func sentJSONMessages() throws -> [[String: Any]] {
        try recordedSentLines.map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    func send(line: String) async throws {
        recordedSentLines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func nextLine() async throws -> String? {
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }

    func terminate() async {
        terminated = true
    }
}

private actor AppServerTransportFactoryRecorder {
    private var transports: [CodexAppServerTransporting]
    private var calls = 0

    init(transports: [CodexAppServerTransporting]) {
        self.transports = transports
    }

    var callCount: Int {
        calls
    }

    func next() throws -> CodexAppServerTransporting {
        calls += 1
        guard !transports.isEmpty else {
            throw CodexAppServerTestError.missingTransport
        }
        return transports.removeFirst()
    }
}

private actor ThrowingSendCodexAppServerTransport: CodexAppServerTransporting {
    private var terminated = false

    var didTerminate: Bool {
        terminated
    }

    func send(line: String) async throws {
        throw CodexAppServerTestError.sendFailed
    }

    func nextLine() async throws -> String? {
        nil
    }

    func terminate() async {
        terminated = true
    }
}

private enum CodexAppServerTestError: Error {
    case missingTransport
    case sendFailed
}

private actor HangingCodexAppServerTransport: CodexAppServerTransporting {
    private var terminated = false

    var didTerminate: Bool {
        terminated
    }

    func send(line: String) async throws {}

    func nextLine() async throws -> String? {
        while !terminated {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func terminate() async {
        terminated = true
    }
}

private actor HangingAfterLinesCodexAppServerTransport: CodexAppServerTransporting {
    private var lines: [String]
    private var terminated = false

    init(lines: [String]) {
        self.lines = lines
    }

    var didTerminate: Bool {
        terminated
    }

    func send(line: String) async throws {}

    func nextLine() async throws -> String? {
        if !lines.isEmpty {
            return lines.removeFirst()
        }

        while !terminated {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func terminate() async {
        terminated = true
    }
}

private actor ThrowingAfterTerminateCodexAppServerTransport: CodexAppServerTransporting {
    private var terminated = false

    var didTerminate: Bool {
        terminated
    }

    func send(line: String) async throws {}

    func nextLine() async throws -> String? {
        while !terminated {
            try? await Task.sleep(for: .milliseconds(5))
        }
        throw CodexAppServerProtocolError.invalidJSON
    }

    func terminate() async {
        terminated = true
    }
}

private final class AppServerTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [CodexAppServerTraceEvent] = []

    var events: [CodexAppServerTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    var eventLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents.map { event in event.logLine }
    }

    func record(_ event: CodexAppServerTraceEvent) {
        lock.lock()
        defer { lock.unlock() }
        recordedEvents.append(event)
    }
}

private final class AppServerProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedProgress: [CodexAppServerTurnProgress] = []

    var progress: [CodexAppServerTurnProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recordedProgress
    }

    func record(_ progress: CodexAppServerTurnProgress) {
        lock.lock()
        defer { lock.unlock() }
        recordedProgress.append(progress)
    }
}

private final class RunStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LoreleiRunStatus] = []

    var statuses: [LoreleiRunStatus] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ status: LoreleiRunStatus) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(status)
    }
}

private actor BlockingCodexAppServerTransport: CodexAppServerTransporting {
    private var lines: [String]
    private var recordedSentLines: [String] = []
    private var terminated = false

    init(lines: [String]) {
        self.lines = lines
    }

    var sentLines: [String] {
        recordedSentLines
    }

    var didTerminate: Bool {
        terminated
    }

    func enqueue(_ line: String) {
        lines.append(line)
    }

    func send(line: String) async throws {
        recordedSentLines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func nextLine() async throws -> String? {
        while lines.isEmpty && !terminated {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard !terminated else { return nil }
        return lines.removeFirst()
    }

    func terminate() async {
        terminated = true
    }
}

@MainActor
private final class SilentSpeechOutput: SpeechOutputing {
    func speak(_ text: String) {}
}

@MainActor
private final class BuddyAudioFeedbackRecorder: BuddyAudioFeedbacking {
    struct Event: Equatable {
        let cue: BuddyAudioCue
        let spokenSummary: String?
    }

    private(set) var events: [Event] = []

    func play(_ cue: BuddyAudioCue, spokenSummary: String?) {
        events.append(Event(cue: cue, spokenSummary: spokenSummary))
    }
}

@MainActor
private final class AppServerDesktopActionRecorder {
    private let result: WorkspaceCommandResult
    var onRun: ((String, String) -> Void)?
    private(set) var calls: [(prompt: String, cwd: String)] = []

    init(result: WorkspaceCommandResult) {
        self.result = result
    }

    func run(_ prompt: String, _ cwd: String) async -> WorkspaceCommandResult {
        calls.append((prompt, cwd))
        onRun?(prompt, cwd)
        return result
    }
}

@MainActor
private final class OverlayWindowManagerRecorder: OverlayWindowManaging {
    var hasShownOverlayBefore = false
    private(set) var events: [String] = []
    private var isShowing = false

    func showOverlay(onScreens screens: [NSScreen], companionManager: CompanionManager) {
        events.append("show")
        isShowing = true
    }

    func hideOverlay() {
        events.append("hide")
        isShowing = false
    }

    func fadeOutAndHideOverlay(duration: TimeInterval) {
        events.append("fadeOut")
        isShowing = false
    }

    func isShowingOverlay() -> Bool {
        isShowing
    }
}

@MainActor
private final class ForegroundEnvironmentRecorder {
    private var onscreenResults: [Bool]
    private(set) var events: [String] = []
    private(set) var spaceDirections: [CodexAppServerDesktopSpaceDirection] = []

    init(onscreenResults: [Bool]) {
        self.onscreenResults = onscreenResults
    }

    func environment() -> CodexAppServerDesktopForegroundEnvironment {
        CodexAppServerDesktopForegroundEnvironment(
            openURLInApp: { [weak self] url, appName, bundleIdentifier in
                self?.events.append("open:\(url.absoluteString):\(appName ?? "nil"):\(bundleIdentifier ?? "nil")")
                return true
            },
            activateApp: { [weak self] appName, bundleIdentifier in
                self?.events.append("activate:\(appName ?? "nil"):\(bundleIdentifier ?? "nil")")
                return true
            },
            appHasOnscreenWindow: { [weak self] appName, bundleIdentifier in
                self?.events.append("check:\(appName ?? "nil"):\(bundleIdentifier ?? "nil")")
                guard let self, !self.onscreenResults.isEmpty else { return false }
                return self.onscreenResults.removeFirst()
            },
            switchSpace: { [weak self] direction in
                self?.spaceDirections.append(direction)
                self?.events.append("switch:\(direction.rawValue)")
            },
            sleep: { _ in }
        )
    }
}
