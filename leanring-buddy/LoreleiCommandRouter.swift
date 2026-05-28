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

struct LoreleiConfirmationPolicy {
    static func requiresConfirmation(for action: LoreleiCommandAction) -> Bool {
        switch action {
        case .codexReadOnly, .codexWorkspaceWrite, .codexDesktopAction:
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

    static func desktopActionPrompt(for prompt: String) -> String {
        """
        Use Codex App Server's interactive control plane for every desktop operation, including simple app and URL opening.
        For app or URL opening, first call the dynamic tool lorelei.foreground_app; URL opening must also go through that tool.
        lorelei.foreground_app opens the optional URL, activates the target app, and tries to make its normal window visible in the current macOS Space.
        Use the Codex Computer Use plugin only when visual UI inspection, clicking, typing, scrolling, dragging, or key presses are actually needed.
        Before Computer Use inspects a desktop app, call lorelei.foreground_app for that target app. If Computer Use reports cgWindowNotFound, call lorelei.foreground_app once more before retrying visual inspection.
        Follow the Codex Computer Use confirmation and safety policy for risky UI actions.
        Do not rely on caller-side local shortcuts.
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

        if let browserOpenPrompt = browserOpenPrompt(command: command, originalCommand: originalCommand) {
            return .codexDesktopAction(browserOpenPrompt)
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
            || isBrowserDesktopOperation(command)
    }

    private func browserOpenPrompt(command: String, originalCommand: String) -> String? {
        guard command.contains("chrome"),
              !command.contains("computer use"),
              !requiresBrowserInteractionAfterOpen(command),
              containsAnyWord(in: command, words: ["open", "launch"]) || command.contains("new tab"),
              let urlString = normalizedURLString(in: originalCommand) else {
            return nil
        }

        return """
        Open \(urlString) in Google Chrome.
        Call lorelei.foreground_app exactly once with appName "Google Chrome", bundleIdentifier "com.google.Chrome", and url "\(urlString)".
        After the tool succeeds, reply with the tool result in one sentence.
        Do not use Computer Use, shell commands, or the Chrome plugin.
        Do not search, type into the page, click submit, or perform any additional browser interaction.

        Original user request:
        \(originalCommand)
        """
    }

    private func isBrowserDesktopOperation(_ command: String) -> Bool {
        let mentionsBrowserTarget = command.contains("chrome")
            || command.contains("safari")
            || command.contains("browser")
            || command.contains("chatgpt")

        guard mentionsBrowserTarget else { return false }

        return containsAnyWord(in: command, words: [
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
        ]) || command.contains("new tab")
    }

    private func requiresBrowserInteractionAfterOpen(_ command: String) -> Bool {
        command.contains(" and then ")
            || command.contains(" then ")
            || containsAnyWord(in: command, words: [
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

    private func normalizedURLString(in command: String) -> String? {
        let trimmingCharacters = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "\"'.,;!?()[]{}<>"))

        for rawToken in command.components(separatedBy: .whitespacesAndNewlines) {
            let token = rawToken.trimmingCharacters(in: trimmingCharacters)
            guard !token.isEmpty else { continue }

            if let urlString = normalizedURLString(from: token) {
                return urlString
            }
        }

        return nil
    }

    private func normalizedURLString(from token: String) -> String? {
        let lowercasedToken = token.lowercased()
        let candidate: String
        if lowercasedToken.hasPrefix("https://") || lowercasedToken.hasPrefix("http://") {
            candidate = token
        } else if looksLikeDomain(token) {
            candidate = "https://\(token)"
        } else {
            return nil
        }

        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              looksLikeHost(host) else {
            return nil
        }

        return components.string ?? candidate
    }

    private func looksLikeDomain(_ token: String) -> Bool {
        let host = token
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? token
        return looksLikeHost(host)
    }

    private func looksLikeHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              let topLevelDomain = labels.last,
              topLevelDomain.count >= 2 else {
            return false
        }

        return host.allSatisfy { character in
            character.isLetter || character.isNumber || character == "." || character == "-"
        }
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
