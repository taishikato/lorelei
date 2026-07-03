//
//  CodexExecutor.swift
//  Lorelei
//
//  Locates and launches the Codex CLI for Lorelei's app-server transport.
//

import Foundation

struct CodexExecutor {
    static let executablePathDefaultsKey = CodexExecutableLocator.executablePathDefaultsKey

    static func makeLaunchCommand(
        codexExecutableURL: URL,
        codexArguments: [String],
        fileManager: FileManager = .default
    ) -> (executableURL: URL, arguments: [String]) {
        let resolvedScriptURL = codexExecutableURL.resolvingSymlinksInPath()
        if let nodeURL = resolveNodeExecutable(nearCodex: codexExecutableURL, fileManager: fileManager) {
            return (
                executableURL: nodeURL,
                arguments: [resolvedScriptURL.path] + codexArguments
            )
        }

        return (executableURL: codexExecutableURL, arguments: codexArguments)
    }

    private static func resolveNodeExecutable(
        nearCodex codexURL: URL,
        fileManager: FileManager
    ) -> URL? {
        let candidates = [
            codexURL.deletingLastPathComponent().appendingPathComponent("node"),
            codexURL.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("node")
        ]

        for candidate in candidates {
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}
