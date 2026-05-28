//
//  CodexAppServerExecutor.swift
//  leanring-buddy
//
//  Drives interactive desktop-control turns through Codex App Server.
//

import Foundation

enum CodexAppServerApprovalDecision: Equatable, Sendable {
    case accept
    case cancel
}

enum CodexAppServerPreflightResult: Equatable, Sendable {
    case completed(String)
    case warning(String)
    case failed(String)
}

typealias CodexAppServerPreflight = @Sendable (_ prompt: String) async -> CodexAppServerPreflightResult

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

    static func preflight(_ detail: String) -> Self {
        Self("preflight \(detail)")
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
        listenURL: String = "stdio://",
        fileManager: FileManager = .default
    ) -> (executableURL: URL, arguments: [String]) {
        CodexExecutor.makeLaunchCommand(
            codexExecutableURL: codexExecutableURL,
            codexArguments: ["app-server", "--listen", listenURL],
            fileManager: fileManager
        )
    }
}

struct CodexAppServerExecutor {
    private let turnTimeoutSeconds: TimeInterval
    private let preflight: CodexAppServerPreflight
    private let makeTransport: () async throws -> CodexAppServerTransporting
    private let skillInputResolver: () -> [CodexAppServerSkillInput]
    private let dynamicToolSpecsResolver: () -> [CodexAppServerDynamicToolSpec]
    private let dynamicToolHandler: CodexAppServerDynamicToolHandler
    private let traceHandler: CodexAppServerTraceHandler
    private let approvalHandler: (CodexAppServerApprovalRequest) async -> CodexAppServerApprovalDecision

    init(
        turnTimeoutSeconds: TimeInterval = 120,
        preflight: @escaping CodexAppServerPreflight = { _ in .completed("No preflight configured.") },
        makeTransport: @escaping () async throws -> CodexAppServerTransporting = {
            try await CodexAppServerProcessTransport.make()
        },
        skillInputResolver: @escaping () -> [CodexAppServerSkillInput] = {
            CodexAppServerSkillInputResolver.desktopActionSkillInputs()
        },
        dynamicToolSpecsResolver: @escaping () -> [CodexAppServerDynamicToolSpec] = { [] },
        dynamicToolHandler: @escaping CodexAppServerDynamicToolHandler = { request in
            CodexAppServerDynamicToolCallResult(
                success: false,
                contentText: "Unsupported dynamic tool: \(request.namespace.map { "\($0)." } ?? "")\(request.tool)"
            )
        },
        traceHandler: @escaping CodexAppServerTraceHandler = { _ in },
        approvalHandler: @escaping (CodexAppServerApprovalRequest) async -> CodexAppServerApprovalDecision
    ) {
        self.turnTimeoutSeconds = turnTimeoutSeconds
        self.preflight = preflight
        self.makeTransport = makeTransport
        self.skillInputResolver = skillInputResolver
        self.dynamicToolSpecsResolver = dynamicToolSpecsResolver
        self.dynamicToolHandler = dynamicToolHandler
        self.traceHandler = traceHandler
        self.approvalHandler = approvalHandler
    }

    func runDesktopAction(prompt: String, cwd: String) async -> WorkspaceCommandResult {
        guard turnTimeoutSeconds > 0 else {
            return WorkspaceCommandResult(summary: "Codex App Server command timed out.", status: .failed)
        }

        let traceBuffer = CodexAppServerTraceBuffer()
        guard let preflightResult = await runPreflight(prompt: prompt, timeoutSeconds: turnTimeoutSeconds) else {
            recordTrace(.preflight("timed out after \(formattedSeconds(turnTimeoutSeconds))s"), to: traceBuffer)
            return WorkspaceCommandResult(
                summary: "Codex App Server preflight timed out." + traceBuffer.diagnosticSuffix(),
                status: .failed
            )
        }
        switch preflightResult {
        case .completed(let detail):
            recordTrace(.preflight(detail), to: traceBuffer)
        case .warning(let detail):
            recordTrace(.preflight("warning: \(detail)"), to: traceBuffer)
        case .failed(let detail):
            recordTrace(.preflight("failed: \(detail)"), to: traceBuffer)
            return WorkspaceCommandResult(
                summary: detail + traceBuffer.diagnosticSuffix(),
                status: .failed
            )
        }

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
                            cwd: cwd,
                            skillInputs: skillInputResolver()
                        ),
                        to: transport,
                        traceBuffer: traceBuffer
                    )
                case .agentMessageDelta(let delta):
                    finalText += delta
                case .toolCallCompleted(let status, let failureMessage):
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
                    let result = await dynamicToolHandler(request)
                    recordTrace(
                        .dynamicToolCompleted("\(request.traceIdentifier):success=\(result.success)"),
                        to: traceBuffer
                    )
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

    private func runPreflight(
        prompt: String,
        timeoutSeconds: TimeInterval
    ) async -> CodexAppServerPreflightResult? {
        let state = CodexAppServerPreflightRaceState()
        var preflightTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?

        let result = await withCheckedContinuation { continuation in
            preflightTask = Task { [preflight] in
                let result = await preflight(prompt)
                state.resume(with: result, continuation: continuation)
            }
            timeoutTask = Task {
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                state.resume(with: nil, continuation: continuation)
            }
        }

        preflightTask?.cancel()
        timeoutTask?.cancel()
        return result
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
        case .toolCallCompleted(let status, _):
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

    private func formattedSeconds(_ seconds: TimeInterval) -> String {
        if seconds.rounded() == seconds {
            return String(Int(seconds))
        }
        return String(format: "%.3f", seconds)
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

private final class CodexAppServerPreflightRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        with result: CodexAppServerPreflightResult?,
        continuation: CheckedContinuation<CodexAppServerPreflightResult?, Never>
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !didResume else { return }
        didResume = true
        continuation.resume(returning: result)
    }
}

