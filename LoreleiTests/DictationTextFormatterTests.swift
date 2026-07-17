//
//  DictationTextFormatterTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

@MainActor
struct DictationTextFormatterTests {
    @Test func formatReturnsCleanedTextOnSuccess() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hello world."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let formatter = DictationTextFormatter(
            workingDirectoryProvider: { "/Users/example" },
            makeExecutor: {
                DictationTextFormatter.makeDedicatedExecutor(
                    makeTransport: { transport }
                )
            }
        )

        let result = await formatter.format("um hello world", appContext: nil)

        #expect(result == .formatted("Hello world."))
        #expect(await transport.sentMethods.contains("turn/start"))
    }

    @Test func formatFallsBackWhenTurnFails() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/completed","params":{"status":"failed"}}"#
        ])
        let formatter = DictationTextFormatter(
            workingDirectoryProvider: { "/Users/example" },
            makeExecutor: {
                DictationTextFormatter.makeDedicatedExecutor(
                    makeTransport: { transport }
                )
            }
        )

        let result = await formatter.format("keep this raw", appContext: nil)

        guard case .fallbackToRaw = result else {
            Issue.record("Expected fallbackToRaw, got \(result)")
            return
        }
    }

    @Test func formatFallsBackOnTimeout() async throws {
        let timeoutGate = SleepGate()
        let transport = HangingAfterLinesCodexAppServerTransport(
            lines: [
                #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
                #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
            ],
            onSend: { line in
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      root["method"] as? String == "turn/start" else {
                    return
                }
                Task { await timeoutGate.release() }
            }
        )
        let formatter = DictationTextFormatter(
            workingDirectoryProvider: { "/Users/example" },
            makeExecutor: {
                DictationTextFormatter.makeDedicatedExecutor(
                    turnTimeoutSeconds: 2.0,
                    timeoutSleep: { _ in try await timeoutGate.wait() },
                    makeTransport: { transport }
                )
            }
        )

        let result = await formatter.format("timeout this", appContext: nil)

        guard case .fallbackToRaw = result else {
            Issue.record("Expected fallbackToRaw on timeout, got \(result)")
            return
        }
    }

    @Test func formatFallsBackWhenAgentReturnsEmptyOutput() async throws {
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"   "}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let formatter = DictationTextFormatter(
            workingDirectoryProvider: { "/Users/example" },
            makeExecutor: {
                DictationTextFormatter.makeDedicatedExecutor(
                    makeTransport: { transport }
                )
            }
        )

        let result = await formatter.format("non empty input", appContext: nil)

        #expect(result == .fallbackToRaw(reason: "empty_output"))
    }

    @Test func dedicatedExecutorUsesTenSecondTimeoutAndCancelsApprovals() async throws {
        let executor = DictationTextFormatter.makeDedicatedExecutor(
            makeTransport: { FakeCodexAppServerTransport(lines: []) }
        )
        #expect(executor.defaultedTurnTimeoutSecondsForTesting == 10)
    }

    @Test func scaledTurnTimeoutSecondsMatchesFormulaBoundaries() {
        #expect(DictationTextFormatter.scaledTurnTimeoutSeconds(textCharacters: 0) == 10)
        #expect(
            DictationTextFormatter.scaledTurnTimeoutSeconds(textCharacters: 74)
                == min(10 + Double(74) / 100, 60)
        )
        #expect(
            DictationTextFormatter.scaledTurnTimeoutSeconds(textCharacters: 2338)
                == min(10 + Double(2338) / 100, 60)
        )
        #expect(DictationTextFormatter.scaledTurnTimeoutSeconds(textCharacters: 1_000_000) == 60)
    }

    @Test func formatArmsScaledTurnTimeoutViaInjectedSleep() async throws {
        let selectedLength = 2338
        let expectedTimeout = DictationTextFormatter.scaledTurnTimeoutSeconds(
            textCharacters: selectedLength
        )
        let armed = ArmedTimeoutSecondsBox()
        let hangGate = SleepGate()
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Cleaned."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let formatter = DictationTextFormatter(
            workingDirectoryProvider: { "/Users/example" },
            makeExecutor: {
                DictationTextFormatter.makeDedicatedExecutor(
                    turnTimeoutSeconds: 10,
                    timeoutSleep: { seconds in
                        await armed.recordFirst(seconds)
                        try await hangGate.wait()
                    },
                    makeTransport: { transport }
                )
            }
        )

        let input = String(repeating: "a", count: selectedLength)
        let result = await formatter.format(input, appContext: nil)

        #expect(result == .formatted("Cleaned."))
        #expect(await armed.value == expectedTimeout)
    }

    @Test func formatEditArmsScaledTurnTimeoutViaInjectedSleep() async throws {
        let selectedLength = 74
        let expectedTimeout = DictationTextFormatter.scaledTurnTimeoutSeconds(
            textCharacters: selectedLength
        )
        let armed = ArmedTimeoutSecondsBox()
        let hangGate = SleepGate()
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Shorter."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let formatter = DictationTextFormatter(
            workingDirectoryProvider: { "/Users/example" },
            makeExecutor: {
                DictationTextFormatter.makeDedicatedExecutor(
                    turnTimeoutSeconds: 10,
                    timeoutSleep: { seconds in
                        await armed.recordFirst(seconds)
                        try await hangGate.wait()
                    },
                    makeTransport: { transport }
                )
            }
        )

        let selectedText = String(repeating: "b", count: selectedLength)
        let result = await formatter.formatEdit(
            instruction: "make this shorter",
            selectedText: selectedText,
            appContext: nil
        )

        #expect(result == .formatted("Shorter."))
        #expect(await armed.value == expectedTimeout)
    }

    @Test func promptWithoutContextMatchesLegacyPrompt() {
        let legacy = DictationTextFormatter.prompt(for: "hello", appContext: nil)
        #expect(legacy.contains("You are a dictation cleanup helper."))
        #expect(!legacy.contains("Style hint"))
    }

    @Test func promptWithUnknownAppMatchesNoContextPrompt() {
        let unknownApp = DictationAppContext(
            bundleIdentifier: "com.example.someapp",
            localizedName: "SomeApp"
        )
        let withUnknown = DictationTextFormatter.prompt(for: "hello", appContext: unknownApp)
        let without = DictationTextFormatter.prompt(for: "hello", appContext: nil)
        #expect(withUnknown == without)
    }

    @Test func promptWithEmailContextAppendsEmailHint() {
        let mail = DictationAppContext(
            bundleIdentifier: "com.apple.mail",
            localizedName: "Mail"
        )
        let prompt = DictationTextFormatter.prompt(for: "hello", appContext: mail)
        #expect(prompt.contains("Style hint"))
        #expect(prompt.contains("email compose field"))
        #expect(prompt.contains("Never add, remove, or reword meaningful content."))
    }

    @Test func promptWithCodeContextAppendsVerbatimHint() {
        let cursor = DictationAppContext(
            bundleIdentifier: "com.todesktop.230313mzl4w4u92",
            localizedName: "Cursor"
        )
        let prompt = DictationTextFormatter.prompt(for: "hello", appContext: cursor)
        #expect(prompt.contains("code editor or terminal"))
    }

    @Test func editPromptContainsInstructionSelectionAndGuardrails() {
        let prompt = DictationTextFormatter.editPrompt(
            instruction: "make this shorter",
            selectedText: "The quick brown fox jumps over the lazy dog.",
            appContext: nil
        )
        #expect(prompt.contains("make this shorter"))
        #expect(prompt.contains("The quick brown fox"))
        #expect(prompt.contains("Return ONLY the rewritten text"))
        #expect(prompt.contains(
            "Keep the language of the text unchanged unless the instruction says otherwise."
        ))
        #expect(!prompt.contains("Style hint"))
    }

    @Test func editPromptAppendsStyleHintForKnownApp() {
        let mail = DictationAppContext(
            bundleIdentifier: "com.apple.mail",
            localizedName: "Mail"
        )
        let prompt = DictationTextFormatter.editPrompt(
            instruction: "make it formal",
            selectedText: "hey",
            appContext: mail
        )
        #expect(prompt.contains("Style hint"))
        #expect(prompt.contains("email compose field"))
    }
}
