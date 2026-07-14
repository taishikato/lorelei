//
//  LoreleiMemoryStore.swift
//  Lorelei
//
//  Local Markdown storage for durable and workspace-specific memory.
//

import CryptoKit
import Foundation

final class LoreleiMemoryStore: @unchecked Sendable {
    private static let maximumFileSize = 16_384

    let rootDirectoryURL: URL

    private let lock = NSLock()

    init(rootDirectoryURL: URL? = nil) {
        self.rootDirectoryURL = rootDirectoryURL ?? Self.defaultRootDirectoryURL()
    }

    func loadProfile() -> String? {
        withLock {
            load(profileURL)
        }
    }

    func loadVolatile(forWorkspacePath workspacePath: String?) -> String? {
        withLock {
            load(volatileURL(forWorkspacePath: workspacePath))
        }
    }

    func writeProfile(_ content: String) throws {
        try withLock {
            try write(content, to: profileURL)
        }
    }

    func writeVolatile(_ content: String, forWorkspacePath workspacePath: String?) throws {
        try withLock {
            try write(content, to: volatileURL(forWorkspacePath: workspacePath))
        }
    }

    func createRootDirectory() throws {
        try withLock {
            try FileManager.default.createDirectory(
                at: rootDirectoryURL,
                withIntermediateDirectories: true
            )
        }
    }

    func clearAll() throws {
        try withLock {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: rootDirectoryURL.path) else {
                return
            }
            try fileManager.removeItem(at: rootDirectoryURL)
        }
    }

    private static func defaultRootDirectoryURL() -> URL {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("Lorelei", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

    private var profileURL: URL {
        rootDirectoryURL.appendingPathComponent("PROFILE.md", isDirectory: false)
    }

    private func volatileURL(forWorkspacePath workspacePath: String?) -> URL {
        rootDirectoryURL
            .appendingPathComponent("workspaces", isDirectory: true)
            .appendingPathComponent(workspaceBucket(for: workspacePath), isDirectory: true)
            .appendingPathComponent("VOLATILE.md", isDirectory: false)
    }

    private func workspaceBucket(for workspacePath: String?) -> String {
        guard let workspacePath else {
            return "default"
        }
        let digest = SHA256.hash(data: Data(workspacePath.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func load(_ fileURL: URL) -> String? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return String(decoding: truncatedUTF8Data(content), as: UTF8.self)
    }

    private func write(_ content: String, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try truncatedUTF8Data(content).write(to: fileURL, options: .atomic)
    }

    private func truncatedUTF8Data(_ content: String) -> Data {
        let data = Data(content.utf8)
        guard data.count > Self.maximumFileSize else {
            return data
        }

        var endIndex = Self.maximumFileSize
        while endIndex > 0, data[endIndex] & 0b1100_0000 == 0b1000_0000 {
            endIndex -= 1
        }
        return data.prefix(endIndex)
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
