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
    case codexChrome(String)
    case unsupported(String)

    var requiresWorkspace: Bool {
        switch self {
        case .gitStatus, .gitDiff, .runTests, .codexReadOnly, .codexWorkspaceWrite, .codexScreen:
            return true
        case .codexComputerUse, .codexChrome, .unsupported:
            return false
        }
    }
}

struct LoreleiConfirmationPolicy {
    static func requiresConfirmation(for action: LoreleiCommandAction) -> Bool {
        switch action {
        case .codexReadOnly, .codexWorkspaceWrite, .codexComputerUse, .codexChrome:
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
        The user requested a computer-use action through Lorelei. Use available computer-use capabilities if needed. Do not commit changes.

        User request:
        \(prompt)
        """
    }

    static func chromePrompt(for prompt: String) -> String {
        """
        @chrome Use the existing Chrome browser/profile/session through the Codex Chrome Extension. If a suitable open tab already exists, use or claim that existing tab; otherwise open a new tab in the existing Chrome session. Do not use AppleScript, shell browser automation, or a non-Chrome fallback. Do not commit changes.

        User browser operation:
        \(prompt)
        """
    }
}

struct BrowserOperationClassification: Codable, Equatable, Sendable {
    let isBrowserOperation: Bool
    let operation: String
    let confidence: Double
}

struct BrowserOperationClassifier {
    private let codexExecutor: CodexExecutor
    private let fallbackWorkingDirectoryPath: String

    init(
        codexExecutor: CodexExecutor = CodexExecutor(),
        fallbackWorkingDirectoryPath: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.codexExecutor = codexExecutor
        self.fallbackWorkingDirectoryPath = fallbackWorkingDirectoryPath
    }

    func classify(_ transcript: String, workspacePath: String?) async -> BrowserOperationClassification? {
        let result = await codexExecutor.run(
            .readOnly,
            prompt: Self.classificationPrompt(for: transcript),
            workspacePath: workspacePath,
            ephemeral: true,
            fallbackWorkingDirectoryPath: fallbackWorkingDirectoryPath,
            skipGitRepoCheck: true
        )

        guard result.status == WorkspaceCommandResultStatus.succeeded else { return nil }
        return Self.parseClassificationResponse(result.summary)
    }

    static func shouldClassify(_ transcript: String) -> Bool {
        let command = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !command.isEmpty else { return false }
        guard !command.contains("@chrome") else { return false }

        let phraseCues = [
            "go to",
            "look up",
            "open link",
            "open page",
            "open site",
            "open tab",
            "open url",
            "search for",
            "use chrome",
            "use the browser"
        ]
        if phraseCues.contains(where: { command.contains($0) }) {
            return true
        }

        if command.range(
            of: #"\b[a-z0-9-]+\.(ai|app|co|com|dev|io|jp|net|org)\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }

        let wordCues: Set<String> = [
            "browser",
            "chrome",
            "google",
            "link",
            "navigate",
            "page",
            "search",
            "site",
            "tab",
            "url",
            "web",
            "website"
        ]
        let separators = CharacterSet.alphanumerics.inverted
        let tokens = command
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
        return tokens.contains { wordCues.contains($0) }
    }

    static func classificationPrompt(for transcript: String) -> String {
        """
        Classify whether this Lorelei voice transcript asks to operate the user's web browser or Chrome. Browser operations include navigating to a site, searching Google, using a webpage, clicking or typing in a browser tab, reading an existing browser page, managing tabs, or interacting with a web app. Do not perform the operation.

        Return JSON only using this exact shape:
        {"isBrowserOperation": true, "operation": "concise browser task", "confidence": 0.0}

        Use false with an empty operation when the transcript is about code, files, git, tests, the desktop outside a browser, or general Q&A.

        Transcript:
        \(transcript)
        """
    }

    static func parseClassificationResponse(_ response: String) -> BrowserOperationClassification? {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText = extractJSONObjectText(from: trimmedResponse)
        guard let data = jsonText.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BrowserOperationClassification.self, from: data)
    }

    private static func extractJSONObjectText(from response: String) -> String {
        guard let startIndex = response.firstIndex(of: "{"),
              let endIndex = response.lastIndex(of: "}") else {
            return response
        }

        return String(response[startIndex...endIndex])
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
    func route(
        _ transcript: String,
        browserClassification: BrowserOperationClassification? = nil
    ) -> LoreleiCommandAction {
        let originalCommand = transcript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let command = originalCommand
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !command.isEmpty else {
            return .unsupported("I didn't catch a command.")
        }

        if let browserClassification,
           browserClassification.isBrowserOperation,
           browserClassification.confidence >= 0.65 {
            let browserOperation = browserClassification.operation
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .codexChrome(browserOperation.isEmpty ? originalCommand : browserOperation)
        }

        if command.contains("@chrome") {
            return .codexChrome(originalCommand)
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
