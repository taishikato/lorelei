//
//  ComputerUsePluginLocator.swift
//  Lorelei
//
//  Discovers the ChatGPT.app-managed Codex Computer Use plugin installation
//  under ~/.codex/plugins/cache/openai-bundled/computer-use/. Lorelei never
//  bundles or redistributes the plugin: it only points codex at whatever the
//  user's own ChatGPT.app already installed. Any missing piece -> nil, and
//  desktop actions fall back to the in-house lorelei.* AX tools.
//

import Foundation

struct ComputerUsePluginInstallation: Equatable, Sendable {
    let version: String
    let pluginRootPath: String
    let mcpBinaryPath: String
    let skillPath: String
}

enum ComputerUsePluginLocator {
    static let skillName = "computer-use"

    private static let mcpBinaryRelativePath =
        "Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
    private static let skillRelativePath = "skills/computer-use/SKILL.md"

    static func defaultBaseDirectory(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/plugins/cache/openai-bundled/computer-use", isDirectory: true)
    }

    static func locate(
        baseDirectory: URL,
        fileManager: FileManager = .default
    ) -> ComputerUsePluginInstallation? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            return nil
        }
        let versionDirectories = entries.compactMap { entry -> String? in
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return entry.lastPathComponent
        }
        guard let version = highestVersion(versionDirectories) else { return nil }

        let root = baseDirectory.appendingPathComponent(version, isDirectory: true)
        let binary = root.appendingPathComponent(mcpBinaryRelativePath)
        let skill = root.appendingPathComponent(skillRelativePath)
        guard fileManager.fileExists(atPath: binary.path),
              fileManager.fileExists(atPath: skill.path) else {
            return nil
        }

        return ComputerUsePluginInstallation(
            version: version,
            pluginRootPath: root.path,
            mcpBinaryPath: binary.path,
            skillPath: skill.path
        )
    }

    /// Numeric-aware version pick matching `sort -V` for dotted-numeric names.
    static func highestVersion(_ versions: [String]) -> String? {
        versions
            .filter { !$0.hasPrefix(".") }
            .max { lhs, rhs in
                lhs.compare(rhs, options: .numeric) == .orderedAscending
            }
    }
}