private actor CodexAppServerProcessTransport: CodexAppServerTransporting {
    private let process: Process
    private let standardInput: FileHandle
    private let standardOutput: FileHandle
    private let standardError: FileHandle
    private let webSocketTask: URLSessionWebSocketTask
    private var outputDrainTask: Task<Void, Never>?
    private var errorDrainTask: Task<Void, Never>?

    static func make(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) async throws -> CodexAppServerProcessTransport {
        guard let codexExecutableURL = CodexExecutableLocator(
            fileManager: fileManager,
            defaults: defaults
        ).resolve() else {
            throw CodexAppServerProcessTransportError.missingCodexExecutable
        }

        var lastError: Error?
        for _ in 0..<3 {
            do {
                return try await make(
                    codexExecutableURL: codexExecutableURL,
                    fileManager: fileManager
                )
            } catch {
                lastError = error
            }
        }

        throw lastError ?? CodexAppServerProcessTransportError.startupTimedOut
    }

    private static func make(
        codexExecutableURL: URL,
        fileManager: FileManager
    ) async throws -> CodexAppServerProcessTransport {
        let port = Int.random(in: 45_000...60_000)
        let listenURL = "ws://127.0.0.1:\(port)"
        let launch = CodexAppServerLaunch.make(
            codexExecutableURL: codexExecutableURL,
            listenURL: listenURL,
            fileManager: fileManager
        )
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.executableURL = launch.executableURL
        process.arguments = launch.arguments
        process.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
        process.environment = WorkspaceProcessRunner.launchEnvironment()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()

        let standardOutput = outputPipe.fileHandleForReading
        let standardError = errorPipe.fileHandleForReading
        let outputDrainTask = drain(standardOutput)
        let errorDrainTask = drain(standardError)

        do {
            try await waitUntilReady(port: port)
        } catch {
            outputDrainTask.cancel()
            errorDrainTask.cancel()
            try? inputPipe.fileHandleForWriting.close()
            try? standardOutput.close()
            try? standardError.close()
            if process.isRunning {
                process.terminate()
            }
            throw error
        }

        let webSocketTask = URLSession.shared.webSocketTask(
            with: URL(string: listenURL)!
        )
        webSocketTask.resume()

        return CodexAppServerProcessTransport(
            process: process,
            standardInput: inputPipe.fileHandleForWriting,
            standardOutput: standardOutput,
            standardError: standardError,
            webSocketTask: webSocketTask,
            outputDrainTask: outputDrainTask,
            errorDrainTask: errorDrainTask
        )
    }

    private init(
        process: Process,
        standardInput: FileHandle,
        standardOutput: FileHandle,
        standardError: FileHandle,
        webSocketTask: URLSessionWebSocketTask,
        outputDrainTask: Task<Void, Never>,
        errorDrainTask: Task<Void, Never>
    ) {
        self.process = process
        self.standardInput = standardInput
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.webSocketTask = webSocketTask
        self.outputDrainTask = outputDrainTask
        self.errorDrainTask = errorDrainTask
    }

    private static func drain(_ fileHandle: FileHandle) -> Task<Void, Never> {
        Task.detached {
            do {
                for try await _ in fileHandle.bytes {}
            } catch {}
        }
    }

    private static func waitUntilReady(port: Int) async throws {
        let deadline = Date().addingTimeInterval(5)
        let readyURL = URL(string: "http://127.0.0.1:\(port)/readyz")!

        while Date() < deadline {
            do {
                var request = URLRequest(url: readyURL)
                request.timeoutInterval = 0.2
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    return
                }
            } catch {}

            try await Task.sleep(for: .milliseconds(100))
        }

        throw CodexAppServerProcessTransportError.startupTimedOut
    }

    func send(line: String) async throws {
        let message = line.trimmingCharacters(in: .newlines)
        try await webSocketTask.send(.string(message))
    }

    func nextLine() async throws -> String? {
        let message = try await webSocketTask.receive()
        switch message {
        case .string(let line):
            return line
        case .data(let data):
            guard let line = String(data: data, encoding: .utf8) else {
                throw CodexAppServerProtocolError.invalidUTF8
            }
            return line
        @unknown default:
            throw CodexAppServerProcessTransportError.invalidWebSocketMessage
        }
    }

    func terminate() async {
        outputDrainTask?.cancel()
        errorDrainTask?.cancel()
        webSocketTask.cancel(with: .goingAway, reason: nil)
        try? standardInput.close()
        try? standardOutput.close()
        try? standardError.close()

        if process.isRunning {
            process.terminate()
        }
    }
}

private enum CodexAppServerProcessTransportError: Error, LocalizedError {
    case missingCodexExecutable
    case startupTimedOut
    case invalidWebSocketMessage

    var errorDescription: String? {
        switch self {
        case .missingCodexExecutable:
            return "Codex executable was not found."
        case .startupTimedOut:
            return "Codex App Server did not become ready."
        case .invalidWebSocketMessage:
            return "Codex App Server sent an unsupported WebSocket message."
        }
    }
}

private extension CodexAppServerDynamicToolCallRequest {
    var traceIdentifier: String {
        "\(requestID):\(namespace.map { "\($0)." } ?? "")\(tool)"
    }
}
