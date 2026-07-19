//
//  CompanionManagerTurnTests.swift
//  LoreleiTests
//

import Testing
import AppKit
import Combine
import CoreAudio
import Foundation
import CoreGraphics
import ServiceManagement
@testable import Lorelei

@MainActor
struct CompanionManagerTurnTests {

    @Test func companionManagerTracksRunStatusThroughVoiceTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerRunStatusVoiceTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerRunStatusVoiceTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        // Record every transition instead of polling: the scripted turn can
        // finish faster than any polling interval, so transient states like
        // .working would otherwise be missed nondeterministically.
        let recorder = RunStatusRecorder()
        let statusCancellable = manager.$runStatus.sink { recorder.record($0) }
        defer { statusCancellable.cancel() }

        manager.simulateShortcutTransitionForTesting(.pressed)
        #expect(manager.runStatus == .listening)

        manager.simulateShortcutTransitionForTesting(.released)
        #expect(manager.runStatus == .transcribing)

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<200 {
            if recorder.statuses.contains(.finished(success: true)) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let statuses = recorder.statuses
        #expect(statuses.contains(.finished(success: true)))
        #expect(isOrderedSubsequence(
            [.listening, .transcribing, .working("Thinking…"), .finished(success: true)],
            of: statuses
        ))
        #expect(manager.streamText == "Hello")
    }

    @Test func companionManagerReturnsToIdleWhenTranscribeProducesNoTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerTranscribingWatchdogTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerTranscribingWatchdogTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            transcribingWatchdogDelay: .milliseconds(300)
        )

        manager.simulateShortcutTransitionForTesting(.pressed)
        manager.simulateShortcutTransitionForTesting(.released)
        #expect(manager.runStatus == .transcribing)

        // No transcript ever arrives (silent hold / no-audio device); the
        // watchdog must return the status to idle instead of sticking.
        for _ in 0..<150 {
            if manager.runStatus == .idle { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(manager.runStatus == .idle)
    }

    @Test func companionManagerPlaysCuesThroughVoiceTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerAudioVoiceTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerAudioVoiceTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.simulateShortcutTransitionForTesting(.pressed)
        manager.simulateShortcutTransitionForTesting(.released)
        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<200 {
            if audioFeedback.events.contains(where: { $0.cue == .runSucceeded }) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(audioFeedback.events.map(\.cue) == [.listeningStarted, .listeningEnded, .runSucceeded])
        #expect(audioFeedback.events.last?.spokenSummary == "Hello")
    }

    @Test func companionManagerSteersUtteranceIntoRunningTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerSteerRunningTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerSteerRunningTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = HangingAfterLinesCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Working"}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.streamText == "Working" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .working("Thinking…"))
        #expect(manager.streamText == "Working")

        manager.handleFinalTranscriptForTesting("actually the other window")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.contains(where: { $0["method"] as? String == "turn/steer" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        let steer = try #require(sentMessages.first { $0["method"] as? String == "turn/steer" })
        let steerParams = try #require(steer["params"] as? [String: Any])
        let steerInput = try #require(steerParams["input"] as? [[String: Any]])

        #expect(steerParams["threadId"] as? String == "thread-1")
        #expect(steerParams["expectedTurnId"] as? String == "turn-9")
        #expect(steerInput.first?["text"] as? String == "actually the other window")
        #expect(sentMessages.filter { $0["method"] as? String == "turn/start" }.count == 1)
        #expect(manager.runStatus == .working("Thinking…"))
        #expect(manager.streamText == "Working")
        #expect(audioFeedback.events.isEmpty)
    }

    @Test func companionManagerLogsSteeredUtteranceIntoConversation() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerConversationLogSteerTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerConversationLogSteerTests")
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

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.streamText == "Working" {
                break
            }
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

        manager.handleFinalTranscriptForTesting("actually the other window")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.contains(where: { $0["method"] as? String == "turn/steer" }) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.conversationLog.map(\.role) == [
            ConversationEntry.Role.user,
            ConversationEntry.Role.assistant,
            ConversationEntry.Role.user
        ])
        #expect(manager.conversationLog.map(\.text) == [
            "use computer use to inspect TextEdit",
            "Working",
            "↪ actually the other window"
        ])
        #expect(manager.conversationLog.filter { $0.role == .assistant }.count == 1)
    }

    @Test func companionManagerStartsNewTurnWhenIdle() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerIdleStartsNewTurnTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerIdleStartsNewTurnTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"First"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-10","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Second"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.runStatus == .finished(success: true) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.runStatus == .finished(success: true))

        manager.handleFinalTranscriptForTesting("use computer use to inspect Safari")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.filter({ $0["method"] as? String == "turn/start" }).count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        #expect(sentMessages.filter { $0["method"] as? String == "turn/start" }.count == 2)
        #expect(!sentMessages.contains { $0["method"] as? String == "turn/steer" })
    }

    @Test func companionManagerRunsReadOnlyUtteranceOnSharedThread() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerReadOnlySharedThreadTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerReadOnlySharedThreadTests")
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = directoryURL.path
        let factoryCallCount = AsyncCounter()
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Opened TextEdit."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-10","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"I opened TextEdit."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: {
                await factoryCallCount.increment()
                return transport
            },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to open TextEdit")
        for _ in 0..<40 {
            if manager.runStatus == .finished(success: true) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        manager.handleFinalTranscriptForTesting("what did you just do")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.filter({ $0["method"] as? String == "turn/start" }).count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        let turnStarts = sentMessages.filter { $0["method"] as? String == "turn/start" }
        let secondParams = try #require(turnStarts.last?["params"] as? [String: Any])
        let secondInput = try #require(secondParams["input"] as? [[String: Any]])

        #expect(await factoryCallCount.value == 1)
        #expect(turnStarts.count == 2)
        #expect(secondParams["threadId"] as? String == "thread-1")
        #expect((secondParams["sandboxPolicy"] as? [String: Any])?["type"] as? String == "readOnly")
        #expect(secondInput.first?["text"] as? String == "what did you just do")
    }

    @Test func companionManagerRunsWorkspaceWriteOnSharedThread() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerWorkspaceWriteSharedThreadTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerWorkspaceWriteSharedThreadTests")
        let directoryURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = directoryURL.path
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Opened TextEdit."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-10","items":[],"status":"inProgress"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Fixed the test."}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let factoryCallCount = AsyncCounter()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: {
                await factoryCallCount.increment()
                return transport
            },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to open TextEdit")
        for _ in 0..<40 {
            if manager.runStatus == .finished(success: true) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        manager.handleFinalTranscriptForTesting("fix the failing test")
        for _ in 0..<40 {
            let sentMessages = try await transport.sentJSONMessages()
            if sentMessages.filter({ $0["method"] as? String == "turn/start" }).count == 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        let turnStarts = sentMessages.filter { $0["method"] as? String == "turn/start" }
        let secondParams = try #require(turnStarts.last?["params"] as? [String: Any])
        let secondInput = try #require(secondParams["input"] as? [[String: Any]])

        #expect(await factoryCallCount.value == 1)
        #expect(turnStarts.count == 2)
        #expect(secondParams["threadId"] as? String == "thread-1")
        #expect((secondParams["sandboxPolicy"] as? [String: Any])?["type"] as? String == "workspaceWrite")
        #expect(secondInput.first?["text"] as? String == CodexPromptBuilder.workspaceWritePrompt(for: "fix the failing test"))
    }

    @Test func companionManagerStopKeepsSessionForNextTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerStopKeepsSessionTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerStopKeepsSessionTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let factoryCallCount = AsyncCounter()
        let transport = InterruptCompletingCodexAppServerTransport(
            initialLines: [
                #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
                #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
                #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"inProgress"}}}"#,
                #"{"method":"item/agentMessage/delta","params":{"delta":"Working"}}"#
            ],
            interruptCompletionLines: [
                #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-9","items":[],"status":"interrupted"}}}"#,
                #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-10","items":[],"status":"inProgress"}}}"#,
                #"{"method":"item/agentMessage/delta","params":{"delta":"Still here"}}"#,
                #"{"method":"turn/completed","params":{"threadId":"thread-1","turn":{"id":"turn-10","items":[],"status":"completed"}}}"#
            ]
        )
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: {
                await factoryCallCount.increment()
                return transport
            },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.streamText == "Working" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.stopCurrentRun()
        for _ in 0..<40 {
            if manager.latestResultSummary == "Stopped." {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.handleFinalTranscriptForTesting("use computer use to keep going")
        for _ in 0..<40 {
            if manager.latestResultSummary == "Still here" {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        let sentMessages = try await transport.sentJSONMessages()
        let interrupt = try #require(sentMessages.first { $0["method"] as? String == "turn/interrupt" })
        let interruptParams = try #require(interrupt["params"] as? [String: Any])
        let turnStarts = sentMessages.filter { $0["method"] as? String == "turn/start" }

        #expect(interruptParams["threadId"] as? String == "thread-1")
        #expect(interruptParams["turnId"] as? String == "turn-9")
        #expect(turnStarts.count == 2)
        #expect(turnStarts.compactMap { ($0["params"] as? [String: Any])?["threadId"] as? String } == ["thread-1", "thread-1"])
        #expect(await factoryCallCount.value == 1)
        #expect(!(await transport.didTerminate))
    }

    private func isOrderedSubsequence(
        _ expected: [LoreleiRunStatus],
        of recorded: [LoreleiRunStatus]
    ) -> Bool {
        var remaining = expected[...]
        for status in recorded {
            if status == remaining.first {
                remaining = remaining.dropFirst()
            }
        }
        return remaining.isEmpty
    }

    @Test func companionManagerShowsNeedsApprovalStatusDuringApprovalBridge() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerApprovalRunStatusTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerApprovalRunStatusTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":44,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow control?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow."},{"label":"Decline","description":"Stop."}]}]}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(5)
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .needsApproval("Computer Use"))

        manager.acceptPendingApproval()
        for _ in 0..<20 {
            if case .working = manager.runStatus {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .working("Thinking…"))
        await transport.enqueue(#"{"method":"item/agentMessage/delta","params":{"delta":"Approved"}}"#)
        await transport.enqueue(#"{"method":"turn/completed","params":{"status":"completed"}}"#)
    }

    @Test func companionManagerStopTerminatesLiveTransport() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerStopRunTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerStopRunTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        ])
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60)
        )

        let recorder = RunStatusRecorder()
        let statusCancellable = manager.$runStatus.sink { recorder.record($0) }
        defer { statusCancellable.cancel() }

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if recorder.statuses.contains(.working("Thinking…")) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.stopCurrentRun()
        for _ in 0..<20 {
            if await transport.didTerminate {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(await transport.didTerminate)
        #expect(manager.latestResultSummary == "Stopped.")
        #expect(manager.runStatus == .finished(success: false))
    }

    @Test func companionManagerPlaysFailureCueOnStop() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerAudioStopTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerAudioStopTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if manager.runStatus == .working("Thinking…") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        manager.stopCurrentRun()

        // Stop now resolves asynchronously (interrupt-or-invalidate hops to a
        // main-actor task), so poll for the cue instead of asserting one tick
        // after the call.
        let expectedEvent = BuddyAudioFeedbackRecorder.Event(cue: .runFailed, spokenSummary: "Stopped.")
        for _ in 0..<100 {
            if audioFeedback.events.contains(expectedEvent) {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(audioFeedback.events.contains(expectedEvent))
    }

    @Test func companionManagerPlaysApprovalCue() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerAudioApprovalTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerAudioApprovalTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"id":44,"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow control?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow."},{"label":"Decline","description":"Stop."}]}]}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<20 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(audioFeedback.events.filter { $0.cue == .approvalRequested }.count == 1)
        #expect(audioFeedback.events.first { $0.cue == .approvalRequested }?.spokenSummary == nil)
    }

    @Test func companionManagerStopWithoutRunIsNoOp() {
        let defaults = UserDefaults(suiteName: "CompanionManagerStopWithoutRunTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerStopWithoutRunTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.stopCurrentRun()

        #expect(manager.runStatus == .idle)
        #expect(manager.latestResultSummary == nil)
        #expect(manager.pendingApprovalTitle == nil)
    }

    @Test func companionManagerRecordsCompletedTurnWhenHistoryEnabled() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerHistoryEnabledTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerHistoryEnabledTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let historyRecorder = HistoryRecordRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            historyRecorder: { role, text in
                historyRecorder.record(role: role, text: text)
            },
            historyEnabled: { true },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<200 {
            if historyRecorder.roles.count >= 2 {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(historyRecorder.roles == ["user", "assistant"])
        #expect(historyRecorder.texts == [
            "use computer use to inspect TextEdit",
            "Hello"
        ])
        #expect(historyRecorder.assistantCount == 1)
        #expect(!historyRecorder.texts.contains("Hel"))
        #expect(!historyRecorder.texts.contains("lo"))
    }

    @Test func companionManagerRecordsNothingWhenHistoryDisabled() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerHistoryDisabledTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerHistoryDisabledTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = FakeCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"Hel"}}"#,
            #"{"method":"item/agentMessage/delta","params":{"delta":"lo"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let historyRecorder = HistoryRecordRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            historyRecorder: { role, text in
                historyRecorder.record(role: role, text: text)
            },
            historyEnabled: { false },
            runStatusIdleReturnDelay: .seconds(60)
        )

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<200 {
            if case .finished = manager.runStatus {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(historyRecorder.roles.isEmpty)
        #expect(manager.streamText == "Hello")
    }

    @Test func companionManagerAutoAcceptsRepeatedApprovalTitleWithinTurn() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerApprovalMemoryRepeatTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerApprovalMemoryRepeatTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"inProgress"}}}"#,
            Self.computerUseApprovalRequestLine(id: 44),
            Self.computerUseApprovalRequestLine(id: 45),
            #"{"method":"item/agentMessage/delta","params":{"delta":"Done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )
        let recorder = RunStatusRecorder()
        let statusCancellable = manager.$runStatus.sink { recorder.record($0) }
        defer { statusCancellable.cancel() }

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.runStatus == .needsApproval("Computer Use"))

        manager.acceptPendingApproval()
        for _ in 0..<200 {
            if case .finished(success: true) = manager.runStatus {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .finished(success: true))
        #expect(recorder.statuses.filter { $0 == .needsApproval("Computer Use") }.count == 1)
        #expect(audioFeedback.events.filter { $0.cue == .approvalRequested }.count == 1)
        #expect(manager.latestResultSummary == "Done")
    }

    @Test func companionManagerSurfacesApprovalAgainAfterDecline() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerApprovalMemoryDeclineTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerApprovalMemoryDeclineTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"inProgress"}}}"#,
            Self.computerUseApprovalRequestLine(id: 44),
            Self.computerUseApprovalRequestLine(id: 45),
            #"{"method":"item/agentMessage/delta","params":{"delta":"Done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )
        let recorder = RunStatusRecorder()
        let statusCancellable = manager.$runStatus.sink { recorder.record($0) }
        defer { statusCancellable.cancel() }

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.runStatus == .needsApproval("Computer Use"))

        manager.cancelPendingApproval()
        for _ in 0..<40 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.runStatus == .needsApproval("Computer Use"))

        manager.acceptPendingApproval()
        for _ in 0..<200 {
            if case .finished = manager.runStatus {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(recorder.statuses.filter { $0 == .needsApproval("Computer Use") }.count == 2)
        #expect(audioFeedback.events.filter { $0.cue == .approvalRequested }.count == 2)
    }

    @Test func companionManagerSurfacesRepeatedApprovalWhenMemoryDisabled() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerApprovalMemoryDisabledTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerApprovalMemoryDisabledTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let transport = BlockingCodexAppServerTransport(lines: [
            #"{"id":1,"result":{"userAgent":"codex-test"}}"#,
            #"{"id":2,"result":{"thread":{"id":"thread-1"}}}"#,
            #"{"method":"turn/started","params":{"threadId":"thread-1","turn":{"id":"turn-1","items":[],"status":"inProgress"}}}"#,
            Self.computerUseApprovalRequestLine(id: 44),
            Self.computerUseApprovalRequestLine(id: 45),
            #"{"method":"item/agentMessage/delta","params":{"delta":"Done"}}"#,
            #"{"method":"turn/completed","params":{"status":"completed"}}"#
        ])
        let audioFeedback = BuddyAudioFeedbackRecorder()
        let manager = CompanionManager(
            speechOutput: SilentSpeechOutput(),
            workspaceSettingsStore: store,
            codexAppServerTransportFactory: { transport },
            approvalMemoryEnabled: { false },
            runStatusIdleReturnDelay: .seconds(60),
            audioFeedback: audioFeedback
        )
        let recorder = RunStatusRecorder()
        let statusCancellable = manager.$runStatus.sink { recorder.record($0) }
        defer { statusCancellable.cancel() }

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        for _ in 0..<40 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.runStatus == .needsApproval("Computer Use"))

        manager.acceptPendingApproval()
        for _ in 0..<40 {
            if manager.runStatus == .needsApproval("Computer Use") {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(manager.runStatus == .needsApproval("Computer Use"))

        manager.acceptPendingApproval()
        for _ in 0..<200 {
            if case .finished(success: true) = manager.runStatus {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .finished(success: true))
        #expect(recorder.statuses.filter { $0 == .needsApproval("Computer Use") }.count == 2)
        #expect(audioFeedback.events.filter { $0.cue == .approvalRequested }.count == 2)
    }

    private static func computerUseApprovalRequestLine(id: Int) -> String {
        #"{"id":\#(id),"method":"item/tool/requestUserInput","params":{"threadId":"thread-1","turnId":"turn-1","itemId":"item-1","questions":[{"id":"approval","header":"Computer Use","question":"Allow control?","isOther":false,"isSecret":false,"options":[{"label":"Accept","description":"Allow."},{"label":"Decline","description":"Stop."}]}]}}"#
    }
}

@MainActor
private final class HistoryRecordRecorder {
    private(set) var roles: [String] = []
    private(set) var texts: [String] = []

    var assistantCount: Int {
        roles.filter { $0 == "assistant" }.count
    }

    func record(role: String, text: String) {
        roles.append(role)
        texts.append(text)
    }
}
