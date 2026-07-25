//
//  CompanionManagerTypedInputTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

@MainActor
struct CompanionManagerTypedInputTests {
    @Test func submitTypedMessageStartsATurnAndLogsTheUserEntry() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerTypedInputNewTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerTypedInputNewTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Working"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.submitTypedMessage("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.streamText == "Working" { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.conversationLog.map(\.role) == [
            ConversationEntry.Role.user,
            ConversationEntry.Role.assistant
        ])
        #expect(manager.conversationLog.map(\.text) == [
            "use computer use to inspect TextEdit",
            "Working"
        ])
    }

    @Test func submitTypedMessageTrimsWhitespaceAndIgnoresEmptyInput() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerTypedInputEmptyTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerTypedInputEmptyTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Working"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.submitTypedMessage("   ")
        manager.submitTypedMessage("")

        #expect(manager.conversationLog.isEmpty)

        manager.submitTypedMessage("  open the notes app  ")
        for _ in 0..<40 {
            if manager.streamText == "Working" { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.conversationLog.first?.text == "open the notes app")
    }

    @Test func submitTypedMessageSteersWhileATurnIsActive() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerTypedInputSteerTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerTypedInputSteerTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Working"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.submitTypedMessage("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.streamText == "Working" { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.submitTypedMessage("actually the other window")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.contains(where: { $0["method"] as? String == "turn/steer" }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        #expect(sentMessages.contains { $0["method"] as? String == "turn/steer" })
        #expect(sentMessages.filter { $0["method"] as? String == "turn/start" }.count == 1)
        #expect(manager.conversationLog.last?.text == "↪ actually the other window")
    }
}
