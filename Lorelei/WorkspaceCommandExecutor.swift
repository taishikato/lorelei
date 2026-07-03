//
//  WorkspaceCommandExecutor.swift
//  Lorelei
//
//  Executes Lorelei's safe built-in workspace actions.
//

import Foundation
import Darwin

enum WorkspaceCommandResultStatus: Equatable, Sendable {
    case succeeded
    case failed
    case cancelled
    case missingWorkspace
}

struct WorkspaceCommandResult: Equatable, Sendable {
    let summary: String
    let status: WorkspaceCommandResultStatus

    nonisolated init(summary: String, status: WorkspaceCommandResultStatus = .succeeded) {
        self.summary = summary
        self.status = status
    }

    nonisolated var spokenStatus: String {
        switch status {
        case .succeeded:
            return "Done"
        case .failed, .cancelled:
            return "Failed"
        case .missingWorkspace:
            return "No workspace selected"
        }
    }
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
            switch action {
            case .unsupported(let message):
                return WorkspaceCommandResult(summary: message)
            case .codexDesktopAction, .codexChromeBrowserOpen:
                return WorkspaceCommandResult(summary: "Codex commands are handled by CodexExecutor.")
            case .gitStatus, .gitDiff, .runTests, .codexReadOnly, .codexWorkspaceWrite, .codexScreen:
                break
            }
            return WorkspaceCommandResult(summary: "Unsupported command.")
        }

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

        switch action {
        case .gitStatus:
            return await runGit(arguments: ["status", "--short", "--branch"], workspacePath: workspacePath)
        case .gitDiff:
            return await runGitDiff(workspacePath: workspacePath)
        case .runTests:
            return WorkspaceCommandResult(summary: "No test command configured.", status: .failed)
        case .codexReadOnly, .codexWorkspaceWrite, .codexScreen, .codexDesktopAction, .codexChromeBrowserOpen:
            return WorkspaceCommandResult(summary: "Codex commands are handled by CodexExecutor.")
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
            return WorkspaceCommandResult(summary: "Command timed out.", status: .failed)
        }

