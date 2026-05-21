//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import Foundation
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

    @Test func routerMapsScreenRequestToCodexScreen() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("look at my screen") == .codexScreen("look at my screen"))
    }

    @Test func routerMapsComputerUseRequestToCodexComputerUse() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("click the submit button") == .codexComputerUse("click the submit button"))
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
