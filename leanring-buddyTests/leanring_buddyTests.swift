//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
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

        #expect(router.route("open the app window") == .codexComputerUse("open the app window"))
    }

    @Test func routerDoesNotMapDesktopCommandToCodexScreen() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("switch desktop") == .codexReadOnly("switch desktop"))
    }

    @Test func routerMapsComputerUseRequestToCodexComputerUse() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("click the submit button") == .codexComputerUse("click the submit button"))
    }

    @Test func routerUsesAIBrowserClassificationForChromeAction() async throws {
        let router = LoreleiCommandRouter()
        let classification = BrowserOperationClassification(
            isBrowserOperation: true,
            operation: "search Google for weather in Tokyo",
            confidence: 0.94
        )

        #expect(
            router.route(
                "search Google for weather in Tokyo",
                browserClassification: classification
            ) == .codexChrome("search Google for weather in Tokyo")
        )
    }

    @Test func confirmationPolicyAllowsOnlySafeLocalAndScopedScreenCommandsImmediately() async throws {
        #expect(!LoreleiConfirmationPolicy.requiresConfirmation(for: .gitStatus))
        #expect(!LoreleiConfirmationPolicy.requiresConfirmation(for: .gitDiff))
        #expect(!LoreleiConfirmationPolicy.requiresConfirmation(for: .runTests))
        #expect(!LoreleiConfirmationPolicy.requiresConfirmation(for: .codexScreen("look at my screen")))
    }

    @Test func confirmationPolicyRequiresPanelConfirmationForBroadCodexWriteAndComputerUseCommands() async throws {
        #expect(LoreleiConfirmationPolicy.requiresConfirmation(for: .codexReadOnly("explain this")))
        #expect(LoreleiConfirmationPolicy.requiresConfirmation(for: .codexWorkspaceWrite("fix the test")))
        #expect(LoreleiConfirmationPolicy.requiresConfirmation(for: .codexComputerUse("click submit")))
        #expect(LoreleiConfirmationPolicy.requiresConfirmation(for: .codexChrome("search Google for OpenAI")))
    }

    @Test func workspaceWritePromptIncludesNoCommitGuard() async throws {
        let prompt = CodexPromptBuilder.workspaceWritePrompt(for: "fix the test")

        #expect(prompt.contains("Do not commit changes."))
        #expect(prompt.contains("fix the test"))
    }

    @Test func chromePromptTargetsCodexChromeAndExistingSession() async throws {
        let prompt = CodexPromptBuilder.chromePrompt(for: "search Google for Lorelei app")

        #expect(prompt.contains("@chrome"))
        #expect(prompt.contains("existing Chrome browser/profile/session"))
        #expect(prompt.contains("Codex Chrome Extension backend only"))
        #expect(prompt.contains("Do not use chrome-devtools"))
        #expect(prompt.contains("search Google for Lorelei app"))
        #expect(prompt.contains("Do not use AppleScript"))
    }

    @Test func browserClassifierPromptRequestsStrictJSONDecision() async throws {
        let prompt = BrowserOperationClassifier.classificationPrompt(
            for: "search Google for Lorelei app"
        )

        #expect(prompt.contains("Return JSON only"))
        #expect(prompt.contains("isBrowserOperation"))
        #expect(prompt.contains("operation"))
        #expect(prompt.contains("search Google for Lorelei app"))
    }

    @Test func browserClassifierOnlyRunsForPossibleBrowserOperations() async throws {
        #expect(BrowserOperationClassifier.shouldClassify("search Google for Lorelei app"))
        #expect(BrowserOperationClassifier.shouldClassify("open the dashboard in Chrome"))
        #expect(!BrowserOperationClassifier.shouldClassify("@chrome search Google for Lorelei app"))
        #expect(!BrowserOperationClassifier.shouldClassify("git status"))
        #expect(!BrowserOperationClassifier.shouldClassify("explain this Swift file"))
    }

    @Test func browserClassifierParsesJSONDecision() async throws {
        let classification = BrowserOperationClassifier.parseClassificationResponse(
            """
            {"isBrowserOperation":true,"operation":"search Google for Lorelei app","confidence":0.91}
            """
        )

        #expect(classification == BrowserOperationClassification(
            isBrowserOperation: true,
            operation: "search Google for Lorelei app",
            confidence: 0.91
        ))
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

    @Test func codexExecutorUsesFallbackWorkingDirectoryWhenWorkspaceIsMissing() async throws {
        let fallbackDirectoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fallbackDirectoryURL) }
        let recorder = CodexCommandRecorder(finalMessage: "Chrome answer")
        let executor = CodexExecutor(
            codexExecutableResolver: { URL(fileURLWithPath: "/usr/local/bin/codex") },
            commandRunner: recorder.run
        )

        let result = await executor.run(
            .workspaceWrite,
            prompt: "@chrome search Google for Lorelei",
            workspacePath: nil,
            fallbackWorkingDirectoryPath: fallbackDirectoryURL.path
        )

        #expect(result.summary == "Chrome answer")
        #expect(recorder.currentDirectoryURL == fallbackDirectoryURL)
        #expect(recorder.arguments?.contains(fallbackDirectoryURL.path) == true)
        #expect(recorder.arguments?.contains("--skip-git-repo-check") == true)
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

    @Test func chromeBridgePlannerBuildsGoogleSearchCommand() async throws {
        let command = ChromeBridgeCommandPlanner.command(for: "search Google for Lorelei voice control smoke test")

        #expect(command == .googleSearch(query: "Lorelei voice control smoke test"))
    }

    @Test func chromeBridgePlannerRejectsUnsupportedChromeCommands() async throws {
        let command = ChromeBridgeCommandPlanner.command(for: "click the first result")

        #expect(command == nil)
    }

    @Test func chromeBridgeRequestEncodesSingleJSONLine() async throws {
        let request = ChromeBridgeRequest(
            id: "test-id",
            command: .googleSearch(query: "Lorelei voice control smoke test")
        )

        let line = try ChromeBridgeLineCodec.encode(request)

        #expect(line.hasSuffix("\n"))
        #expect(line.contains("\"type\":\"googleSearch\""))
        #expect(line.contains("\"query\":\"Lorelei voice control smoke test\""))
    }

    @Test func chromeBridgeResponseSummaryReportsGoogleSearchState() async throws {
        let response = ChromeBridgeResponse(
            id: "test-id",
            ok: true,
            type: "googleSearch",
            title: "Lorelei voice control smoke test - Google Search",
            url: "https://www.google.com/search?q=Lorelei%20voice%20control%20smoke%20test",
            searchValue: "Lorelei voice control smoke test",
            error: nil
        )

        #expect(response.summary == "Chrome Google search opened: Lorelei voice control smoke test")
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

@MainActor
private final class SilentSpeechOutput: SpeechOutputing {
    func speak(_ text: String) {}
}
