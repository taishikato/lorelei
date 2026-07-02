//
//  CodexExecutableLocator.swift
//  Lorelei
//
//  Resolves the local Codex CLI executable for Codex-backed workflows.
//

import Foundation

struct CodexExecutableLocator {
    static let executablePathDefaultsKey = "codexExecutablePath"

    private let fileManager: FileManager
    private let defaults: UserDefaults

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
    }

    func resolve() -> URL? {
        if let overridePath = defaults.string(forKey: Self.executablePathDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty,
           let url = executableURLIfValid(path: overridePath) {
            return url
        }

        let pathCandidates = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .map(String.init)
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }

        let fixedCandidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]

        for candidate in pathCandidates + fixedCandidates + nvmCodexCandidates() {
            if let url = executableURLIfValid(path: candidate) {
                return url
            }
        }

        return nil
    }

    private func executableURLIfValid(path: String) -> URL? {
        let expandedPath = NSString(string: path).expandingTildeInPath
        guard fileManager.isExecutableFile(atPath: expandedPath) else {
            return nil
        }
        return URL(fileURLWithPath: expandedPath)
    }

    private func nvmCodexCandidates() -> [String] {
        let versionsURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)

        guard let versionNames = try? fileManager.contentsOfDirectory(atPath: versionsURL.path) else {
            return []
        }

        return versionNames.map {
            versionsURL
                .appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("codex")
                .path
        }
    }
}
