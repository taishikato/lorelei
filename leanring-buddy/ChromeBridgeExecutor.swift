import Foundation

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
}
