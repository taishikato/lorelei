//
//  WorkspaceCommandExecutor.swift
//  leanring-buddy
//
//  Executes Lorelei's safe built-in workspace actions.
//

import Foundation

struct WorkspaceCommandResult: Equatable, Sendable {
    let summary: String
}

struct WorkspaceCommandExecutor {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func run(_ action: LoreleiCommandAction, workspacePath: String?) async -> WorkspaceCommandResult {
        guard action.requiresWorkspace else {
            if case let .unsupported(message) = action {
                return WorkspaceCommandResult(summary: message)
            }
            return WorkspaceCommandResult(summary: "Unsupported command.")
        }

        guard let workspacePath = workspacePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workspacePath.isEmpty else {
            return WorkspaceCommandResult(summary: "No workspace selected.")
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: workspacePath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return WorkspaceCommandResult(summary: "Workspace path is not a valid directory: \(workspacePath)")
        }

        switch action {
        case .gitStatus:
            return await runGit(arguments: ["status", "--short", "--branch"], workspacePath: workspacePath)
        case .gitDiff:
            return await runGitDiff(workspacePath: workspacePath)
        case .runTests:
            return WorkspaceCommandResult(summary: "No test command configured")
        case .unsupported(let message):
            return WorkspaceCommandResult(summary: message)
        }
    }

    private func runGitDiff(workspacePath: String) async -> WorkspaceCommandResult {
        let stat = await runGit(arguments: ["diff", "--stat"], workspacePath: workspacePath, emptySuccessSummary: "")
        let conciseDiff = await runGit(
            arguments: ["diff", "--name-status"],
            workspacePath: workspacePath,
            emptySuccessSummary: ""
        )

        let combined = [stat.summary, conciseDiff.summary]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        return WorkspaceCommandResult(summary: combined.isEmpty ? "No diff." : combined)
    }

    private func runGit(
        arguments: [String],
        workspacePath: String,
        emptySuccessSummary: String = "No output."
    ) async -> WorkspaceCommandResult {
        await Task.detached(priority: .userInitiated) {
            let invocation = Self.gitInvocation(arguments: arguments)
            return Self.runProcess(
                executableURL: invocation.executableURL,
                arguments: invocation.arguments,
                currentDirectoryURL: URL(fileURLWithPath: workspacePath),
                emptySuccessSummary: emptySuccessSummary
            )
        }.value
    }

    nonisolated private static func runProcess(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        emptySuccessSummary: String
    ) -> WorkspaceCommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return WorkspaceCommandResult(summary: "Command failed to start: \(error.localizedDescription)")
        }

        let output = decode(stdout.fileHandleForReading.readDataToEndOfFile())
        let errorOutput = decode(stderr.fileHandleForReading.readDataToEndOfFile())
        let combined = [output, errorOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        let conciseOutput = concise(combined)
        if process.terminationStatus == 0 {
            return WorkspaceCommandResult(summary: conciseOutput.isEmpty ? emptySuccessSummary : conciseOutput)
        }

        let command = ([executableURL.path] + arguments).joined(separator: " ")
        let failure = conciseOutput.isEmpty ? "No output." : conciseOutput
        return WorkspaceCommandResult(summary: "\(command) failed with exit code \(process.terminationStatus):\n\(failure)")
    }

    nonisolated private static func gitInvocation(arguments: [String]) -> (executableURL: URL, arguments: [String]) {
        let fixedPath = "/usr/bin/git"
        if FileManager.default.isExecutableFile(atPath: fixedPath) {
            return (URL(fileURLWithPath: fixedPath), arguments)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["git"] + arguments)
    }

    nonisolated private static func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func concise(_ output: String, maxCharacters: Int = 4_000) -> String {
        guard output.count > maxCharacters else { return output }
        let endIndex = output.index(output.startIndex, offsetBy: maxCharacters)
        return "\(output[..<endIndex])\n... output truncated ..."
    }
}
