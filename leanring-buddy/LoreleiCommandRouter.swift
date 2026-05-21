//
//  LoreleiCommandRouter.swift
//  leanring-buddy
//
//  Maps final voice transcripts to Lorelei's local workspace and Codex actions.
//

import Foundation

enum LoreleiCommandAction: Equatable, Sendable {
    case gitStatus
    case gitDiff
    case runTests
    case codexReadOnly(String)
    case codexWorkspaceWrite(String)
    case codexScreen(String)
    case codexComputerUse(String)
    case unsupported(String)

    var requiresWorkspace: Bool {
        switch self {
        case .gitStatus, .gitDiff, .runTests, .codexReadOnly, .codexWorkspaceWrite, .codexScreen:
            return true
        case .codexComputerUse, .unsupported:
            return false
        }
    }
}

struct LoreleiCommandRouter {
    func route(_ transcript: String) -> LoreleiCommandAction {
        let originalCommand = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let command = originalCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !command.isEmpty else {
            return .unsupported("I didn't catch a command.")
        }

        if isScreenRequest(command) {
            return .codexScreen(originalCommand)
        }

        if isComputerUseRequest(command) {
            return .codexComputerUse(originalCommand)
        }

        if isMutatingRequest(command) {
            return .codexWorkspaceWrite(originalCommand)
        }

        if command.contains("git status") || command.contains("status") {
            return .gitStatus
        }

        if command.contains("what changed")
            || command.contains("diff")
            || command.contains("changes")
            || command.contains("changed") {
            return .gitDiff
        }

        if command.contains("run tests")
            || command.contains("run test")
            || command.contains("tests")
            || command.contains("test") {
            return .runTests
        }

        return .codexReadOnly(originalCommand)
    }

    private func isMutatingRequest(_ command: String) -> Bool {
        containsAnyWord(in: command, words: [
            "fix",
            "edit",
            "write",
            "create",
            "delete",
            "change",
            "refactor",
            "install"
        ])
    }

    private func isComputerUseRequest(_ command: String) -> Bool {
        command.contains("click")
            || command.contains("open app")
            || command.contains("open the app")
            || command.contains("open browser")
            || command.contains("open the browser")
            || command.contains("launch")
            || command.contains("computer use")
            || command.contains("system settings")
            || command.contains("use the browser")
    }

    private func isScreenRequest(_ command: String) -> Bool {
        command.contains("look at my screen")
            || command.contains("look at the screen")
            || command.contains("see my screen")
            || command.contains("screen context")
            || command.contains("screenshot")
            || command.contains("what do you see")
    }

    private func containsAnyWord(in command: String, words: [String]) -> Bool {
        let separators = CharacterSet.alphanumerics.inverted
        let tokens = command
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        return words.contains { tokens.contains($0) }
    }
}
