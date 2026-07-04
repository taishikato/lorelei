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

    nonisolated private init(_ logLine: String) {
        self.logLine = logLine
    }

    nonisolated static func inbound(_ detail: String) -> Self {
        Self("inbound \(detail)")
    }

    nonisolated static func outbound(_ detail: String) -> Self {
        Self("outbound \(detail)")
    }

    nonisolated static func dynamicToolStarted(_ detail: String) -> Self {
        Self("dynamicToolStarted \(detail)")
    }

    nonisolated static func dynamicToolCompleted(_ detail: String) -> Self {
        Self("dynamicToolCompleted \(detail)")
    }
}

typealias CodexAppServerTraceHandler = @Sendable (_ event: CodexAppServerTraceEvent) -> Void

enum CodexAppServerSessionLifecycleEvent: Sendable {
    case started
    case reused
    case reset

    var logLine: String {
        switch self {
        case .started:
            return "session started"
        case .reused:
            return "session reused"
        case .reset:
            return "session reset"
        }
    }
}

typealias CodexAppServerSessionLifecycleHandler = @Sendable (_ event: CodexAppServerSessionLifecycleEvent) -> Void

final class CodexAppServerTraceBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let maxLines: Int
    nonisolated(unsafe) private var lines: [String] = []

    init(maxLines: Int = 30) {
        self.maxLines = maxLines
    }

    nonisolated func record(_ event: CodexAppServerTraceEvent) {
        lock.lock()
        defer { lock.unlock() }

        lines.append(event.logLine)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    nonisolated func diagnosticSuffix() -> String {
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

actor CodexAppServerSessionStore {
    struct LiveSession {
        let transport: CodexAppServerTransporting
        let threadID: String
        let cwd: String
        let connectionToken: Int
    }

    typealias TraceRecorder = @Sendable (CodexAppServerTraceEvent, CodexAppServerTraceBuffer) -> Void

    private let makeTransport: () async throws -> CodexAppServerTransporting
    private let onLifecycleEvent: CodexAppServerSessionLifecycleHandler
    private var currentTransport: CodexAppServerTransporting?
    private var currentConnectionToken = 0
    private var liveSession: LiveSession?
    private var nextID = 1

    init(
        makeTransport: @escaping () async throws -> CodexAppServerTransporting,
        onLifecycleEvent: @escaping CodexAppServerSessionLifecycleHandler = { _ in }
    ) {
        self.makeTransport = makeTransport
        self.onLifecycleEvent = onLifecycleEvent
    }

    var hasLiveSession: Bool {
        liveSession != nil
    }

    func ensureSession(
        cwd: String,
        dynamicTools: [CodexAppServerDynamicToolSpec],
        traceBuffer: CodexAppServerTraceBuffer,
        recordTrace: TraceRecorder,
        onTransportReady: @Sendable (CodexAppServerTransporting) -> Void
    ) async throws -> LiveSession {
        if let liveSession, liveSession.cwd == cwd {
            onTransportReady(liveSession.transport)
            onLifecycleEvent(.reused)
            return liveSession
        }

        if let currentTransport {
            await currentTransport.terminate()
            onLifecycleEvent(.reset)
        }
        currentTransport = nil
        liveSession = nil
        currentConnectionToken += 1
        nextID = 1

        let transport: CodexAppServerTransporting
        do {
            transport = try await makeTransport()
        } catch {
            throw CodexAppServerSessionStoreError.transportStartFailed(error.localizedDescription)
        }
        currentTransport = transport
        let connectionToken = currentConnectionToken
        onTransportReady(transport)

        let initializeID = takeNextRequestID()
        try await send(
            CodexAppServerProtocol.initializeRequest(id: initializeID),
            to: transport,
            traceBuffer: traceBuffer,
            recordTrace: recordTrace
        )
        try ensureConnectionIsCurrent(connectionToken)

        while let line = try await transport.nextLine() {
            try ensureConnectionIsCurrent(connectionToken)
            let event = try await CodexAppServerProtocol.parseInboundLine(line)
            recordTrace(.inbound(codexAppServerTraceDetail(for: event)), traceBuffer)
            switch event {
            case .response(let requestID) where requestID == initializeID:
                try await send(
                    CodexAppServerProtocol.initializedNotification(),
                    to: transport,
                    traceBuffer: traceBuffer,
                    recordTrace: recordTrace
                )
                try ensureConnectionIsCurrent(connectionToken)
                let threadStartID = takeNextRequestID()
                try await send(
                    CodexAppServerProtocol.threadStartRequest(
                        id: threadStartID,
                        cwd: cwd,
                        dynamicTools: dynamicTools
                    ),
                    to: transport,
                    traceBuffer: traceBuffer,
                    recordTrace: recordTrace
                )
                try ensureConnectionIsCurrent(connectionToken)
            case .threadStarted(_, let threadID):
                let session = LiveSession(
                    transport: transport,
                    threadID: threadID,
                    cwd: cwd,
                    connectionToken: connectionToken
                )
                liveSession = session
                onLifecycleEvent(.started)
                return session
            case .unsupportedServerRequest(_, let method):
                throw CodexAppServerSessionStoreError.unsupportedClientMethod(method)
            case .error(_, let message):
                throw CodexAppServerSessionStoreError.serverError(message)
            case .ignored:
                break
            default:
                break
            }
        }

        throw CodexAppServerSessionStoreError.closedBeforeThreadStart
    }

    func nextRequestID() -> Int {
        takeNextRequestID()
    }

    func invalidate() async {
        await invalidateCurrentConnection(onlyIfToken: currentConnectionToken)
    }

    func invalidate(onlyIfToken connectionToken: Int) async {
        await invalidateCurrentConnection(onlyIfToken: connectionToken)
    }

    func invalidateCurrentConnectionForTimeout() async {
        guard currentTransport != nil else {
            return
        }
        await invalidate(onlyIfToken: currentConnectionToken)
    }

    private func invalidateCurrentConnection(onlyIfToken connectionToken: Int) async {
        guard currentConnectionToken == connectionToken else {
            return
        }

        let hadConnection = currentTransport != nil || liveSession != nil
        if let currentTransport {
            await currentTransport.terminate()
        }

        guard currentConnectionToken == connectionToken else {
            return
        }
        currentTransport = nil
        liveSession = nil
        currentConnectionToken += 1
        nextID = 1
        if hadConnection {
            onLifecycleEvent(.reset)
        }
    }

    private func takeNextRequestID() -> Int {
        let requestID = nextID
        nextID += 1
        return requestID
    }

    private func ensureConnectionIsCurrent(_ connectionToken: Int) throws {
        guard currentConnectionToken == connectionToken else {
            throw CodexAppServerSessionStoreError.sessionInvalidated
        }
    }

    private func send(
        _ message: [String: Any],
        to transport: CodexAppServerTransporting,
        traceBuffer: CodexAppServerTraceBuffer,
        recordTrace: TraceRecorder
    ) async throws {
        try await transport.send(line: CodexAppServerProtocol.encodeLine(message))
        recordTrace(.outbound(codexAppServerTraceDetail(forOutboundMessage: message)), traceBuffer)
    }
}

private enum CodexAppServerSessionStoreError: Error, LocalizedError {
    case closedBeforeThreadStart
    case sessionInvalidated
    case serverError(String)
    case transportStartFailed(String)
    case unsupportedClientMethod(String)

    var errorDescription: String? {
        switch self {
        case .closedBeforeThreadStart:
            return "Codex App Server did not start a thread."
        case .sessionInvalidated:
            return "Codex App Server session was invalidated."
        case .serverError(let message):
            return "Codex App Server error: \(message)"
        case .transportStartFailed(let message):
            return "Codex App Server failed to start: \(message)"
        case .unsupportedClientMethod(let method):
            return "Codex App Server requested unsupported client method: \(method)"
        }
    }
}

private struct CodexAppServerTurnAttemptResult {
    let commandResult: WorkspaceCommandResult
    let shouldRetryDeadSession: Bool

    static func finished(_ commandResult: WorkspaceCommandResult) -> Self {
        Self(commandResult: commandResult, shouldRetryDeadSession: false)
    }

    static func retry(_ commandResult: WorkspaceCommandResult) -> Self {
        Self(commandResult: commandResult, shouldRetryDeadSession: true)
    }
}

private actor CodexAppServerSteerRequestTracker {
    private var requestIDs = Set<Int>()

    func insert(_ requestID: Int) {
        requestIDs.insert(requestID)
    }

    func remove(_ requestID: Int) {
        requestIDs.remove(requestID)
    }

    func consume(_ requestID: Int) -> Bool {
        requestIDs.remove(requestID) != nil
    }
}

final class CodexAppServerExecutor {
    private let turnTimeoutSeconds: TimeInterval
    private let timeoutInterruptGraceSeconds: TimeInterval
    private let sessionStore: CodexAppServerSessionStore
    private let steerRequestTracker = CodexAppServerSteerRequestTracker()
    private let dynamicToolSpecsResolver: () -> [CodexAppServerDynamicToolSpec]
    private let dynamicToolHandler: CodexAppServerDynamicToolHandler
    private let traceHandler: CodexAppServerTraceHandler
    private let progressHandler: CodexAppServerTurnProgressHandler
    private let onTransportReady: @Sendable (CodexAppServerTransporting) -> Void
    private let approvalHandler: (CodexAppServerApprovalRequest) async -> CodexAppServerApprovalDecision

    init(
        turnTimeoutSeconds: TimeInterval = 300,
        timeoutInterruptGraceSeconds: TimeInterval = 5,
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
        onTransportReady: @escaping @Sendable (CodexAppServerTransporting) -> Void = { _ in },
        onSessionLifecycleEvent: @escaping CodexAppServerSessionLifecycleHandler = { _ in },
        approvalHandler: @escaping (CodexAppServerApprovalRequest) async -> CodexAppServerApprovalDecision
    ) {
        self.turnTimeoutSeconds = turnTimeoutSeconds
        self.timeoutInterruptGraceSeconds = timeoutInterruptGraceSeconds
        self.sessionStore = CodexAppServerSessionStore(
            makeTransport: makeTransport,
            onLifecycleEvent: onSessionLifecycleEvent
        )
        self.dynamicToolSpecsResolver = dynamicToolSpecsResolver
        self.dynamicToolHandler = dynamicToolHandler
        self.traceHandler = traceHandler
        self.progressHandler = progressHandler
        self.onTransportReady = onTransportReady
        self.approvalHandler = approvalHandler
    }

#if DEBUG
    var defaultedTurnTimeoutSecondsForTesting: TimeInterval {
        turnTimeoutSeconds
    }
#endif

    func runTurn(
        prompt: String,
        cwd: String,
        sandboxPolicy: String? = nil,
        extraInput: [CodexAppServerTurnInputItem] = [],
        removeLocalImageInputsAfterRun: Bool = false
    ) async -> WorkspaceCommandResult {
        defer {
            if removeLocalImageInputsAfterRun {
                for item in extraInput {
                    if case .localImage(let path) = item {
                        try? FileManager.default.removeItem(atPath: path)
                    }
                }
            }
        }
        defer {
            progressHandler(.turnEnded)
        }

        guard turnTimeoutSeconds > 0 else {
            return WorkspaceCommandResult(summary: "Codex App Server command timed out.", status: .failed)
        }

        let traceBuffer = CodexAppServerTraceBuffer()
        var lastFailure: WorkspaceCommandResult?

        for attempt in 0..<2 {
            let result = await runTurnAttempt(
                prompt: prompt,
                cwd: cwd,
                sandboxPolicy: sandboxPolicy,
                extraInput: extraInput,
                traceBuffer: traceBuffer,
                allowDeadSessionRetry: attempt == 0
            )
            if result.shouldRetryDeadSession {
                await sessionStore.invalidate()
                lastFailure = result.commandResult
                continue
            }
            return result.commandResult
        }

        return lastFailure ?? WorkspaceCommandResult(summary: "Codex App Server failed.", status: .failed)
    }

    func runDesktopAction(prompt: String, cwd: String) async -> WorkspaceCommandResult {
        await runTurn(prompt: prompt, cwd: cwd)
    }

    func runComputerUse(prompt: String, cwd: String) async -> WorkspaceCommandResult {
        await runDesktopAction(prompt: prompt, cwd: cwd)
    }

    func invalidateSession() async {
        await sessionStore.invalidate()
    }

    func reserveSteerRequestID() async -> Int {
        let requestID = await sessionStore.nextRequestID()
        await steerRequestTracker.insert(requestID)
        return requestID
    }

    func reserveRequestID() async -> Int {
        await sessionStore.nextRequestID()
    }

    func sendSteerRequest(
        id requestID: Int,
        threadID: String,
        expectedTurnID: String,
        prompt: String,
        transport: CodexAppServerTransporting
    ) async throws {
        do {
            try await send(
                CodexAppServerProtocol.turnSteerRequest(
                    id: requestID,
                    threadID: threadID,
                    expectedTurnID: expectedTurnID,
                    prompt: prompt
                ),
                to: transport,
                traceBuffer: CodexAppServerTraceBuffer()
            )
        } catch {
            await steerRequestTracker.remove(requestID)
            throw error
        }
    }

    func sendInterruptRequest(
        id requestID: Int,
        threadID: String,
        turnID: String,
        transport: CodexAppServerTransporting
    ) async throws {
        try await send(
            CodexAppServerProtocol.turnInterruptRequest(
                id: requestID,
                threadID: threadID,
                turnID: turnID
            ),
            to: transport,
            traceBuffer: CodexAppServerTraceBuffer()
        )
    }

    private func runTurnAttempt(
        prompt: String,
        cwd: String,
        sandboxPolicy: String?,
        extraInput: [CodexAppServerTurnInputItem],
        traceBuffer: CodexAppServerTraceBuffer,
        allowDeadSessionRetry: Bool
    ) async -> CodexAppServerTurnAttemptResult {
        let timeoutState = CodexAppServerTimeoutState()
        let timeoutTask = Task { [
            turnTimeoutSeconds,
            timeoutInterruptGraceSeconds,
            sessionStore,
            timeoutState,
            traceBuffer,
            traceHandler
        ] in
            do {
                try await Task.sleep(for: .seconds(turnTimeoutSeconds))
            } catch {
                return
            }
            await timeoutState.markTimedOut()
            guard let activeTurn = await timeoutState.activeTurn else {
                await sessionStore.invalidateCurrentConnectionForTimeout()
                return
            }

            do {
                let requestID = await sessionStore.nextRequestID()
                let message = CodexAppServerProtocol.turnInterruptRequest(
                    id: requestID,
                    threadID: activeTurn.threadID,
                    turnID: activeTurn.turnID
                )
                try await activeTurn.transport.send(line: CodexAppServerProtocol.encodeLine(message))
                traceBuffer.record(.outbound(codexAppServerTraceDetail(forOutboundMessage: message)))
                traceHandler(.outbound(codexAppServerTraceDetail(forOutboundMessage: message)))
            } catch {
                await sessionStore.invalidate(onlyIfToken: activeTurn.connectionToken)
                return
            }

            do {
                try await Task.sleep(for: .seconds(timeoutInterruptGraceSeconds))
            } catch {
                return
            }

            if await timeoutState.didTimeOut {
                await sessionStore.invalidate(onlyIfToken: activeTurn.connectionToken)
            }
        }
        defer { timeoutTask.cancel() }

        var isWaitingOnApproval = false
        var didReceiveTurnEvent = false

        do {
            let session = try await sessionStore.ensureSession(
                cwd: cwd,
                dynamicTools: dynamicToolSpecsResolver(),
                traceBuffer: traceBuffer,
                recordTrace: { [traceHandler] event, traceBuffer in
                    traceBuffer.record(event)
                    traceHandler(event)
                },
                onTransportReady: onTransportReady
            )

            if await timeoutState.didTimeOut {
                await sessionStore.invalidate(onlyIfToken: session.connectionToken)
                return .finished(timeoutResult(isWaitingOnApproval: isWaitingOnApproval, traceBuffer: traceBuffer))
            }

            do {
                try await send(
                    CodexAppServerProtocol.turnStartRequest(
                        id: await sessionStore.nextRequestID(),
                        threadID: session.threadID,
                        prompt: prompt,
                        cwd: cwd,
                        sandboxPolicy: sandboxPolicy,
                        extraInput: extraInput
                    ),
                    to: session.transport,
                    traceBuffer: traceBuffer
                )
            } catch {
                if await timeoutState.didTimeOut {
                    await sessionStore.invalidate(onlyIfToken: session.connectionToken)
                    return .finished(timeoutResult(isWaitingOnApproval: isWaitingOnApproval, traceBuffer: traceBuffer))
                }
                await sessionStore.invalidate()
                if allowDeadSessionRetry {
                    return .retry(
                        WorkspaceCommandResult(
                            summary: "Codex App Server failed: \(error.localizedDescription)",
                            status: .failed
                        )
                    )
                }
                return .finished(
                    WorkspaceCommandResult(
                        summary: "Codex App Server failed: \(error.localizedDescription)",
                        status: .failed
                    )
                )
            }

            var finalText = ""
            var pendingToolFailure: String?

            while let line = try await session.transport.nextLine() {
                let event = try CodexAppServerProtocol.parseInboundLine(line)
                didReceiveTurnEvent = true
                recordTrace(.inbound(codexAppServerTraceDetail(for: event)), to: traceBuffer)
                switch event {
                case .turnStarted(let threadID, let turnID):
                    await timeoutState.setActiveTurn(
                        threadID: threadID,
                        turnID: turnID,
                        transport: session.transport,
                        connectionToken: session.connectionToken
                    )
                    progressHandler(.turnStarted(threadID: threadID, turnID: turnID))
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
                        to: session.transport,
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
                        to: session.transport,
                        traceBuffer: traceBuffer
                    )
                case .unsupportedServerRequest(_, let method):
                    await sessionStore.invalidate()
                    return .finished(
                        WorkspaceCommandResult(
                            summary: "Codex App Server requested unsupported client method: \(method)",
                            status: .failed
                        )
                    )
                case .turnCompleted(let status):
                    await timeoutState.clearActiveTurn()
                    if await timeoutState.didTimeOut {
                        return .finished(timeoutResult(isWaitingOnApproval: isWaitingOnApproval, traceBuffer: traceBuffer))
                    }
                    if status == "completed" {
                        let summary = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let pendingToolFailure {
                            return .finished(
                                WorkspaceCommandResult(
                                    summary: summary.isEmpty ? pendingToolFailure : summary,
                                    status: .failed
                                )
                            )
                        }
                        return .finished(WorkspaceCommandResult(summary: summary.isEmpty ? "Codex completed." : summary))
                    }
                    return .finished(
                        WorkspaceCommandResult(
                            summary: "Stopped.",
                            status: .failed
                        )
                    )
                case .error(let requestID?, let message):
                    if await steerRequestTracker.consume(requestID) {
                        progressHandler(.steerFailed(requestID: requestID, message: message))
                        continue
                    }
                    await sessionStore.invalidate()
                    return .finished(WorkspaceCommandResult(summary: "Codex App Server error: \(message)", status: .failed))
                case .error(nil, let message):
                    await sessionStore.invalidate()
                    return .finished(WorkspaceCommandResult(summary: "Codex App Server error: \(message)", status: .failed))
                case .threadWaitingOnApproval(let waitingOnApproval):
                    isWaitingOnApproval = waitingOnApproval
                case .response, .threadStarted, .ignored:
                    break
                }

                if Task.isCancelled {
                    await sessionStore.invalidate(onlyIfToken: session.connectionToken)
                    return .finished(
                        WorkspaceCommandResult(summary: "Codex App Server command cancelled.", status: .cancelled)
                    )
                }
            }

            if await timeoutState.didTimeOut {
                await sessionStore.invalidate(onlyIfToken: session.connectionToken)
                return .finished(timeoutResult(isWaitingOnApproval: isWaitingOnApproval, traceBuffer: traceBuffer))
            }
            await sessionStore.invalidate()
            if !didReceiveTurnEvent, allowDeadSessionRetry {
                return .retry(
                    WorkspaceCommandResult(
                        summary: "Codex App Server closed before completing the turn.",
                        status: .failed
                    )
                )
            }
            return .finished(
                WorkspaceCommandResult(
                    summary: "Codex App Server closed before completing the turn.",
                    status: .failed
                )
            )
        } catch {
            if await timeoutState.didTimeOut {
                return .finished(timeoutResult(isWaitingOnApproval: isWaitingOnApproval, traceBuffer: traceBuffer))
            }
            await sessionStore.invalidate()
            if let sessionStoreError = error as? CodexAppServerSessionStoreError {
                return .finished(sessionStoreFailureResult(for: sessionStoreError, traceBuffer: traceBuffer))
            }
            if !didReceiveTurnEvent, allowDeadSessionRetry {
                return .retry(
                    WorkspaceCommandResult(
                        summary: "Codex App Server failed: \(error.localizedDescription)",
                        status: .failed
                    )
                )
            }
            return .finished(
                WorkspaceCommandResult(summary: "Codex App Server failed: \(error.localizedDescription)", status: .failed)
            )
        }
    }

    private func sessionStoreFailureResult(
        for error: CodexAppServerSessionStoreError,
        traceBuffer: CodexAppServerTraceBuffer
    ) -> WorkspaceCommandResult {
        let suffix: String
        switch error {
        case .transportStartFailed:
            suffix = traceBuffer.diagnosticSuffix()
        case .closedBeforeThreadStart, .sessionInvalidated, .serverError, .unsupportedClientMethod:
            suffix = ""
        }

        return WorkspaceCommandResult(
            summary: error.localizedDescription + suffix,
            status: .failed
        )
    }

    private func send(
        _ message: [String: Any],
        to transport: CodexAppServerTransporting,
        traceBuffer: CodexAppServerTraceBuffer
    ) async throws {
        try await transport.send(line: CodexAppServerProtocol.encodeLine(message))
        recordTrace(.outbound(codexAppServerTraceDetail(forOutboundMessage: message)), to: traceBuffer)
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

}

nonisolated private func codexAppServerTraceDetail(for event: CodexAppServerInboundEvent) -> String {
    switch event {
    case .response(let requestID):
        return "response#\(requestID)"
    case .threadStarted(let requestID, let threadID):
        return "threadStarted#\(requestID):\(threadID)"
    case .turnStarted(let threadID, let turnID):
        return "turnStarted:\(threadID):\(turnID)"
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
    case .error(let requestID, let message):
        if let requestID {
            return "error#\(requestID):\(message)"
        }
        return "error:\(message)"
    case .ignored:
        return "ignored"
    }
}

nonisolated private func codexAppServerTraceDetail(forOutboundMessage message: [String: Any]) -> String {
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

private extension CodexAppServerDynamicToolCallRequest {
    var displayName: String {
        "\(namespace.map { "\($0)." } ?? "")\(tool)"
    }
}

private actor CodexAppServerTimeoutState {
    struct ActiveTurn: Sendable {
        let threadID: String
        let turnID: String
        let transport: CodexAppServerTransporting
        let connectionToken: Int
    }

    private var timedOut = false
    private var currentActiveTurn: ActiveTurn?

    var didTimeOut: Bool {
        timedOut
    }

    var activeTurn: ActiveTurn? {
        currentActiveTurn
    }

    func markTimedOut() {
        timedOut = true
    }

    func setActiveTurn(
        threadID: String,
        turnID: String,
        transport: CodexAppServerTransporting,
        connectionToken: Int
    ) {
        currentActiveTurn = ActiveTurn(
            threadID: threadID,
            turnID: turnID,
            transport: transport,
            connectionToken: connectionToken
        )
    }

    func clearActiveTurn() {
        currentActiveTurn = nil
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
    nonisolated var traceIdentifier: String {
        "\(requestID):\(namespace.map { "\($0)." } ?? "")\(tool)"
    }
}
