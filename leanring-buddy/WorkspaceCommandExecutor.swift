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

    init(fileManager: FileManager = .default, commandTimeoutSeconds: TimeInterval = 10) {
        self.fileManager = fileManager
        self.commandTimeoutSeconds = commandTimeoutSeconds
    }

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
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.taishi.lorelei.workspace-process-runner")
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var didComplete = false
    nonisolated(unsafe) private var completion: ((WorkspaceProcessExecution.Reason) -> Void)?

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
        finish(reason: .cancelled)
    }

    nonisolated private func start(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeoutSeconds: TimeInterval,
        continuation: CheckedContinuation<WorkspaceProcessExecution, Never>
    ) {
        lock.lock()
        guard !didComplete else {
            lock.unlock()
            continuation.resume(returning: WorkspaceProcessExecution(reason: .cancelled, stdout: "", stderr: ""))
            return
        }
        lock.unlock()

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

        stdout.fileHandleForReading.readabilityHandler = { handle in
            stdoutCollector.append(handle.availableData)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            stderrCollector.append(handle.availableData)
        }

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            self?.finish(reason: .timedOut)
        }

        process.terminationHandler = { [weak self] terminatedProcess in
            self?.finish(reason: .exited(terminatedProcess.terminationStatus))
        }

        let completion: (WorkspaceProcessExecution.Reason) -> Void = { [weak self] reason in
            timeoutWorkItem.cancel()

            if case .timedOut = reason {
                self?.terminateRunningProcess()
            } else if case .cancelled = reason {
                self?.terminateRunningProcess()
            }

            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            if case .failedToStart = reason {
                // Nothing was launched, so the pipe write ends may still be open locally.
            } else {
                stdoutCollector.append(stdout.fileHandleForReading.readDataToEndOfFile())
                stderrCollector.append(stderr.fileHandleForReading.readDataToEndOfFile())
            }

            continuation.resume(returning: WorkspaceProcessExecution(
                reason: reason,
                stdout: stdoutCollector.stringValue(),
                stderr: stderrCollector.stringValue()
            ))
        }

        lock.lock()
        self.process = process
        self.completion = completion
        lock.unlock()

        do {
            try process.run()
            queue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeoutWorkItem)
        } catch {
            finish(reason: .failedToStart(error))
        }
    }

    nonisolated private func finish(
        reason: WorkspaceProcessExecution.Reason,
        stdoutCollector: WorkspaceOutputCollector? = nil,
        stderrCollector: WorkspaceOutputCollector? = nil,
        continuation: CheckedContinuation<WorkspaceProcessExecution, Never>? = nil,
        timeoutWorkItem: DispatchWorkItem? = nil
    ) {
        let completionToCall: ((WorkspaceProcessExecution.Reason) -> Void)?

        lock.lock()
        guard !didComplete else {
            lock.unlock()
            return
        }
        didComplete = true
        completionToCall = completion
        lock.unlock()

        if let completionToCall {
            completionToCall(reason)
            return
        }

        timeoutWorkItem?.cancel()
        if case .timedOut = reason {
            terminateRunningProcess()
        } else if case .cancelled = reason {
            terminateRunningProcess()
        }
        continuation?.resume(returning: WorkspaceProcessExecution(
            reason: reason,
            stdout: stdoutCollector?.stringValue() ?? "",
            stderr: stderrCollector?.stringValue() ?? ""
        ))
    }

    nonisolated private func terminateRunningProcess() {
        lock.lock()
        let process = process
        self.process = nil
        lock.unlock()

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
