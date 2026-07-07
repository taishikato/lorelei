//
//  WorkspaceExecutorTests.swift
//  LoreleiTests
//

import Testing
import AppKit
import Combine
import CoreAudio
import Foundation
import CoreGraphics
import ServiceManagement
@testable import Lorelei

@MainActor
struct WorkspaceExecutorTests {

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
                // Generous, not knife-edge: the 50ms pre-cancel sleep below
                // can overshoot under parallel-suite load, and the cancel
                // must land before this delay elapses or the process
                // launches and the assertion cannot hold.
                prelaunchDelay: 1.5,
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

        #expect(result.summary == "Codex commands are handled by Codex App Server.")
        #expect(result.status == .succeeded)
    }

    @Test func screenContextRunnerDoesNotCaptureForInvalidWorkspace() async throws {
        let captureCounter = LaunchCounter()
        let missingWorkspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)", isDirectory: true)
        let runCounter = LaunchCounter()
        let runner = CodexScreenContextRequestRunner(
            captureCursorScreen: {
                captureCounter.increment()
                return nil
            }
        )

        let result = await runner.run(prompt: "look at my screen", workspacePath: missingWorkspace.path) { _, _ in
            runCounter.increment()
            return WorkspaceCommandResult(summary: "Should not run")
        }

        #expect(result.summary == "Workspace path is not a valid directory: \(missingWorkspace.path)")
        #expect(captureCounter.value == 0)
        #expect(runCounter.value == 0)
    }

    @Test func screenContextRunnerCancelsBeforeWritingTempImage() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let captureCounter = LaunchCounter()
        let tempURLCounter = LaunchCounter()
        let runCounter = LaunchCounter()
        let runner = CodexScreenContextRequestRunner(
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

        let result = await runner.run(prompt: "look at my screen", workspacePath: directoryURL.path) { _, _ in
            runCounter.increment()
            return WorkspaceCommandResult(summary: "Should not run")
        }

        #expect(result.summary == "Screen capture cancelled.")
        #expect(captureCounter.value == 1)
        #expect(tempURLCounter.value == 0)
        #expect(runCounter.value == 0)
    }

    @Test func screenContextRunnerFeedsCapturedImageToSharedTurn() async throws {
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let imageURL = directoryURL.appendingPathComponent("screen.jpg")
        var receivedPrompt: String?
        var receivedImagePath: String?
        let runner = CodexScreenContextRequestRunner(
            captureCursorScreen: {
                CompanionScreenCapture(
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
            makeTemporaryImageURL: { imageURL }
        )

        let result = await runner.run(prompt: "look at my screen", workspacePath: directoryURL.path) { prompt, imagePath in
            receivedPrompt = prompt
            receivedImagePath = imagePath
            return WorkspaceCommandResult(summary: "Screen answer")
        }

        #expect(result.summary == "Screen answer")
        #expect(receivedPrompt == "look at my screen")
        #expect(receivedImagePath == imageURL.path)
        #expect(FileManager.default.fileExists(atPath: imageURL.path))
    }

    private func makeTemporaryGitRepository() throws -> URL {
        let repositoryURL = try makeTemporaryDirectory()
        try runGitTestCommand(["init"], in: repositoryURL)
        return repositoryURL
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
}
