//
//  CodexAppServerExecutor.swift
//  Lorelei
//
//  Drives interactive desktop-control turns through Codex App Server.
//

import Foundation

enum CodexAppServerApprovalDecision: Equatable, Sendable {
    case accept
    case cancel
}

typealias CodexAppServerDynamicToolHandler = @MainActor (
    _ request: CodexAppServerDynamicToolCallRequest
) async -> CodexAppServerDynamicToolCallResult

struct CodexAppServerTraceEvent: Equatable, Sendable {
    nonisolated let logLine: String

    private init(_ logLine: String) {
        self.logLine = logLine
    }

    static func inbound(_ detail: String) -> Self {
        Self("inbound \(detail)")
    }

    static func outbound(_ detail: String) -> Self {
        Self("outbound \(detail)")
    }

    static func dynamicToolStarted(_ detail: String) -> Self {
        Self("dynamicToolStarted \(detail)")
    }

    static func dynamicToolCompleted(_ detail: String) -> Self {
        Self("dynamicToolCompleted \(detail)")
    }
}

typealias CodexAppServerTraceHandler = @Sendable (_ event: CodexAppServerTraceEvent) -> Void

private final class CodexAppServerTraceBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maxLines: Int
    private var lines: [String] = []

    init(maxLines: Int = 30) {
        self.maxLines = maxLines
    }

    func record(_ event: CodexAppServerTraceEvent) {
        lock.lock()
        defer { lock.unlock() }

        lines.append(event.logLine)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func diagnosticSuffix() -> String {
        lock.lock()
        defer { lock.unlock() }

        guard !lines.isEmpty else { return "" }
        return "\n\nTrace:\n" + lines.joined(separator: "\n")
    }
}

protocol CodexAppServerTransporting: Sendable {
    func send(line: String) async throws
    func nextLine() async throws -> String?
    func terminate() async
}

enum CodexAppServerLaunch {
    static func make(
        codexExecutableURL: URL,
        fileManager: FileManager = .default
    ) -> (executableURL: URL, arguments: [String]) {
        CodexExecutor.makeLaunchCommand(
            codexExecutableURL: codexExecutableURL,
            codexArguments: ["app-server"],
            fileManager: fileManager
        )
    }
}

struct CodexAppServerExecutor {
    private let turnTimeoutSeconds: TimeInterval
    private let makeTransport: () async throws -> CodexAppServerTransporting
    private let dynamicToolSpecsResolver: () -> [CodexAppServerDynamicToolSpec]
    private let dynamicToolHandler: CodexAppServerDynamicToolHandler
    private let traceHandler: CodexAppServerTraceHandler
    private let progressHandler: CodexAppServerTurnProgressHandler
    private let approvalHandler: (CodexAppServerApprovalRequest) async -> CodexAppServerApprovalDecision

    init(
        turnTimeoutSeconds: TimeInterval = 120,
        makeTransport: @escaping () async throws -> CodexAppServerTransporting = {
            try await CodexAppServerStdioTransport.make()
        },
        dynamicToolSpecsResolver: @escaping () -> [CodexAppServerDynamicToolSpec] = { [] },
        dynamicToolHandler: @escaping CodexAppServerDynamicToolHandler = { request in
            CodexAppServerDynamicToolCallResult(
                success: false,
                contentText: "Unsupported dynamic tool: \(request.namespace.map { "\($0)." } ?? "")\(request.tool)"
            )
        },
        traceHandler: @escaping CodexAppServerTraceHandler = { _ in },
        progressHandler: @escaping CodexAppServerTurnProgressHandler = { _ in },
        approvalHandler: @escaping (CodexAppServerApprovalRequest) async -> CodexAppServerApprovalDecision
    ) {
        self.turnTimeoutSeconds = turnTimeoutSeconds
        self.makeTransport = makeTransport
        self.dynamicToolSpecsResolver = dynamicToolSpecsResolver
        self.dynamicToolHandler = dynamicToolHandler
        self.traceHandler = traceHandler
        self.progressHandler = progressHandler
        self.approvalHandler = approvalHandler
    }

