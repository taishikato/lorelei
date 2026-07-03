//
//  LoreleiCommandRouter.swift
//  Lorelei
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
    case codexDesktopAction(String)
    case unsupported(String)

    var requiresWorkspace: Bool {
        switch self {
        case .gitStatus, .gitDiff, .runTests, .codexReadOnly, .codexWorkspaceWrite, .codexScreen:
            return true
        case .codexDesktopAction, .unsupported:
            return false
        }
    }

    var debugLabel: String {
        switch self {
        case .gitStatus:
            return "Git status"
        case .gitDiff:
            return "Git diff"
        case .runTests:
            return "Run tests"
        case .codexReadOnly:
            return "Codex read-only"
        case .codexWorkspaceWrite:
            return "Codex workspace write"
        case .codexScreen:
            return "Codex screen request"
        case .codexDesktopAction:
            return "Codex desktop action"
        case .unsupported:
            return "Unsupported command"
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

    static func desktopActionPrompt(for prompt: String) -> String {
        """
        Use Codex App Server's interactive control plane for every desktop operation.
        Use the Codex Computer Use plugin for desktop control, including browser typing, clicking, search, scrolling, dragging, key presses, and other interactive UI actions.
        Before Computer Use inspects a desktop app, call lorelei.foreground_app for that target app. If Computer Use reports cgWindowNotFound, call lorelei.foreground_app once more before retrying visual inspection.
        For app opening or URL opening, call lorelei.foreground_app before visual inspection so the target app is visible in the current macOS Space.
        Follow the Codex Computer Use confirmation and safety policy for risky UI actions.
        Do not rely on caller-side local shortcuts.
        Do not commit changes.

        User request:
        \(prompt)
        """
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
            return .codexDesktopAction(originalCommand)
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
            || containsAnyWord(in: command, words: [
                "browser",
                "open",
                "launch",
                "type",
                "search",
                "ask",
                "enter",
                "submit",
                "press",
                "click",
                "scroll"
            ])
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
