//
//  WorkspaceCommandExecutor.swift
//  leanring-buddy
//
//  Executes Lorelei's safe built-in workspace actions.
//

import Foundation
import Darwin

struct WorkspaceCommandResult: Equatable, Sendable {
    let summary: String
}

struct WorkspaceCommandExecutor {
    private let fileManager: FileManager
    private let commandTimeoutSeconds: TimeInterval
#if DEBUG
    private let testCommandOverride: WorkspaceCommandTestHook?
#endif

#if DEBUG
    init(
        fileManager: FileManager = .default,
        commandTimeoutSeconds: TimeInterval = 10,
        testCommandOverride: WorkspaceCommandTestHook? = nil
    ) {
        self.fileManager = fileManager
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.testCommandOverride = testCommandOverride
    }
#else
    init(fileManager: FileManager = .default, commandTimeoutSeconds: TimeInterval = 10) {
        self.fileManager = fileManager
        self.commandTimeoutSeconds = commandTimeoutSeconds
    }
#endif

    func run(_ action: LoreleiCommandAction, workspacePath: String?) async -> WorkspaceCommandResult {
        guard action.requiresWorkspace else {
            if case let .unsupported(message) = action {
                return WorkspaceCommandResult(summary: message)
            }
            return WorkspaceCommandResult(summary: "Unsupported command.")
        }

        guard let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspacePath.isEmpty else {
            return WorkspaceCommandResult(summary: "No workspace selected.")
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspacePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return WorkspaceCommandResult(summary: "Workspace path is not a valid directory: \(workspacePath)")
        }

        switch action {
        case .gitStatus:
            return await runGit(arguments: ["status", "--short", "--branch"], workspacePath: workspacePath)
        case .gitDiff:
            return await runGitDiff(workspacePath: workspacePath)
        case .runTests:
            return WorkspaceCommandResult(summary: "No test command configured")
        case .unsupported(let message):
            return WorkspaceCommandResult(summary: message)
        }
    }

    private func runGitDiff(workspacePath: String) async -> WorkspaceCommandResult {
        let stat = await runGit(arguments: ["diff", "--stat"], workspacePath: workspacePath, emptySuccessSummary: "")
        let conciseDiff = await runGit(
            arguments: ["diff", "--name-status"],
            workspacePath: workspacePath,
            emptySuccessSummary: ""
        )

        let combined = [stat.summary, conciseDiff.summary]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        return WorkspaceCommandResult(summary: combined.isEmpty ? "No diff." : combined)
    }

    private func runGit(
        arguments: [String],
        workspacePath: String,
        emptySuccessSummary: String = "No output."
    ) async -> WorkspaceCommandResult {
        guard commandTimeoutSeconds > 0 else {
            return WorkspaceCommandResult(summary: "Command timed out.")
        }

#if DEBUG
        if let testCommandOverride {
            return await Self.runProcess(
                executableURL: testCommandOverride.executableURL,
                arguments: testCommandOverride.arguments,
                currentDirectoryURL: URL(fileURLWithPath: workspacePath),
                emptySuccessSummary: emptySuccessSummary,
                timeoutSeconds: commandTimeoutSeconds
            )
        }
#endif

        let invocation = Self.gitInvocation(arguments: arguments)
        return await Self.runProcess(
            executableURL: invocation.executableURL,
            arguments: invocation.arguments,
            currentDirectoryURL: URL(fileURLWithPath: workspacePath),
            emptySuccessSummary: emptySuccessSummary,
            timeoutSeconds: commandTimeoutSeconds
        )
    }

    nonisolated private static func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        emptySuccessSummary: String,
        timeoutSeconds: TimeInterval
    ) async -> WorkspaceCommandResult {
        let runner = WorkspaceProcessRunner()
        let execution = await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            timeoutSeconds: timeoutSeconds
        )

        switch execution.reason {
        case .cancelled:
            return WorkspaceCommandResult(summary: "Command cancelled.")
        case .timedOut:
            return WorkspaceCommandResult(summary: "Command timed out.")
        case .failedToStart(let error):
            return WorkspaceCommandResult(summary: "Command failed to start: \(error.localizedDescription)")
        case .exited(let status):
            let combined = [execution.stdout, execution.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")

            let conciseOutput = concise(combined)
            if status == 0 {
                return WorkspaceCommandResult(summary: conciseOutput.isEmpty ? emptySuccessSummary : conciseOutput)
            }

            let command = ([executableURL.path] + arguments).joined(separator: " ")
            let failure = conciseOutput.isEmpty ? "No output." : conciseOutput
            return WorkspaceCommandResult(summary: "\(command) failed with exit code \(status):\n\(failure)")
        }
    }

    nonisolated private static func gitInvocation(arguments: [String]) -> (executableURL: URL, arguments: [String]) {
        let fixedPath = "/usr/bin/git"
        if FileManager.default.isExecutableFile(atPath: fixedPath) {
            return (URL(fileURLWithPath: fixedPath), arguments)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["git"] + arguments)
    }

    nonisolated private static func concise(_ output: String, maxCharacters: Int = 4_000) -> String {
        guard output.count > maxCharacters else { return output }
        let endIndex = output.index(output.startIndex, offsetBy: maxCharacters)
        return "\(output[..<endIndex])\n... output truncated ..."
    }
}

