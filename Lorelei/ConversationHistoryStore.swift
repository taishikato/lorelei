//
//  ConversationHistoryStore.swift
//  Lorelei
//
//  Append-only JSONL storage for opt-in persistent conversation history.
//

import Foundation

struct ConversationHistoryRecord: Codable, Equatable, Sendable {
    let ts: String
    let role: String
    let text: String
}

final class ConversationHistoryStore: @unchecked Sendable {
    let rootDirectoryURL: URL
    let maxFileBytes: Int

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let timestampFormatter: ISO8601DateFormatter

    init(
        rootDirectoryURL: URL = ConversationHistoryStore.defaultRootDirectoryURL(),
        maxFileBytes: Int = 5_000_000
    ) {
        self.rootDirectoryURL = rootDirectoryURL
        self.maxFileBytes = maxFileBytes

        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        self.encoder = encoder
        self.decoder = JSONDecoder()

        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = timestampFormatter
    }

    func append(role: String, text: String) throws {
        try withLock {
            try createRootDirectoryIfNeeded()
            let record = ConversationHistoryRecord(
                ts: timestampFormatter.string(from: Date()),
                role: role,
                text: text
            )
            var lineData = try encoder.encode(record)
            lineData.append(contentsOf: "\n".utf8)

            if FileManager.default.fileExists(atPath: historyFileURL.path) {
                let handle = try FileHandle(forWritingTo: historyFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: lineData)
            } else {
                try lineData.write(to: historyFileURL, options: .atomic)
            }

            try trimIfNeeded()
        }
    }

    func readAll() throws -> [ConversationHistoryRecord] {
        try withLock {
            guard FileManager.default.fileExists(atPath: historyFileURL.path) else {
                return []
            }
            let contents = try String(contentsOf: historyFileURL, encoding: .utf8)
            guard !contents.isEmpty else {
                return []
            }

            return contents
                .split(separator: "\n", omittingEmptySubsequences: true)
                .compactMap { line in
                    guard let data = line.data(using: .utf8) else {
                        return nil
                    }
                    return try? decoder.decode(ConversationHistoryRecord.self, from: data)
                }
        }
    }

    func clear() throws {
        try withLock {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: historyFileURL.path) else {
                return
            }
            try fileManager.removeItem(at: historyFileURL)
        }
    }

    static func defaultRootDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("Lorelei", isDirectory: true)
            .appendingPathComponent("history", isDirectory: true)
    }

    private var historyFileURL: URL {
        rootDirectoryURL.appendingPathComponent("history.jsonl", isDirectory: false)
    }

    private func createRootDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(
            at: rootDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func trimIfNeeded() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: historyFileURL.path) else {
            return
        }
        let attributes = try fileManager.attributesOfItem(atPath: historyFileURL.path)
        let fileSize = attributes[.size] as? Int ?? 0
        guard fileSize > maxFileBytes else {
            return
        }

        let contents = try String(contentsOf: historyFileURL, encoding: .utf8)
        let lines = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else {
            return
        }

        let targetBytes = maxFileBytes / 2
        var kept: [String] = []
        var keptBytes = 0
        for line in lines.reversed() {
            let lineBytes = line.utf8.count + 1
            if !kept.isEmpty, keptBytes + lineBytes > targetBytes {
                break
            }
            kept.append(line)
            keptBytes += lineBytes
        }
        kept.reverse()

        let rewritten = kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
        try Data(rewritten.utf8).write(to: historyFileURL, options: .atomic)
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