    func runDesktopAction(prompt: String, cwd: String) async -> WorkspaceCommandResult {
        guard turnTimeoutSeconds > 0 else {
            return WorkspaceCommandResult(summary: "Codex App Server command timed out.", status: .failed)
        }

        let traceBuffer = CodexAppServerTraceBuffer()
        let transport: CodexAppServerTransporting
        do {
            transport = try await makeTransport()
        } catch {
            return WorkspaceCommandResult(
                summary: "Codex App Server failed to start: \(error.localizedDescription)"
                    + traceBuffer.diagnosticSuffix(),
                status: .failed
            )
        }

        let timeoutState = CodexAppServerTimeoutState()
        let timeoutTask = Task { [turnTimeoutSeconds, transport, timeoutState] in
            try? await Task.sleep(for: .seconds(turnTimeoutSeconds))
            await timeoutState.markTimedOut()
            await transport.terminate()
        }
        defer { timeoutTask.cancel() }

        var isWaitingOnApproval = false

        do {
            try await send(CodexAppServerProtocol.initializeRequest(id: 1), to: transport, traceBuffer: traceBuffer)

            var didStartThread = false
            var finalText = ""
            var pendingToolFailure: String?

            while let line = try await transport.nextLine() {
                let event = try CodexAppServerProtocol.parseInboundLine(line)
                recordTrace(.inbound(traceDetail(for: event)), to: traceBuffer)
                switch event {
                case .response(let requestID):
                    if requestID == 1 {
                        try await send(
                            CodexAppServerProtocol.initializedNotification(),
                            to: transport,
                            traceBuffer: traceBuffer
                        )
                        try await send(
                            CodexAppServerProtocol.threadStartRequest(
                                id: 2,
                                cwd: cwd,
                                dynamicTools: dynamicToolSpecsResolver()
                            ),
                            to: transport,
                            traceBuffer: traceBuffer
                        )
                    }
                case .threadStarted(_, let threadID):
                    didStartThread = true
                    try await send(
                        CodexAppServerProtocol.turnStartRequest(
                            id: 3,
                            threadID: threadID,
                            prompt: prompt,
                            cwd: cwd
                        ),
                        to: transport,
                        traceBuffer: traceBuffer
                    )
                case .agentMessageDelta(let delta):
                    progressHandler(.agentMessageDelta(delta))
                    finalText += delta
                case .toolCallCompleted(let status, let failureMessage, let name):
                    progressHandler(.toolCallCompleted(name: name ?? "tool", success: status != "failed"))
                    if status == "failed" {
                        pendingToolFailure = failureMessage ?? "Codex App Server tool call failed."
                    } else {
                        pendingToolFailure = nil
                    }
                case .approvalRequest(let request):
                    let decision = await approvalHandler(request)
                    let payload = decision == .accept ? request.acceptPayload : request.declinePayload
                    try await send(
                        CodexAppServerProtocol.approvalResponse(id: request.requestID, payload: payload),
                        to: transport,
                        traceBuffer: traceBuffer
                    )
                case .dynamicToolCall(let request):
                    recordTrace(.dynamicToolStarted(request.traceIdentifier), to: traceBuffer)
                    progressHandler(.toolCallStarted(name: request.displayName))
                    let result = await dynamicToolHandler(request)
                    recordTrace(
                        .dynamicToolCompleted("\(request.traceIdentifier):success=\(result.success)"),
                        to: traceBuffer
                    )
                    progressHandler(.toolCallCompleted(name: request.displayName, success: result.success))
                    try await send(
                        CodexAppServerProtocol.dynamicToolCallResponse(
                            id: request.requestID,
                            result: result
                        ),
                        to: transport,
                        traceBuffer: traceBuffer
                    )
                case .unsupportedServerRequest(_, let method):
                    await transport.terminate()
                    return WorkspaceCommandResult(
                        summary: "Codex App Server requested unsupported client method: \(method)",
                        status: .failed
                    )
                case .turnCompleted(let status):
                    await transport.terminate()
                    if status == "completed" {
                        let summary = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let pendingToolFailure {
                            return WorkspaceCommandResult(
                                summary: summary.isEmpty ? pendingToolFailure : summary,
                                status: .failed
                            )
                        }
                        return WorkspaceCommandResult(summary: summary.isEmpty ? "Codex completed." : summary)
                    }
                    return WorkspaceCommandResult(
                        summary: "Codex App Server turn ended with status: \(status)",
                        status: .failed
                    )
                case .error(let message):
                    await transport.terminate()
                    return WorkspaceCommandResult(summary: "Codex App Server error: \(message)", status: .failed)
                case .threadWaitingOnApproval(let waitingOnApproval):
                    isWaitingOnApproval = waitingOnApproval
                case .ignored:
                    break
                }

                if Task.isCancelled {
                    await transport.terminate()
                    return WorkspaceCommandResult(summary: "Codex App Server command cancelled.", status: .cancelled)
                }
            }

            await transport.terminate()
            if await timeoutState.didTimeOut {
                return timeoutResult(isWaitingOnApproval: isWaitingOnApproval, traceBuffer: traceBuffer)
            }
            if didStartThread {
                return WorkspaceCommandResult(
                    summary: "Codex App Server closed before completing the turn.",
                    status: .failed
                )
            }
            return WorkspaceCommandResult(summary: "Codex App Server did not start a thread.", status: .failed)
        } catch {
            await transport.terminate()
            if await timeoutState.didTimeOut {
                return timeoutResult(isWaitingOnApproval: isWaitingOnApproval, traceBuffer: traceBuffer)
            }
            return WorkspaceCommandResult(summary: "Codex App Server failed: \(error.localizedDescription)", status: .failed)
        }
    }

