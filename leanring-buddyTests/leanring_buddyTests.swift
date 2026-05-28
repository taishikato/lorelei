//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import AppKit
import Foundation
import CoreGraphics
@testable import Lorelei

@MainActor
struct leanring_buddyTests {

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

    @Test func openAITranscriptionIsNotDefaultWhenConfigured() async throws {
        let shouldUseOpenAI = BuddyTranscriptionProviderFactory.shouldUseOpenAIProvider(
            preferredProviderRawValue: nil,
            openAIIsConfigured: true
        )

        #expect(!shouldUseOpenAI)
    }

    @Test func openAITranscriptionCanBeExplicitlySelectedWhenConfigured() async throws {
        let shouldUseOpenAI = BuddyTranscriptionProviderFactory.shouldUseOpenAIProvider(
            preferredProviderRawValue: "openai",
            openAIIsConfigured: true
        )

        #expect(shouldUseOpenAI)
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

    @Test func companionManagerRunsDesktopActionThroughInjectedAppServerRunnerAfterConfirmation() async throws {
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
            if manager.pendingConfirmationTitle == "Run Codex desktop action?" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.pendingConfirmationTitle == "Run Codex desktop action?")

        manager.confirmPendingCommand()
        for _ in 0..<20 {
            if recorder.calls.count == 1,
               manager.latestResultSummary == "Opened through App Server." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(recorder.calls.count == 1)
        let call = try #require(recorder.calls.first)
        #expect(call.prompt.contains("Codex App Server"))
        #expect(call.prompt.contains("https://chatgpt.com"))
        #expect(call.prompt.contains("Google Chrome"))
        #expect(call.prompt.contains("Chrome plugin"))
        #expect(call.prompt.contains("Do not use Computer Use"))
        #expect(call.prompt.contains("Do not call lorelei.foreground_app"))
        #expect(!call.prompt.contains("Before Computer Use inspects a desktop app, call lorelei.foreground_app"))
        #expect(!call.prompt.contains("call lorelei.foreground_app before visual inspection"))
        #expect(call.cwd == FileManager.default.homeDirectoryForCurrentUser.path)
        #expect(manager.latestResultSummary == "Opened through App Server.")
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
            if manager.pendingConfirmationTitle == "Run Codex desktop action?" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.pendingConfirmationTitle == "Run Codex desktop action?")

        manager.confirmPendingCommand()
        for _ in 0..<20 {
            if recorder.calls.count == 1,
               manager.latestResultSummary == "Typed through App Server." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let call = try #require(recorder.calls.first)
        #expect(call.prompt.contains("Codex App Server"))
        #expect(call.prompt.contains("Computer Use plugin"))
        #expect(call.prompt.contains("Before Computer Use inspects a desktop app, call lorelei.foreground_app"))
        #expect(call.prompt.contains("use computer use to open TextEdit and type hello"))
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
        manager.setClickyCursorEnabled(true)

        manager.handleFinalTranscriptForTesting("Open chatgpt.com in a new tab on chrome browser")
        for _ in 0..<20 {
            if manager.pendingConfirmationTitle == "Run Codex desktop action?" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.confirmPendingCommand()
        for _ in 0..<20 {
            if manager.latestResultSummary == "Desktop action finished." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(overlayWindowManager.events == ["show", "hide", "show"])
        #expect(manager.isOverlayVisible)
        #expect(manager.latestResultSummary == "Desktop action finished.")
    }

    @Test func companionManagerRecordsDebugLogForConfirmedDesktopAction() async throws {
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
            if manager.pendingConfirmationTitle == "Run Codex desktop action?" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.confirmPendingCommand()
        for _ in 0..<20 {
            if manager.latestResultSummary == "Opened through App Server." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.debugLogText.contains("Transcript: Open chatgpt.com in a new tab on chrome browser"))
        #expect(manager.debugLogText.contains("Route: Codex desktop action"))
        #expect(manager.debugLogText.contains("Waiting for confirmation: Run Codex desktop action?"))
        #expect(manager.debugLogText.contains("Confirmed: Codex desktop action"))
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

    @Test func routerMapsChromeURLRequestToAppServerDesktopAction() async throws {
        let router = LoreleiCommandRouter()

        let action = router.route("Open chatgpt.com in a new tab on chrome browser")

        guard case .codexDesktopAction(let prompt) = action else {
            Issue.record("Expected App Server desktop action, got \(action)")
            return
        }
        #expect(prompt.contains("https://chatgpt.com"))
        #expect(prompt.contains("Google Chrome"))
        #expect(prompt.contains("Chrome plugin"))
        #expect(prompt.contains("Do not use Computer Use"))
        #expect(prompt.contains("Do not call lorelei.foreground_app"))
        #expect(prompt.contains("Do not search"))
    }

    @Test func routerMapsChromeTypingRequestToDesktopActionWithoutReadOnlyCodex() async throws {
        let router = LoreleiCommandRouter()
        let transcript = "No open ChatGPT in chrome browser and then type in what should I do around Tokyo station"

        #expect(router.route(transcript) == .codexDesktopAction(transcript))
    }

    @Test func routerDoesNotUseURLOnlyPromptWhenChromeRequestNeedsTyping() async throws {
        let router = LoreleiCommandRouter()
        let transcript = "Open chatgpt.com in chrome browser and then type in what should I do around Tokyo station"

        #expect(router.route(transcript) == .codexDesktopAction(transcript))
    }

    @Test func routerMapsExplicitComputerUsePhraseToCodexDesktopAction() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("use computer use to open System Settings") == .codexDesktopAction("use computer use to open System Settings"))
    }

    @Test func confirmationPolicyAllowsOnlySafeLocalAndScopedScreenCommandsImmediately() async throws {
        #expect(!LoreleiConfirmationPolicy.requiresConfirmation(for: .gitStatus))
        #expect(!LoreleiConfirmationPolicy.requiresConfirmation(for: .gitDiff))
        #expect(!LoreleiConfirmationPolicy.requiresConfirmation(for: .runTests))
        #expect(!LoreleiConfirmationPolicy.requiresConfirmation(for: .codexScreen("look at my screen")))
    }

    @Test func confirmationPolicyRequiresPanelConfirmationForBroadCodexWriteAndDesktopActionCommands() async throws {
        #expect(LoreleiConfirmationPolicy.requiresConfirmation(for: .codexReadOnly("explain this")))
        #expect(LoreleiConfirmationPolicy.requiresConfirmation(for: .codexWorkspaceWrite("fix the test")))
        #expect(LoreleiConfirmationPolicy.requiresConfirmation(for: .codexDesktopAction("click submit")))
    }

    @Test func workspaceWritePromptIncludesNoCommitGuard() async throws {
        let prompt = CodexPromptBuilder.workspaceWritePrompt(for: "fix the test")

        #expect(prompt.contains("Do not commit changes."))
        #expect(prompt.contains("fix the test"))
    }

    @Test func desktopActionPromptRequiresAppServerControlPlaneAndScopedDesktopActions() async throws {
        let prompt = CodexPromptBuilder.desktopActionPrompt(for: "open TextEdit and type hello")

        #expect(prompt.contains("Codex App Server"))
        #expect(prompt.contains("Chrome plugin"))
        #expect(prompt.contains("Computer Use plugin"))
        #expect(prompt.contains("visual UI inspection"))
        #expect(prompt.contains("lorelei.foreground_app"))
        #expect(prompt.contains("Do not rely on caller-side local shortcuts."))
        #expect(prompt.contains("Do not commit changes."))
        #expect(!prompt.contains("non-interactive codex exec"))
        #expect(prompt.contains("open TextEdit and type hello"))
    }

    @Test func desktopActionPromptKeepsBrowserAutomationOnChromePluginWhenVisualInspectionIsNotNeeded() async throws {
        let prompt = CodexPromptBuilder.desktopActionPrompt(for: "open ChatGPT in Chrome and type hello")

        #expect(prompt.contains("browser typing, clicking, and search"))
        #expect(prompt.contains("prefer the Codex Chrome plugin"))
        #expect(prompt.contains("without visual desktop inspection"))
    }

    @Test func desktopActionPromptScopesForegroundAppToNonChromeOpeningOnly() async throws {
        let prompt = CodexPromptBuilder.desktopActionPrompt(for: "open chatgpt.com in Chrome")

        #expect(prompt.contains("non-Chrome app opening or non-Chrome URL opening"))
        #expect(!prompt.contains("For non-Chrome app or URL opening"))
    }

    @Test func pendingConfirmationStoresAndClearsAction() async throws {
        var confirmation = PendingCommandConfirmation()
        confirmation.request(
            title: "Run Codex with workspace write access?",
            action: .codexWorkspaceWrite("fix the test")
        )

        #expect(confirmation.title == "Run Codex with workspace write access?")
        #expect(confirmation.action == .codexWorkspaceWrite("fix the test"))
        #expect(confirmation.confirm() == .codexWorkspaceWrite("fix the test"))
        #expect(confirmation.title == nil)
        #expect(confirmation.action == nil)
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
        #expect(WorkspaceCommandResult(summary: "Needs confirmation.", status: .needsConfirmation).spokenStatus == "Needs confirmation")
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

    @Test func appServerLaunchCanUseWebSocketTransport() async throws {
        let codexURL = URL(fileURLWithPath: "/usr/local/bin/codex")

        let launch = CodexAppServerLaunch.make(
            codexExecutableURL: codexURL,
            listenURL: "ws://127.0.0.1:48123"
        )

        #expect(launch.executableURL == codexURL)
        #expect(launch.arguments == ["app-server", "--listen", "ws://127.0.0.1:48123"])
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

    @Test func appServerTurnStartCanAttachComputerUseSkillInput() throws {
        let skillPath = "/Users/example/.codex/plugins/computer-use/skills/computer-use/SKILL.md"
        let request = CodexAppServerProtocol.turnStartRequest(
            id: 3,
            threadID: "thread-1",
            prompt: "click submit",
            cwd: "/Users/example",
            skillInputs: [
                CodexAppServerSkillInput(
                    name: "computer-use:computer-use",
                    path: skillPath
                )
            ]
        )
        let params = try #require(request["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])

        #expect(input.count == 2)
        #expect(input[0]["type"] as? String == "text")
        #expect(input[1]["type"] as? String == "skill")
        #expect(input[1]["name"] as? String == "computer-use:computer-use")
        #expect(input[1]["path"] as? String == skillPath)
    }

    @Test func appServerThreadStartEnablesChromeAndComputerUsePluginsForDesktopActions() throws {
        let request = CodexAppServerProtocol.threadStartRequest(id: 2, cwd: "/Users/example")
        let params = try #require(request["params"] as? [String: Any])
        let config = try #require(params["config"] as? [String: Any])
        let plugins = try #require(config["plugins"] as? [String: Any])
        let chromePlugin = try #require(plugins["chrome@openai-bundled"] as? [String: Any])
        let computerUsePlugin = try #require(plugins["computer-use@openai-bundled"] as? [String: Any])

        #expect(chromePlugin["enabled"] as? Bool == true)
        #expect(computerUsePlugin["enabled"] as? Bool == true)
    }

    @Test func appServerThreadStartEnablesComputerUsePluginForDesktopActions() throws {
        let request = CodexAppServerProtocol.threadStartRequest(id: 2, cwd: "/Users/example")
        let params = try #require(request["params"] as? [String: Any])
        let config = try #require(params["config"] as? [String: Any])
        let plugins = try #require(config["plugins"] as? [String: Any])
        let computerUsePlugin = try #require(plugins["computer-use@openai-bundled"] as? [String: Any])

        #expect(computerUsePlugin["enabled"] as? Bool == true)
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
        #expect(result.contentText.contains("Google Chrome"))
        #expect(result.contentText.contains("onscreen"))
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
        #expect(result.contentText.contains("appName or bundleIdentifier"))
        #expect(recorder.events.isEmpty)
    }

    @Test func appServerComputerUseSkillResolverFindsBundledMarketplaceSkill() throws {
        let homeURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let skillURL = homeURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent(".tmp", isDirectory: true)
            .appendingPathComponent("bundled-marketplaces", isDirectory: true)
            .appendingPathComponent("openai-bundled", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("computer-use", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("computer-use", isDirectory: true)
            .appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(
            at: skillURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "Computer Use".write(to: skillURL, atomically: true, encoding: .utf8)

        let input = try #require(CodexAppServerSkillInputResolver.computerUseSkillInput(homeDirectoryURL: homeURL))

        #expect(input.name == "computer-use:computer-use")
        #expect(input.path == skillURL.path)
    }

    @Test func appServerComputerUseSkillResolverFallsBackToPluginCacheSkill() throws {
        let homeURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: homeURL) }
        let skillURL = homeURL
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent("openai-bundled", isDirectory: true)
            .appendingPathComponent("computer-use", isDirectory: true)
            .appendingPathComponent("1.0.799", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("computer-use", isDirectory: true)
            .appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(
            at: skillURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "Computer Use".write(to: skillURL, atomically: true, encoding: .utf8)

        let input = try #require(CodexAppServerSkillInputResolver.computerUseSkillInput(homeDirectoryURL: homeURL))

        #expect(input.name == "computer-use:computer-use")
        #expect(input.path == skillURL.path)
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
        {"id":0,"method":"mcpServer/elicitation/request","params":{"threadId":"thread-1","turnId":"turn-1","serverName":"computer-use","mode":"form","_meta":null,"message":"Allow Computer Use to inspect Google Chrome?","requestedSchema":{"type":"object","properties":{}}}}
        """

        let event = try CodexAppServerProtocol.parseInboundLine(line)

        #expect(event == .approvalRequest(
            CodexAppServerApprovalRequest(
                requestID: 0,
                kind: .mcpElicitation,
                title: "Computer Use approval",
                detail: "Allow Computer Use to inspect Google Chrome?\nServer: computer-use",
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

    @Test func appServerExecutorAnswersMcpElicitationApprovalWithZeroID() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":0,"method":"mcpServer/elicitation/request","params":{"threadId":"thread-1","turnId":"turn-1","serverName":"computer-use","mode":"form","_meta":null,"message":"Allow Codex to use Google Chrome?","requestedSchema":{"type":"object","properties":{}}}}"#,
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
            #"{"method":"item/completed","params":{"threadId":"thread-1","turnId":"turn-1","item":{"id":"item-1","type":"mcpToolCall","status":"failed","server":"computer-use","tool":"get_app_state","result":{"content":[{"type":"text","text":"Computer Use server error -10005: cgWindowNotFound"}],"isError":true}}}}"#,
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

    @Test func appServerExecutorAttachesComputerUseSkillInputToDesktopTurn() async throws {
        let skillPath = "/Users/example/.codex/plugins/computer-use/skills/computer-use/SKILL.md"
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let executor = CodexAppServerExecutor(
            makeTransport: { transport },
            skillInputResolver: {
                [
                    CodexAppServerSkillInput(
                        name: "computer-use:computer-use",
                        path: skillPath
                    )
                ]
            },
            approvalHandler: { _ in .cancel }
        )

        _ = await executor.runDesktopAction(prompt: "click submit", cwd: "/Users/example")

        let sentMessages = try await transport.sentLines.map { line in
            try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        let root = try #require(sentMessages.first { $0["method"] as? String == "turn/start" })
        let params = try #require(root["params"] as? [String: Any])
        let input = try #require(params["input"] as? [[String: Any]])

        #expect(input.contains { item in
            item["type"] as? String == "skill"
                && item["name"] as? String == "computer-use:computer-use"
                && item["path"] as? String == skillPath
        })
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
            turnTimeoutSeconds: 0.01,
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
            turnTimeoutSeconds: 0.01,
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
            turnTimeoutSeconds: 0.01,
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
        let executor = CodexAppServerExecutor(
            turnTimeoutSeconds: 0.01,
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
                #expect(request.tool == "foreground_app")
                return CodexAppServerDynamicToolCallResult(
                    success: true,
                    contentText: "Google Chrome is onscreen."
                )
            },
            approvalHandler: { _ in .cancel }
        )

        let result = await executor.runDesktopAction(prompt: "foreground Chrome", cwd: "/Users/example")

        #expect(result.summary == "Foregrounded and done")
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

    @Test func liveAppServerOpensChromeThroughForegroundDynamicTool() async throws {
        let liveMarkerPath = "/tmp/lorelei-live-app-server-foreground-test"
        guard ProcessInfo.processInfo.environment["LORELEI_LIVE_APP_SERVER_FOREGROUND_TEST"] == "1"
                || FileManager.default.fileExists(atPath: liveMarkerPath) else {
            return
        }

        let foregroundTool = CodexAppServerDesktopForegroundTool()
        let traceRecorder = AppServerTraceRecorder()
        let executor = CodexAppServerExecutor(
            turnTimeoutSeconds: 45,
            dynamicToolSpecsResolver: {
                [CodexAppServerDesktopForegroundTool.spec]
            },
            dynamicToolHandler: { request in
                await foregroundTool.handle(request)
            },
            traceHandler: { event in
                traceRecorder.record(event)
            },
            approvalHandler: { _ in .accept }
        )
        let prompt = """
        Call lorelei.foreground_app exactly once with appName "Google Chrome", bundleIdentifier "com.google.Chrome", and url "https://chatgpt.com".
        After the tool succeeds, reply with the tool result in one sentence.
        Do not use shell commands, the Chrome plugin, or Computer Use for this live smoke test.
        """

        let result = await executor.runDesktopAction(
            prompt: CodexPromptBuilder.desktopActionPrompt(for: prompt),
            cwd: FileManager.default.homeDirectoryForCurrentUser.path
        )

        if result.status != .succeeded {
            let trace = traceRecorder.eventLines
                .joined(separator: "\n")
            Issue.record(
                """
                Live App Server foreground smoke failed.
                Status: \(result.status)
                Summary: \(result.summary)
                Trace:
                \(trace)
                """
            )
        }
        #expect(result.status == .succeeded)
        #expect(result.summary.localizedCaseInsensitiveContains("Chrome"))
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

private actor FakeCodexAppServerTransport: CodexAppServerTransporting {
    private var lines: [String]
    private var recordedSentLines: [String] = []

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

    func send(line: String) async throws {
        recordedSentLines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func nextLine() async throws -> String? {
        guard !lines.isEmpty else { return nil }
        return lines.removeFirst()
    }

    func terminate() async {}
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

@MainActor
private final class SilentSpeechOutput: SpeechOutputing {
    func speak(_ text: String) {}
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