#if DEBUG
struct WorkspaceCommandTestHook: Sendable {
    let executableURL: URL
    let arguments: [String]

    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }
}
#endif

private struct WorkspaceProcessExecution: Sendable {
    enum Reason: Sendable {
        case exited(Int32)
        case timedOut
        case cancelled
        case failedToStart(Error)
    }

    let reason: Reason
    let stdout: String
    let stderr: String
}

private final class WorkspaceProcessRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.taishi.lorelei.workspace-process-runner")
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var didComplete = false
    nonisolated(unsafe) private var continuation: CheckedContinuation<WorkspaceProcessExecution, Never>?
    nonisolated(unsafe) private var stdout: Pipe?
    nonisolated(unsafe) private var stderr: Pipe?
    nonisolated(unsafe) private var stdoutCollector: WorkspaceOutputCollector?
    nonisolated(unsafe) private var stderrCollector: WorkspaceOutputCollector?
    nonisolated(unsafe) private var timeoutWorkItem: DispatchWorkItem?

    nonisolated init() {}

    nonisolated func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeoutSeconds: TimeInterval
    ) async -> WorkspaceProcessExecution {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.start(
                        executableURL: executableURL,
                        arguments: arguments,
                        currentDirectoryURL: currentDirectoryURL,
                        timeoutSeconds: timeoutSeconds,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            cancel()
        }
    }

    nonisolated func cancel() {
        queue.async {
            self.finishOnQueue(reason: .cancelled)
        }
    }

    private func start(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeoutSeconds: TimeInterval,
        continuation: CheckedContinuation<WorkspaceProcessExecution, Never>
    ) {
        guard !didComplete else {
            continuation.resume(returning: WorkspaceProcessExecution(reason: .cancelled, stdout: "", stderr: ""))
            return
        }

        self.continuation = continuation

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        let stdoutCollector = WorkspaceOutputCollector()
        let stderrCollector = WorkspaceOutputCollector()

        process.standardOutput = stdout
        process.standardError = stderr
        self.process = process
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutCollector = stdoutCollector
        self.stderrCollector = stderrCollector

        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.queue.async {
                self?.finishOnQueue(reason: .timedOut)
            }
        }
        self.timeoutWorkItem = timeoutWorkItem

        process.terminationHandler = { [weak self] terminatedProcess in
            self?.queue.async {
                self?.finishOnQueue(reason: .exited(terminatedProcess.terminationStatus))
            }
        }

        do {
            try process.run()
            queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)
        } catch {
            finishOnQueue(reason: .failedToStart(error))
        }
    }

    private func finishOnQueue(reason: WorkspaceProcessExecution.Reason) {
        guard !didComplete else {
            return
        }
        didComplete = true

        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        if case .timedOut = reason {
            terminateProcessOnQueue()
        } else if case .cancelled = reason {
            terminateProcessOnQueue()
        }

        stdout?.fileHandleForReading.readabilityHandler = nil
        stderr?.fileHandleForReading.readabilityHandler = nil
        if case .failedToStart = reason {
            // Nothing was launched, so the pipe write ends may still be open locally.
        } else {
            stdoutCollector?.append(stdout?.fileHandleForReading.readDataToEndOfFile() ?? Data())
            stderrCollector?.append(stderr?.fileHandleForReading.readDataToEndOfFile() ?? Data())
        }

        let execution = WorkspaceProcessExecution(
            reason: reason,
            stdout: stdoutCollector?.stringValue() ?? "",
            stderr: stderrCollector?.stringValue() ?? ""
        )
        let continuation = continuation
        self.continuation = nil
        self.process = nil
        self.stdout = nil
        self.stderr = nil
        self.stdoutCollector = nil
        self.stderrCollector = nil

        continuation?.resume(returning: execution)
    }

    private func terminateProcessOnQueue() {
        let process = process
        guard let process, process.isRunning else { return }
        process.terminate()
        Thread.sleep(forTimeInterval: 0.2)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private final class WorkspaceOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes = 8_000
    nonisolated(unsafe) private var data = Data()
    nonisolated(unsafe) private var isTruncated = false

    nonisolated init() {}

    nonisolated func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        guard data.count < maxBytes else {
            isTruncated = true
            return
        }

        let remainingBytes = maxBytes - data.count
        if chunk.count <= remainingBytes {
            data.append(chunk)
        } else {
            data.append(chunk.prefix(remainingBytes))
            isTruncated = true
        }
    }

    nonisolated func stringValue() -> String {
        lock.lock()
        let value = String(data: data, encoding: .utf8) ?? ""
        let truncated = isTruncated
        lock.unlock()

        return truncated ? "\(value)\n... output truncated ..." : value
    }
}
