import Foundation
import Darwin

enum ChromeBridgeCommand: Equatable, Sendable {
    case ping
    case googleSearch(query: String)
}

struct ChromeBridgeRequest: Equatable, Sendable {
    let id: String
    let command: ChromeBridgeCommand
}

struct ChromeBridgeResponse: Codable, Equatable, Sendable {
    let id: String?
    let ok: Bool
    let type: String?
    let title: String?
    let url: String?
    let searchValue: String?
    let error: String?

    var summary: String {
        if ok, type == "googleSearch", let searchValue, !searchValue.isEmpty {
            return "Chrome Google search opened: \(searchValue)"
        }

        if let error, !error.isEmpty {
            return "Chrome bridge failed: \(error)"
        }

        return ok ? "Chrome bridge command completed." : "Chrome bridge command failed."
    }
}

struct ChromeBridgeCommandPlanner {
    static func command(for prompt: String) -> ChromeBridgeCommand? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedPrompt = trimmedPrompt.lowercased()
        let supportedPrefixes = [
            "search google for ",
            "google search for ",
            "search for ",
            "look up ",
        ]

        for prefix in supportedPrefixes where lowercasedPrompt.hasPrefix(prefix) {
            let queryStartIndex = trimmedPrompt.index(trimmedPrompt.startIndex, offsetBy: prefix.count)
            let query = String(trimmedPrompt[queryStartIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return query.isEmpty ? nil : .googleSearch(query: query)
        }

        return nil
    }
}

struct ChromeBridgeLineCodec {
    struct EncodedRequest: Codable, Equatable, Sendable {
        let id: String
        let type: String
        let query: String?
    }

    static func encode(_ request: ChromeBridgeRequest) throws -> String {
        let encodedRequest = EncodedRequest(request: request)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        do {
            let data = try encoder.encode(encodedRequest)
            guard let line = String(data: data, encoding: .utf8) else {
                throw ChromeBridgeExecutorError.encodingFailed
            }
            return line + "\n"
        } catch let error as ChromeBridgeExecutorError {
            throw error
        } catch {
            throw ChromeBridgeExecutorError.encodingFailed
        }
    }

    static func decodeResponse(_ line: String) throws -> ChromeBridgeResponse {
        guard let data = line.data(using: .utf8) else {
            throw ChromeBridgeExecutorError.responseDecodingFailed
        }

        do {
            return try JSONDecoder().decode(ChromeBridgeResponse.self, from: data)
        } catch {
            throw ChromeBridgeExecutorError.responseDecodingFailed
        }
    }
}

private extension ChromeBridgeLineCodec.EncodedRequest {
    init(request: ChromeBridgeRequest) {
        switch request.command {
        case .ping:
            self.init(id: request.id, type: "ping", query: nil)
        case .googleSearch(let query):
            self.init(id: request.id, type: "googleSearch", query: query)
        }
    }
}

enum ChromeBridgeExecutorError: Error, Equatable {
    case encodingFailed
    case unsupportedCommand
    case socketUnavailable(String)
    case responseDecodingFailed
    case timedOut
    case responseTooLarge
}

extension ChromeBridgeExecutorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Chrome bridge request could not be encoded."
        case .unsupportedCommand:
            return "Chrome bridge does not support that browser action yet."
        case .socketUnavailable(let message):
            return message
        case .responseDecodingFailed:
            return "Chrome bridge response could not be decoded."
        case .timedOut:
            return "Chrome bridge timed out."
        case .responseTooLarge:
            return "Chrome bridge response was too large."
        }
    }
}

protocol ChromeBridgeClienting: Sendable {
    func send(line: String) async throws -> String
}

struct ChromeBridgeExecutor: Sendable {
    private let client: ChromeBridgeClienting
    private let idGenerator: @Sendable () -> String

    init(
        client: ChromeBridgeClienting = ChromeBridgeSocketClient(),
        idGenerator: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.client = client
        self.idGenerator = idGenerator
    }

    func run(prompt: String) async -> WorkspaceCommandResult {
        guard let command = ChromeBridgeCommandPlanner.command(for: prompt) else {
            return WorkspaceCommandResult(
                summary: "Chrome bridge does not support that browser action yet.",
                status: .failed
            )
        }

        do {
            let request = ChromeBridgeRequest(id: idGenerator(), command: command)
            let requestLine = try ChromeBridgeLineCodec.encode(request)
            let responseLine = try await client.send(line: requestLine)
            let response = try ChromeBridgeLineCodec.decodeResponse(responseLine)
            return WorkspaceCommandResult(
                summary: response.summary,
                status: response.ok ? .succeeded : .failed
            )
        } catch {
            return WorkspaceCommandResult(
                summary: "Chrome bridge failed: \(error.localizedDescription)",
                status: .failed
            )
        }
    }
}

