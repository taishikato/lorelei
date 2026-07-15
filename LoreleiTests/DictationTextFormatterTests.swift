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

        let result = await formatter.format("um hello world")

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

        let result = await formatter.format("keep this raw")

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

        let result = await formatter.format("timeout this")

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

        let result = await formatter.format("non empty input")

        #expect(result == .fallbackToRaw(reason: "empty_output"))
    }

    @Test func dedicatedExecutorUsesTenSecondTimeoutAndCancelsApprovals() async throws {
        let executor = DictationTextFormatter.makeDedicatedExecutor(
            makeTransport: { FakeCodexAppServerTransport(lines: []) }
        )
        #expect(executor.defaultedTurnTimeoutSecondsForTesting == 10)
    }
}
