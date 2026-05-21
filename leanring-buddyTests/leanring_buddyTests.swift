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

    @Test func routerReturnsUnsupportedForUnknownText() async throws {
        let router = LoreleiCommandRouter()

        #expect(router.route("open the project") == .unsupported("Only status, diff, and test are wired yet."))
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