struct ChromeBridgeSocketClient: ChromeBridgeClienting {
    static var defaultSocketPath: String {
        "/tmp/lorelei-chrome-bridge-\(getuid()).sock"
    }

    private let socketPath: String
    private let timeoutSeconds: TimeInterval
    private let maxResponseBytes: Int
    private let queue = DispatchQueue(label: "dev.taishi.lorelei.chrome-bridge-socket")

    init(
        socketPath: String = ChromeBridgeSocketClient.defaultSocketPath,
        timeoutSeconds: TimeInterval = 20,
        maxResponseBytes: Int = 1_048_576
    ) {
        self.socketPath = socketPath
        self.timeoutSeconds = timeoutSeconds
        self.maxResponseBytes = maxResponseBytes
    }

    func send(line: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try sendBlocking(
                        line: line,
                        socketPath: socketPath,
                        timeoutSeconds: timeoutSeconds,
                        maxResponseBytes: maxResponseBytes
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private func sendBlocking(
    line: String,
    socketPath: String,
    timeoutSeconds: TimeInterval,
    maxResponseBytes: Int
) throws -> String {
    let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else {
        throw ChromeBridgeExecutorError.socketUnavailable(String(cString: strerror(errno)))
    }
    defer { close(fileDescriptor) }

    try setSocketTimeout(timeoutSeconds, on: fileDescriptor)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < pathCapacity else {
        throw ChromeBridgeExecutorError.socketUnavailable("Socket path is too long.")
    }

    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { buffer in
            for index in 0..<pathBytes.count {
                buffer[index] = CChar(bitPattern: pathBytes[index])
            }
            buffer[pathBytes.count] = 0
        }
    }

    let connectResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            connect(fileDescriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connectResult == 0 else {
        throw ChromeBridgeExecutorError.socketUnavailable(String(cString: strerror(errno)))
    }

    try writeAll(line, to: fileDescriptor)
    return try readResponseLine(from: fileDescriptor, maxResponseBytes: maxResponseBytes)
}

private func setSocketTimeout(_ timeoutSeconds: TimeInterval, on fileDescriptor: Int32) throws {
    let safeTimeout = max(timeoutSeconds, 0.001)
    let seconds = floor(safeTimeout)
    let microseconds = (safeTimeout - seconds) * 1_000_000
    var timeout = timeval(
        tv_sec: __darwin_time_t(seconds),
        tv_usec: __darwin_suseconds_t(microseconds)
    )

    let receiveResult = setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
    guard receiveResult == 0 else {
        throw ChromeBridgeExecutorError.socketUnavailable(String(cString: strerror(errno)))
    }

    let sendResult = setsockopt(
        fileDescriptor,
        SOL_SOCKET,
        SO_SNDTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
    guard sendResult == 0 else {
        throw ChromeBridgeExecutorError.socketUnavailable(String(cString: strerror(errno)))
    }
}

private func writeAll(_ line: String, to fileDescriptor: Int32) throws {
    let bytes = Array(line.utf8)
    try bytes.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var bytesWritten = 0
        while bytesWritten < bytes.count {
            let result = write(
                fileDescriptor,
                baseAddress.advanced(by: bytesWritten),
                bytes.count - bytesWritten
            )
            if result > 0 {
                bytesWritten += result
                continue
            }

            if result == 0 {
                throw ChromeBridgeExecutorError.socketUnavailable("Chrome bridge closed the connection.")
            }

            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                throw ChromeBridgeExecutorError.timedOut
            default:
                throw ChromeBridgeExecutorError.socketUnavailable(String(cString: strerror(errno)))
            }
        }
    }
}

private func readResponseLine(from fileDescriptor: Int32, maxResponseBytes: Int) throws -> String {
    var collectedBytes: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 4096)

    while true {
        let bytesRead = read(fileDescriptor, &buffer, buffer.count)

        if bytesRead == 0 {
            throw ChromeBridgeExecutorError.socketUnavailable("Chrome bridge closed the connection.")
        }

        if bytesRead < 0 {
            switch errno {
            case EINTR:
                continue
            case EAGAIN, EWOULDBLOCK:
                throw ChromeBridgeExecutorError.timedOut
            default:
                throw ChromeBridgeExecutorError.socketUnavailable(String(cString: strerror(errno)))
            }
        }

        guard bytesRead > 0 else {
            throw ChromeBridgeExecutorError.socketUnavailable(String(cString: strerror(errno)))
        }

        for byte in buffer.prefix(bytesRead) {
            if byte == 10 {
                return String(decoding: collectedBytes, as: UTF8.self)
            }
            collectedBytes.append(byte)
            if collectedBytes.count > maxResponseBytes {
                throw ChromeBridgeExecutorError.responseTooLarge
            }
        }
    }
}
