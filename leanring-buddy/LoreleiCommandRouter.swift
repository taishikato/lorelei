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

struct LoreleiConfirmationPolicy {
    static func requiresConfirmation(for action: LoreleiCommandAction) -> Bool {
        switch action {
        case .codexReadOnly, .codexWorkspaceWrite, .codexComputerUse:
            return true
        case .gitStatus, .gitDiff, .runTests, .codexScreen, .unsupported:
            return false
        }
    }
}

struct CodexPromptBuilder {
    static func workspaceWritePrompt(for prompt: String) -> String {
        """
        Do not commit changes.

        User request:
        \(prompt)
        """
    }

    static func computerUsePrompt(for prompt: String) -> String {
        """
        Use the existing Codex Computer Use plugin when desktop UI operation is needed.
        Follow the Codex Computer Use confirmation and safety policy for risky UI actions.
        Do not commit changes.

        User request:
        \(prompt)
        """
    }
}

struct PendingCommandConfirmation {
    private(set) var title: String?
    private(set) var action: LoreleiCommandAction?

    mutating func request(title: String, action: LoreleiCommandAction) {
        self.title = title
        self.action = action
    }

    mutating func confirm() -> LoreleiCommandAction? {
        defer { cancel() }
        return action
    }

    mutating func cancel() {
        title = nil
        action = nil
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

        if isStatusRequest(command) {
            return .gitStatus
        }

        if isDiffRequest(command) {
            return .gitDiff
        }

        if isRunTestsRequest(command) {
            return .runTests
        }

        if isMutatingRequest(command) {
            return .codexWorkspaceWrite(originalCommand)
        }

        return .codexReadOnly(originalCommand)
    }

    private func isStatusRequest(_ command: String) -> Bool {
        command.contains("git status") || command.contains("status")
    }

    private func isDiffRequest(_ command: String) -> Bool {
        command.contains("what changed")
            || command.contains("diff")
            || command.contains("changes")
            || command.contains("changed")
    }

    private func isRunTestsRequest(_ command: String) -> Bool {
        command == "test"
            || command == "tests"
            || command.hasPrefix("test ")
            || command.hasPrefix("tests ")
            || command.contains("run tests")
            || command.contains("run test")
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
            "install",
            "update",
            "add",
            "remove",
            "rename",
            "move",
            "modify",
            "apply",
            "implement",
            "replace",
            "configure",
            "setup"
        ]) || command.contains("set up")
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
            || command.contains("capture my screen")
            || command.contains("screen context")
            || command.contains("screenshot")
            || command.contains("visual context")
    }

    private func containsAnyWord(in command: String, words: [String]) -> Bool {
        let separators = CharacterSet.alphanumerics.inverted
        let tokens = command
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        return words.contains { tokens.contains($0) }
    }
}
