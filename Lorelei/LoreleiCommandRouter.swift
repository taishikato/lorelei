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
        desktopActionPrompt(for: prompt, computerUseAvailable: false)
    }

    static func desktopActionPrompt(for prompt: String, computerUseAvailable: Bool) -> String {
        guard computerUseAvailable else {
            return """
            Use Codex App Server's interactive control plane for every desktop operation.
            You control the desktop ONLY through the lorelei.* tools:
            1. Call lorelei.foreground_app to bring the target app (or URL) onscreen in the current macOS Space.
            2. Call lorelei.desktop_snapshot to read the app's accessibility tree; the first [focused] line is always the current focused UI element outside the normal budget.
            3. Use lorelei.desktop_action (press/focus/raise/open/select/showMenu, especially open/select/showMenu for rows) and lorelei.set_text (sets values directly - required for non-ASCII text) to operate the UI; when in doubt, send text to the focused field with elementId "focused".
            4. After UI state changes, call lorelei.desktop_snapshot again before further actions.
            5. Only when the snapshot lacks the information you need (canvas or custom-drawn UIs), call lorelei.screenshot and reason from the image.
            Do not simulate keyboard shortcuts. Do not use shell commands to manipulate the UI.
            Shell commands may prepare files/data but must NEVER be used to drive UI, and AppleScript/osascript UI automation is unavailable (no Automation permission); when the UI path fails, report the blocker instead of escalating to scripts.
            Do not commit changes.

            User request:
            \(prompt)
            """
        }

        return """
        Use official Computer Use as the PRIMARY way to operate the desktop for this request.
        The computer-use skill is attached to this turn: follow it - bootstrap node_repl once, then drive apps with the sky.* API (sky.get_app_state, sky.click, sky.set_value, sky.press_key, ...).
        Text input rules: put non-ASCII text in with sky.set_value (or lorelei.set_text) - NEVER sky.type_text for non-ASCII content; IMEs corrupt synthesized keystrokes.
        FALLBACK: if Computer Use is unavailable, fails to start, or a sky.* call errors and retrying once does not help, switch to the lorelei.* tools for the rest of the task:
        1. lorelei.foreground_app to bring the target app (or URL) onscreen.
        2. lorelei.desktop_snapshot to read the accessibility tree.
        3. lorelei.desktop_action and lorelei.set_text to operate the UI.
        4. lorelei.screenshot only when the snapshot lacks the information you need.
        Do not simulate keyboard shortcuts. Shell commands may prepare files/data but must NEVER be used to drive UI, and AppleScript/osascript UI automation is unavailable; when both tool paths fail, report the blocker instead of escalating to scripts.
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

        let normalizedCommand = normalizeCommand(command)

        if isScreenRequest(normalizedCommand) {
            return .codexScreen(originalCommand)
        }

        if isStatusRequest(normalizedCommand) {
            return .gitStatus
        }

        if isDiffRequest(normalizedCommand) {
            return .gitDiff
        }

        if isRunTestsRequest(normalizedCommand) {
            return .runTests
        }

        if isQuestion(normalizedCommand) {
            return .codexReadOnly(originalCommand)
        }

        if isComputerUseRequest(normalizedCommand) {
            return .codexDesktopAction(originalCommand)
        }

        if isMutatingRequest(normalizedCommand) {
            return .codexWorkspaceWrite(originalCommand)
        }

        return .codexReadOnly(originalCommand)
    }

    private func normalizeCommand(_ command: String) -> String {
        let prefixes = [
            "please ",
            "hey lorelei ",
            "lorelei ",
            "hey ",
            "can you ",
            "could you ",
            "would you ",
            "will you ",
            "i need you to ",
            "i want you to ",
            "i'd like you to ",
            "i would like you to "
        ]
        var normalized = command
        var didStripPrefix = true

        while didStripPrefix {
            didStripPrefix = false
            for prefix in prefixes where normalized.hasPrefix(prefix) {
                normalized.removeFirst(prefix.count)
                didStripPrefix = true
                break
            }
        }

        return normalized
    }

    private func isQuestion(_ command: String) -> Bool {
        let commandTokens = tokens(in: command)
        guard let firstToken = commandTokens.first else {
            return false
        }

        let whWords: Set<String> = [
            "what", "why", "how", "when", "where", "who", "whose", "which"
        ]
        if whWords.contains(firstToken) {
            return true
        }

        // A leading auxiliary only reads as a question when a subject
        // follows ("do you see...", "should i add..."). Without one it is
        // an imperative ("do a google search...") and must keep routing.
        let auxiliaries: Set<String> = [
            "should", "shall", "would", "could", "can",
            "do", "does", "did", "is", "are", "was", "were", "am", "will"
        ]
        let subjects: Set<String> = [
            "you", "i", "we", "they", "he", "she", "it",
            "this", "that", "these", "those", "there", "lorelei"
        ]
        guard auxiliaries.contains(firstToken) else {
            return false
        }
        guard commandTokens.count > 1 else {
            return true
        }
        return subjects.contains(commandTokens[1])
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
        matchesWord(in: command, words: [
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
        ], withinLeadingTokens: 4) || command.contains("set up")
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
            || matchesWord(in: command, words: [
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
            ], withinLeadingTokens: 4)
    }

    private func isScreenRequest(_ command: String) -> Bool {
        command.contains("look at my screen")
            || command.contains("look at the screen")
            || command.contains("see my screen")
            || command.contains("what's on my screen")
            || command.contains("what is on my screen")
            || command.contains("capture my screen")
            || command.contains("screen context")
            || command.contains("screenshot")
            || command.contains("visual context")
    }

    private func matchesWord(in command: String, words: [String], withinLeadingTokens tokenLimit: Int) -> Bool {
        let leadingTokens = tokens(in: command).prefix(tokenLimit)
        return words.contains { leadingTokens.contains($0) }
    }

    private func tokens(in command: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        return command
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }
}