#if DEBUG
        if let testCommandOverride {
            return await Self.runProcess(
                executableURL: testCommandOverride.executableURL,
                arguments: testCommandOverride.arguments,
                currentDirectoryURL: URL(fileURLWithPath: workspacePath),
                emptySuccessSummary: emptySuccessSummary,
                timeoutSeconds: commandTimeoutSeconds,
                prelaunchDelay: testCommandOverride.prelaunchDelay,
                onLaunch: testCommandOverride.onLaunch
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
        timeoutSeconds: TimeInterval,
        prelaunchDelay: TimeInterval = 0,
        onLaunch: (@Sendable () -> Void)? = nil
    ) async -> WorkspaceCommandResult {
        let runner = WorkspaceProcessRunner()
        let execution = await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            timeoutSeconds: timeoutSeconds,
            prelaunchDelay: prelaunchDelay,
            onLaunch: onLaunch
        )

        switch execution.reason {
        case .cancelled:
            return WorkspaceCommandResult(summary: "Command cancelled.", status: .cancelled)
        case .timedOut:
            return WorkspaceCommandResult(summary: "Command timed out.", status: .failed)
        case .failedToStart(let error):
            return WorkspaceCommandResult(
                summary: "Command failed to start: \(error.localizedDescription)",
                status: .failed
            )
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
            return WorkspaceCommandResult(
                summary: "\(command) failed with exit code \(status):\n\(failure)",
                status: .failed
            )
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
    let prelaunchDelay: TimeInterval
    let onLaunch: (@Sendable () -> Void)?

    init(
        executableURL: URL,
        arguments: [String],
        prelaunchDelay: TimeInterval = 0,
        onLaunch: (@Sendable () -> Void)? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.prelaunchDelay = prelaunchDelay
        self.onLaunch = onLaunch
    }
}
#endif

struct WorkspaceProcessExecution: Sendable {
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

final class WorkspaceProcessRunner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.taishi.lorelei.workspace-process-runner")
    private let cancellationLock = NSLock()
    nonisolated(unsafe) private var process: Process?
    nonisolated(unsafe) private var didComplete = false
    nonisolated(unsafe) private var didLaunchProcess = false
    nonisolated(unsafe) private var cancellationRequested = false
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
        timeoutSeconds: TimeInterval,
        prelaunchDelay: TimeInterval = 0,
        onLaunch: (@Sendable () -> Void)? = nil,
        environment: [String: String]? = nil
    ) async -> WorkspaceProcessExecution {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    self.start(
                        executableURL: executableURL,
                        arguments: arguments,
                        currentDirectoryURL: currentDirectoryURL,
                        timeoutSeconds: timeoutSeconds,
                        continuation: continuation,
                        prelaunchDelay: prelaunchDelay,
                        onLaunch: onLaunch,
                        environment: environment
                    )
                }
            }
        } onCancel: {
            cancel()
        }
    }

    /// GUI-launched apps inherit a minimal PATH. Subprocesses that rely on `env node`
    /// or spawn MCP servers via `npx` need common Node install locations prepended.
    nonisolated static func launchEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        let existingComponents = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)

        var mergedComponents: [String] = []
        for candidate in nodeBinPathCandidates() + existingComponents {
            guard !candidate.isEmpty, !mergedComponents.contains(candidate) else { continue }
            mergedComponents.append(candidate)
        }

        environment["PATH"] = mergedComponents.joined(separator: ":")
        return environment
    }

    nonisolated private static func nodeBinPathCandidates() -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home.appendingPathComponent(".nodebrew/current/bin").path,
            "/opt/homebrew/var/nodebrew/current/bin"
        ]

        let nvmVersionsURL = home
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)

        if let versionNames = try? fileManager.contentsOfDirectory(atPath: nvmVersionsURL.path) {
            candidates += versionNames.map {
                nvmVersionsURL
                    .appendingPathComponent($0, isDirectory: true)
                    .appendingPathComponent("bin", isDirectory: true)
                    .path
            }
        }

        return candidates.filter { fileManager.fileExists(atPath: $0) }
    }

    nonisolated func cancel() {
        setCancellationRequested()
        queue.async {
            self.finishOnQueue(reason: .cancelled)
        }
    }

    private func start(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeoutSeconds: TimeInterval,
        continuation: CheckedContinuation<WorkspaceProcessExecution, Never>,
        prelaunchDelay: TimeInterval = 0,
        onLaunch: (@Sendable () -> Void)? = nil,
        environment: [String: String]? = nil
    ) {
        guard !didComplete else {
            continuation.resume(returning: WorkspaceProcessExecution(reason: .cancelled, stdout: "", stderr: ""))
            return
        }

        self.continuation = continuation
        guard !isCancellationRequested() else {
            finishOnQueue(reason: .cancelled)
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.environment = environment ?? Self.launchEnvironment()

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

        if prelaunchDelay > 0 {
            Thread.sleep(forTimeInterval: prelaunchDelay)
        }

        guard !isCancellationRequested() else {
            finishOnQueue(reason: .cancelled)
            return
        }

        do {
            try process.run()
            didLaunchProcess = true
            onLaunch?()
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
        if didLaunchProcess {
            stdoutCollector?.append(Self.readAvailableDataWithoutBlocking(from: stdout?.fileHandleForReading) ?? Data())
            stderrCollector?.append(Self.readAvailableDataWithoutBlocking(from: stderr?.fileHandleForReading) ?? Data())
        }

        let execution = WorkspaceProcessExecution(
            reason: reason,
            stdout: stdoutCollector?.stringValue() ?? "",
            stderr: stderrCollector?.stringValue() ?? ""
        )
        let continuation = continuation
        self.continuation = nil
        self.process = nil
        self.didLaunchProcess = false
        self.stdout = nil
        self.stderr = nil
        self.stdoutCollector = nil
        self.stderrCollector = nil

        continuation?.resume(returning: execution)
    }

    private func terminateProcessOnQueue() {
        let process = process
        guard let process, process.isRunning else { return }
        let processIdentifier = process.processIdentifier
        let descendantProcessIdentifiers = Self.descendantProcessIdentifiers(of: processIdentifier)
        for descendantProcessIdentifier in descendantProcessIdentifiers {
            kill(descendantProcessIdentifier, SIGTERM)
        }

        process.terminate()
        Thread.sleep(forTimeInterval: 0.2)

        let remainingDescendantProcessIdentifiers = Self.uniqueProcessIdentifiers(
            descendantProcessIdentifiers + Self.descendantProcessIdentifiers(of: processIdentifier)
        )
        for descendantProcessIdentifier in remainingDescendantProcessIdentifiers {
            kill(descendantProcessIdentifier, SIGKILL)
        }

        if process.isRunning {
            kill(processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    nonisolated private static func readAvailableDataWithoutBlocking(from fileHandle: FileHandle?) -> Data? {
        guard let fileHandle else { return nil }
        let fileDescriptor = fileHandle.fileDescriptor
        let existingFlags = fcntl(fileDescriptor, F_GETFL)
        if existingFlags >= 0 {
            _ = fcntl(fileDescriptor, F_SETFL, existingFlags | O_NONBLOCK)
        }
        defer {
            if existingFlags >= 0 {
                _ = fcntl(fileDescriptor, F_SETFL, existingFlags)
            }
        }

        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let bytesRead = Darwin.read(fileDescriptor, &buffer, buffer.count)
            if bytesRead > 0 {
                output.append(buffer, count: bytesRead)
                continue
            }
            break
        }
        return output
    }

    nonisolated private static func descendantProcessIdentifiers(of parentProcessIdentifier: pid_t) -> [pid_t] {
        let children = childProcessIdentifiers(of: parentProcessIdentifier)
        return children + children.flatMap { descendantProcessIdentifiers(of: $0) }
    }

    nonisolated private static func childProcessIdentifiers(of parentProcessIdentifier: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-P", String(parentProcessIdentifier)]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0 else { return [] }
        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t(String($0)) }
    }

    nonisolated private static func uniqueProcessIdentifiers(_ processIdentifiers: [pid_t]) -> [pid_t] {
        Array(Set(processIdentifiers))
    }

    nonisolated private func setCancellationRequested() {
        cancellationLock.lock()
        cancellationRequested = true
        cancellationLock.unlock()
    }

    nonisolated private func isCancellationRequested() -> Bool {
        cancellationLock.lock()
        let value = cancellationRequested
        cancellationLock.unlock()
        return value
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