    func runComputerUse(prompt: String, cwd: String) async -> WorkspaceCommandResult {
        await runDesktopAction(prompt: prompt, cwd: cwd)
    }

    private func send(
        _ message: [String: Any],
        to transport: CodexAppServerTransporting,
        traceBuffer: CodexAppServerTraceBuffer
    ) async throws {
        try await transport.send(line: CodexAppServerProtocol.encodeLine(message))
        recordTrace(.outbound(traceDetail(forOutboundMessage: message)), to: traceBuffer)
    }

    private func timeoutResult(
        isWaitingOnApproval: Bool,
        traceBuffer: CodexAppServerTraceBuffer
    ) -> WorkspaceCommandResult {
        if isWaitingOnApproval {
            return WorkspaceCommandResult(
                summary: "Codex App Server is waiting for approval, but no approval request was delivered."
                    + traceBuffer.diagnosticSuffix(),
                status: .failed
            )
        }

        return WorkspaceCommandResult(
            summary: "Codex App Server command timed out." + traceBuffer.diagnosticSuffix(),
            status: .failed
        )
    }

    private func recordTrace(
        _ event: CodexAppServerTraceEvent,
        to traceBuffer: CodexAppServerTraceBuffer
    ) {
        traceBuffer.record(event)
        traceHandler(event)
    }

    private func traceDetail(for event: CodexAppServerInboundEvent) -> String {
        switch event {
        case .response(let requestID):
            return "response#\(requestID)"
        case .threadStarted(let requestID, let threadID):
            return "threadStarted#\(requestID):\(threadID)"
        case .agentMessageDelta:
            return "agentMessageDelta"
        case .toolCallCompleted(let status, _, _):
            return "toolCallCompleted:\(status)"
        case .turnCompleted(let status):
            return "turnCompleted:\(status)"
        case .threadWaitingOnApproval(let isWaiting):
            return "threadWaitingOnApproval:\(isWaiting)"
        case .approvalRequest(let request):
            return "approvalRequest#\(request.requestID):\(request.kind)"
        case .dynamicToolCall(let request):
            return "dynamicToolCall#\(request.traceIdentifier)"
        case .unsupportedServerRequest(let requestID, let method):
            return "unsupportedServerRequest#\(requestID):\(method)"
        case .error(let message):
            return "error:\(message)"
        case .ignored:
            return "ignored"
        }
    }

