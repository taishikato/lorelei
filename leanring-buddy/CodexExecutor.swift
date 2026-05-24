//
//  CodexExecutor.swift
//  leanring-buddy
//
//  Runs local Codex CLI requests for Lorelei.
//

import Foundation

enum CodexExecutionMode: Equatable, Sendable {
    case readOnly
    case workspaceWrite

    var sandboxArgument: String {
        switch self {
        case .readOnly:
            return "read-only"
        case .workspaceWrite:
            return "workspace-write"
        }
    }
}

typealias WorkspaceProcessRun = @MainActor (
    _ executableURL: URL,
    _ arguments: [String],
    _ currentDirectoryURL: URL,
    _ timeoutSeconds: TimeInterval,
    _ prelaunchDelay: TimeInterval,
    _ onLaunch: (@Sendable () -> Void)?
) async -> WorkspaceProcessExecution

struct CodexExecutor {
    static let executablePathDefaultsKey = "codexExecutablePath"

    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let commandTimeoutSeconds: TimeInterval
    private let codexExecutableResolver: (() -> URL?)?
    private let commandRunner: WorkspaceProcessRun

    init(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        commandTimeoutSeconds: TimeInterval = 120,
        codexExecutableResolver: (() -> URL?)? = nil,
        commandRunner: WorkspaceProcessRun? = nil
    ) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.commandTimeoutSeconds = commandTimeoutSeconds
        self.codexExecutableResolver = codexExecutableResolver

        if let commandRunner {
            self.commandRunner = commandRunner
        } else {
            self.commandRunner = { executableURL, arguments, currentDirectoryURL, timeoutSeconds, prelaunchDelay, onLaunch in
                let runner = WorkspaceProcessRunner()
                return await runner.run(
                    executableURL: executableURL,
                    arguments: arguments,
                    currentDirectoryURL: currentDirectoryURL,
                    timeoutSeconds: timeoutSeconds,
                    prelaunchDelay: prelaunchDelay,
                    onLaunch: onLaunch
                )
            }
        }
    }

    func run(
        _ mode: CodexExecutionMode,
        prompt: String,
        workspacePath: String?,
        imagePaths: [String] = [],
        removeImageInputsAfterRun: Bool = false,
        ephemeral: Bool = false,
        fallbackWorkingDirectoryPath: String? = nil,
        skipGitRepoCheck: Bool = false
    ) async -> WorkspaceCommandResult {
        defer {
            if removeImageInputsAfterRun {
                for imagePath in imagePaths {
                    try? fileManager.removeItem(atPath: imagePath)
                }
            }
        }

        let trimmedWorkspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFallbackWorkingDirectoryPath = fallbackWorkingDirectoryPath?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usesFallbackWorkingDirectory = trimmedWorkspacePath?.isEmpty != false
        guard let workingDirectoryPath = usesFallbackWorkingDirectory
            ? trimmedFallbackWorkingDirectoryPath
            : trimmedWorkspacePath,
              !workingDirectoryPath.isEmpty else {
            return WorkspaceCommandResult(summary: "No workspace selected.", status: .missingWorkspace)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workingDirectoryPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return WorkspaceCommandResult(
                summary: "Workspace path is not a valid directory: \(workingDirectoryPath)",
                status: .failed
            )
        }

        guard commandTimeoutSeconds > 0 else {
            return WorkspaceCommandResult(summary: "Codex command timed out.", status: .failed)
        }

        let resolvedExecutableURL: URL?
        if let codexExecutableResolver {
            resolvedExecutableURL = codexExecutableResolver()
        } else {
            resolvedExecutableURL = resolveCodexExecutable()
        }

        guard let executableURL = resolvedExecutableURL else {
            return WorkspaceCommandResult(
                summary: """
                Codex executable was not found. Set UserDefaults key \(Self.executablePathDefaultsKey) to the Codex binary path, or install codex in PATH, /opt/homebrew/bin, /usr/local/bin, or ~/.nvm/versions/node/*/bin.
                """,
                status: .failed
            )
        }

        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("lorelei-codex-\(UUID().uuidString).txt")
        defer { try? fileManager.removeItem(at: outputURL) }

        let execution = await commandRunner(
            executableURL,
            commandArguments(
                mode: mode,
                workspacePath: workingDirectoryPath,
                outputPath: outputURL.path,
                prompt: prompt,
                imagePaths: imagePaths,
                ephemeral: ephemeral,
                skipGitRepoCheck: skipGitRepoCheck || usesFallbackWorkingDirectory
            ),
            URL(fileURLWithPath: workingDirectoryPath, isDirectory: true),
            commandTimeoutSeconds,
            0,
            nil
        )

        let finalMessage = (try? String(contentsOf: outputURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch execution.reason {
        case .cancelled:
            return WorkspaceCommandResult(summary: "Codex command cancelled.", status: .cancelled)
        case .timedOut:
            return WorkspaceCommandResult(summary: "Codex command timed out.", status: .failed)
        case .failedToStart(let error):
            return WorkspaceCommandResult(
                summary: "Codex failed to start: \(error.localizedDescription)",
                status: .failed
            )
        case .exited(let status):
            if status == 0 {
                return WorkspaceCommandResult(
                    summary: finalMessage.isEmpty ? "Codex returned no response." : concise(finalMessage)
                )
            }

            let combinedOutput = [finalMessage, execution.stdout, execution.stderr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let failure = combinedOutput.isEmpty ? "No output." : concise(combinedOutput)
            return WorkspaceCommandResult(
                summary: "Codex failed with exit code \(status):\n\(failure)",
                status: .failed
            )
        }
    }

    func commandArguments(
        mode: CodexExecutionMode,
        workspacePath: String,
        outputPath: String,
        prompt: String,
        imagePaths: [String] = [],
        ephemeral: Bool = false,
        skipGitRepoCheck: Bool = false
    ) -> [String] {
        var arguments: [String] = []

        if mode == .workspaceWrite {
            arguments += [
                "--ask-for-approval",
                "never"
            ]
        }

        arguments += ["exec"]

        if ephemeral {
            arguments += ["--ephemeral"]
        }

        if skipGitRepoCheck {
            arguments += ["--skip-git-repo-check"]
        }

        for imagePath in imagePaths {
            let trimmedImagePath = imagePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedImagePath.isEmpty else { continue }
            arguments += ["-i", trimmedImagePath]
        }

        arguments += [
            "--sandbox",
            mode.sandboxArgument,
            "--cd",
            workspacePath,
            "--output-last-message",
            outputPath,
            prompt
        ]

        return arguments
    }

    private func resolveCodexExecutable() -> URL? {
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

    private func concise(_ output: String, maxCharacters: Int = 4_000) -> String {
        guard output.count > maxCharacters else { return output }
        let endIndex = output.index(output.startIndex, offsetBy: maxCharacters)
        return "\(output[..<endIndex])\n... output truncated ..."
    }
}
