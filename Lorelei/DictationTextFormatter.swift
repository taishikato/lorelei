//
//  DictationTextFormatter.swift
//  Lorelei
//
//  Light Codex post-processor for system dictation: filler removal,
//  punctuation, and line breaks only. Owns a dedicated app-server
//  executor so dictation never shares the command conversation.
//

import Foundation

enum DictationFormatterResult: Equatable, Sendable {
    case formatted(String)
    case fallbackToRaw(reason: String)
}

protocol DictationTextFormatting: AnyObject {
    func format(
        _ rawTranscript: String,
        appContext: DictationAppContext?
    ) async -> DictationFormatterResult
    func formatEdit(
        instruction: String,
        selectedText: String,
        appContext: DictationAppContext?
    ) async -> DictationFormatterResult
    func prewarm()
}

@MainActor
final class DictationTextFormatter: DictationTextFormatting {
    private let workingDirectoryProvider: () -> String
    private let makeExecutor: () -> CodexAppServerExecutor
    private var executor: CodexAppServerExecutor?

    init(
        workingDirectoryProvider: @escaping () -> String = {
            DictationTextFormatter.codexAppServerWorkingDirectory()
        },
        makeExecutor: @escaping () -> CodexAppServerExecutor = {
            DictationTextFormatter.makeDedicatedExecutor()
        }
    ) {
        self.workingDirectoryProvider = workingDirectoryProvider
        self.makeExecutor = makeExecutor
    }

    func prewarm() {
        // ensureSession is private to CodexAppServerSessionStore; constructing
        // the dedicated executor here is the reachable warm-up without adding
        // session-store API. Process spawn still happens on the first format turn.
        _ = sharedExecutor()
    }

    func format(
        _ rawTranscript: String,
        appContext: DictationAppContext?
    ) async -> DictationFormatterResult {
        let trimmedInput = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return .formatted("")
        }

        LoreleiDiagLog.log("dictationFormatter: runTurn begin chars=\(trimmedInput.count)")
        let startedAt = Date()
        let result = await sharedExecutor().runTurn(
            prompt: Self.prompt(for: rawTranscript, appContext: appContext),
            cwd: workingDirectoryProvider(),
            sandboxPolicy: "readOnly"
        )
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        LoreleiDiagLog.log(
            "dictationFormatter: runTurn end status=\(result.status) elapsedMs=\(elapsedMs) summaryChars=\(result.summary.count)"
        )

        guard result.status == .succeeded else {
            return .fallbackToRaw(reason: "turn_\(result.status)")
        }

        let cleaned = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        // CodexAppServerExecutor substitutes empty agent text with "Codex completed."
        // Treat that sentinel as empty output for dictation cleanup.
        guard !cleaned.isEmpty, cleaned != "Codex completed." else {
            return .fallbackToRaw(reason: "empty_output")
        }

        return .formatted(cleaned)
    }

    func formatEdit(
        instruction: String,
        selectedText: String,
        appContext: DictationAppContext?
    ) async -> DictationFormatterResult {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstruction.isEmpty else {
            return .fallbackToRaw(reason: "empty_instruction")
        }

        LoreleiDiagLog.log(
            "dictationEditFormatter: runTurn begin instructionChars=\(trimmedInstruction.count) selectedChars=\(selectedText.count)"
        )
        let startedAt = Date()
        let result = await sharedExecutor().runTurn(
            prompt: Self.editPrompt(
                instruction: instruction,
                selectedText: selectedText,
                appContext: appContext
            ),
            cwd: workingDirectoryProvider(),
            sandboxPolicy: "readOnly"
        )
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        LoreleiDiagLog.log(
            "dictationEditFormatter: runTurn end status=\(result.status) elapsedMs=\(elapsedMs) summaryChars=\(result.summary.count)"
        )

        guard result.status == .succeeded else {
            return .fallbackToRaw(reason: "turn_\(result.status)")
        }

        let edited = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !edited.isEmpty, edited != "Codex completed." else {
            return .fallbackToRaw(reason: "empty_output")
        }

        return .formatted(edited)
    }

    private func sharedExecutor() -> CodexAppServerExecutor {
        if let executor {
            return executor
        }
        let created = makeExecutor()
        executor = created
        return created
    }

    static func prompt(
        for rawTranscript: String,
        appContext: DictationAppContext?
    ) -> String {
        let styleHintBlock: String
        if let hint = appContext?.category.styleHint {
            styleHintBlock = """

            Style hint (style only - never change meaning):
            \(hint)
            """
        } else {
            styleHintBlock = ""
        }

        return """
        You are a dictation cleanup helper. Operate on the transcript below.
        Return ONLY the cleaned transcript text with no preamble, quotes, or commentary.

        Rules:
        - Remove filler words (um, uh, like, you know, えーと, あの, etc.).
        - Fix punctuation and line breaks so the text reads as natural writing.
        - Fix obvious speech-to-text artifacts when the intended word is clear.
        - Never add, remove, or reword meaningful content.
        - Keep the language of the input unchanged.\(styleHintBlock)

        Transcript:
        \(rawTranscript)
        """
    }

    static func editPrompt(
        instruction: String,
        selectedText: String,
        appContext: DictationAppContext?
    ) -> String {
        let styleHintBlock: String
        if let hint = appContext?.category.styleHint {
            styleHintBlock = """

            Style hint (style only - never change meaning beyond the instruction):
            \(hint)
            """
        } else {
            styleHintBlock = ""
        }

        return """
        You are a text editing helper. Apply the spoken instruction to the text below.
        Return ONLY the rewritten text with no preamble, quotes, or commentary.

        Rules:
        - Apply the instruction faithfully; change nothing the instruction does not cover.
        - Keep the language of the text unchanged unless the instruction says otherwise.
        - Preserve meaning except where the instruction requires changing it.
        - If the instruction cannot be applied to this text, return the text unchanged.\(styleHintBlock)

        Instruction (spoken, may contain filler words):
        \(instruction)

        Text:
        \(selectedText)
        """
    }

    /// Mirrors `CompanionManager.codexAppServerWorkingDirectory()`.
    nonisolated static func codexAppServerWorkingDirectory(
        selectedWorkspacePath: String? = nil,
        fileManager: FileManager = .default
    ) -> String {
        if let workspacePath = selectedWorkspacePath?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !workspacePath.isEmpty {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: workspacePath, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return workspacePath
            }
        }

        return fileManager.homeDirectoryForCurrentUser.path
    }

    nonisolated static func makeDedicatedExecutor(
        turnTimeoutSeconds: TimeInterval = 10,
        timeoutSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        makeTransport: @escaping () async throws -> CodexAppServerTransporting = {
            try await CodexAppServerStdioTransport.make()
        }
    ) -> CodexAppServerExecutor {
        CodexAppServerExecutor(
            turnTimeoutSeconds: turnTimeoutSeconds,
            timeoutSleep: timeoutSleep,
            makeTransport: makeTransport,
            dynamicToolSpecsResolver: { [] },
            developerInstructionsResolver: { _ in nil },
            approvalHandler: { _ in .cancel }
        )
    }
}