    private func traceDetail(forOutboundMessage message: [String: Any]) -> String {
        if let method = message["method"] as? String {
            if let id = message["id"] {
                return "\(method)#\(id)"
            }
            return method
        }

        if let id = message["id"] {
            return "response#\(id)"
        }

        return "message"
    }

}

private extension CodexAppServerDynamicToolCallRequest {
    var displayName: String {
        "\(namespace.map { "\($0)." } ?? "")\(tool)"
    }
}

private actor CodexAppServerTimeoutState {
    private var timedOut = false

    var didTimeOut: Bool {
        timedOut
    }

    func markTimedOut() {
        timedOut = true
    }
}

actor CodexAppServerStdioTransport: CodexAppServerTransporting {
    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutReader: CodexAppServerLineReader

    static func make(
        codexExecutableURL: URL? = nil,
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) async throws -> CodexAppServerStdioTransport {
        guard let codexExecutableURL = codexExecutableURL ?? CodexExecutableLocator(
            fileManager: fileManager,
            defaults: defaults
        ).resolve() else {
            throw CodexAppServerStdioTransportError.missingCodexExecutable
        }
        let launch = CodexAppServerLaunch.make(
            codexExecutableURL: codexExecutableURL,
            fileManager: fileManager
        )
        return try await make(executableURL: launch.executableURL, arguments: launch.arguments)
    }

    static func make(executableURL: URL, arguments: [String]) async throws -> CodexAppServerStdioTransport {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.environment = WorkspaceProcessRunner.launchEnvironment()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // stderr is intentionally discarded (codex logs startup notices there).
        // Never drain it with FileHandle.bytes: Foundation serializes all
        // AsyncBytes reads through one shared IO executor, so a blocked stderr
        // read would also block the stdout protocol reads and deadlock turns.
        process.standardError = FileHandle.nullDevice

        try process.run()

        return CodexAppServerStdioTransport(
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            stdoutHandle: stdoutPipe.fileHandleForReading
        )
    }

    private init(
        process: Process,
        stdinHandle: FileHandle,
        stdoutHandle: FileHandle
    ) {
        self.process = process
        self.stdinHandle = stdinHandle
        self.stdoutReader = CodexAppServerLineReader(stdoutHandle: stdoutHandle)
    }

    func send(line: String) async throws {
        let payload = line.hasSuffix("\n") ? line : line + "\n"
        try stdinHandle.write(contentsOf: Data(payload.utf8))
    }

    func nextLine() async throws -> String? {
        try await stdoutReader.next()
    }

    func terminate() async {
        try? stdinHandle.close()

        if process.isRunning {
            process.terminate()
        }
    }
}

private final class CodexAppServerLineReader: @unchecked Sendable {
    nonisolated(unsafe) private var lines: AsyncLineSequence<FileHandle.AsyncBytes>.AsyncIterator

    nonisolated init(stdoutHandle: FileHandle) {
        self.lines = stdoutHandle.bytes.lines.makeAsyncIterator()
    }

    nonisolated func next() async throws -> String? {
        try await lines.next()
    }
}

private enum CodexAppServerStdioTransportError: Error, LocalizedError {
    case missingCodexExecutable

    var errorDescription: String? {
        switch self {
        case .missingCodexExecutable:
            return "Codex executable was not found."
        }
    }
}

private extension CodexAppServerDynamicToolCallRequest {
    var traceIdentifier: String {
        "\(requestID):\(namespace.map { "\($0)." } ?? "")\(tool)"
    }
}
