//
//  PanelPresentationTests.swift
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
struct PanelPresentationTests {

    @Test func responseTaskTrackerIgnoresStaleTaskCleanup() async throws {
        var tracker = CompanionResponseTaskTracker()

        let oldTaskID = tracker.begin()
        let newTaskID = tracker.begin()
        let didFinishOldTask = tracker.finishIfCurrent(oldTaskID)
        let currentTaskIDAfterOldFinish = tracker.currentTaskID
        let didFinishNewTask = tracker.finishIfCurrent(newTaskID)

        #expect(!didFinishOldTask)
        #expect(currentTaskIDAfterOldFinish == newTaskID)
        #expect(didFinishNewTask)
        #expect(tracker.currentTaskID == nil)
    }

    @Test func speechStatusUsesShortAllowedPhrases() async throws {
        #expect(WorkspaceCommandResult(summary: "OK", status: .succeeded).spokenStatus == "Done")
        #expect(WorkspaceCommandResult(summary: "No workspace selected.", status: .missingWorkspace).spokenStatus == "No workspace selected")
        #expect(WorkspaceCommandResult(summary: "Failed", status: .failed).spokenStatus == "Failed")
    }

    @Test func firstSentenceCutsAtTerminatorAndCap() async throws {
        #expect(BuddyAudioFeedback.firstSentence("Opened Gmail. Then waited.") == "Opened Gmail.")
        #expect(BuddyAudioFeedback.firstSentence(String(repeating: "a", count: 300)).count == 120)
        #expect(BuddyAudioFeedback.firstSentence(String(repeating: "a", count: 300)).hasSuffix("…"))
        #expect(BuddyAudioFeedback.firstSentence("Gmailを開きました。次に…") == "Gmailを開きました。")
    }

    @Test func collapsedIslandFrameIsTopCenteredAndFlushWithScreenTop() async throws {
        // 14" MacBook Pro shape: full frame 1512x982, notch/menu bar 32pt.
        let windowSize = LoreleiToolbarController.collapsedWindowSize(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTop: 32,
            auxiliaryTopLeftWidth: 661,
            auxiliaryTopRightWidth: 661
        )
        let frame = LoreleiToolbarController.collapsedIslandFrame(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            windowSize: windowSize
        )

        #expect(windowSize == CGSize(width: 250, height: 72))
        #expect(frame == CGRect(x: 631, y: 910, width: 250, height: 72))
        #expect(frame.maxY == 982)
    }

    @Test func cursorCapsuleSitsRightOfCursor() async throws {
        let origin = BlueCursorView.capsuleOrigin(
            cursorPoint: CGPoint(x: 500, y: 500),
            capsuleSize: CGSize(width: 140, height: 34),
            screenFrame: CGRect(x: 0, y: 0, width: 2000, height: 1200)
        )

        #expect(origin == CGPoint(x: 518, y: 483))
    }

    @Test func cursorCapsuleFlipsLeftNearRightEdge() async throws {
        let origin = BlueCursorView.capsuleOrigin(
            cursorPoint: CGPoint(x: 1950, y: 500),
            capsuleSize: CGSize(width: 140, height: 34),
            screenFrame: CGRect(x: 0, y: 0, width: 2000, height: 1200)
        )

        #expect(origin == CGPoint(x: 1792, y: 483))
    }

    @Test func toolbarStatusLabelReflectsRunStatus() async throws {
        #expect(LoreleiToolbarView.statusLabel(for: .idle) == "Ready")
        #expect(LoreleiToolbarView.statusLabel(for: .listening) == "Listening…")
        #expect(LoreleiToolbarView.statusLabel(for: .transcribing) == "Transcribing…")
        #expect(LoreleiToolbarView.statusLabel(for: .working("lorelei.set_text")) == "lorelei.set_text")
        #expect(LoreleiToolbarView.statusLabel(for: .needsApproval("Run command")) == "Needs approval")
        #expect(LoreleiToolbarView.statusLabel(for: .finished(success: false)) == "Failed")
    }

    @Test func loreleiFaceExpressionMapsRunStatus() async throws {
        #expect(LoreleiFaceExpression.expression(for: .idle) == .neutral)
        #expect(LoreleiFaceExpression.expression(for: .listening) == .listening)
        #expect(LoreleiFaceExpression.expression(for: .transcribing) == .working)
        #expect(LoreleiFaceExpression.expression(for: .working("lorelei.set_text")) == .working)
        #expect(LoreleiFaceExpression.expression(for: .needsApproval("Run command")) == .questioning)
        #expect(LoreleiFaceExpression.expression(for: .finished(success: true)) == .happy)
        #expect(LoreleiFaceExpression.expression(for: .finished(success: false)) == .sad)
    }

    @Test func toolbarAutoExpandsOnApprovalRequest() async throws {
        let defaults = UserDefaults(suiteName: "ToolbarAutoExpansionApprovalTests")!
        defaults.removePersistentDomain(forName: "ToolbarAutoExpansionApprovalTests")
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
            runStatusIdleReturnDelay: .seconds(60)
        )
        let controller = LoreleiToolbarController(companionManager: manager)

        manager.handleFinalTranscriptForTesting("use computer use to inspect TextEdit")
        // Wait on the approval itself: the panel already opens when the turn
        // starts, so `isExpanded` would go true long before the request lands.
        for _ in 0..<20 {
            if manager.pendingApprovalTitle != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .needsApproval("Computer Use"))
        #expect(controller.isExpanded)
    }

    @Test func toolbarPanelRefusesKeyFocusUntilAllowed() async throws {
        let panel = LoreleiToolbarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        #expect(!panel.canBecomeKey)

        panel.keyFocusAllowed = true
        #expect(panel.canBecomeKey)

        panel.keyFocusAllowed = false
        #expect(!panel.canBecomeKey)
    }

    @Test func expandedWindowHeightStacksThePanelUnderTheIsland() async throws {
        let islandSize = IslandGeometry.islandSize(notchWidth: 190, safeAreaTop: 32)
        #expect(islandSize.height == 32)

        let plainWindowHeight = islandSize.height
            + IslandGeometry.expandedPanelHeight(hasPendingApproval: false)
        let approvingWindowHeight = islandSize.height
            + IslandGeometry.expandedPanelHeight(hasPendingApproval: true)

        #expect(plainWindowHeight == 32 + IslandGeometry.expandedPanelSize.height)
        #expect(approvingWindowHeight
            == plainWindowHeight + IslandGeometry.approvalPanelExtraHeight)
        #expect(IslandGeometry.expandedPanelSize.width == 460)
    }

    @Test func aVoiceSteerDoesNotReopenAPanelTheUserCollapsed() {
        var tracker = LoreleiToolbarController.PanelAutoExpansionTracker()
        // `#expect` captures its expression in a closure, so the mutating
        // calls have to happen out here.
        let turnStart = tracker.shouldExpand(for: .working("Thinking…"), isAssistantTurnActive: true)
        let laterActivity = tracker.shouldExpand(for: .working("lorelei.set_text"), isAssistantTurnActive: true)
        let steerListening = tracker.shouldExpand(for: .listening, isAssistantTurnActive: true)
        let steerTranscribing = tracker.shouldExpand(for: .transcribing, isAssistantTurnActive: true)
        let afterSteer = tracker.shouldExpand(for: .working("Thinking…"), isAssistantTurnActive: true)
        let approval = tracker.shouldExpand(for: .needsApproval("Computer Use"), isAssistantTurnActive: true)
        let turnOver = tracker.shouldExpand(for: .idle, isAssistantTurnActive: false)
        let nextTurn = tracker.shouldExpand(for: .working("Thinking…"), isAssistantTurnActive: true)

        // The turn starts and opens the panel once.
        #expect(turnStart)
        // Later activity updates in the same turn leave it alone, so a user
        // who collapsed it is not fought.
        #expect(!laterActivity)
        // A voice steer runs INSIDE the turn: it passes through listening and
        // transcribing, and the working status that follows must not reopen
        // what the user closed.
        #expect(!steerListening)
        #expect(!steerTranscribing)
        #expect(!afterSteer)
        // An approval blocks the run, so it still surfaces mid-turn.
        #expect(approval)
        // Once the turn is over, the next one may open the panel again.
        #expect(!turnOver)
        #expect(nextTurn)
    }

    @Test func autoExpansionRulesCoverTurnsApprovalsAndDictation() {
        // A command turn opens the panel, but only once - `.working` re-emits
        // on every tool change and must not fight a mid-run collapse.
        #expect(LoreleiToolbarController.autoExpansion(
            for: .working("Thinking…"), isAssistantTurnActive: true
        ) == .oncePerTurn)
        // System dictation reports `.working` too and must NOT open it.
        #expect(LoreleiToolbarController.autoExpansion(
            for: .working("Dictating…"), isAssistantTurnActive: false
        ) == .none)
        // Approvals block the run, so they surface every time.
        #expect(LoreleiToolbarController.autoExpansion(
            for: .needsApproval("Computer Use"), isAssistantTurnActive: true
        ) == .always)
        #expect(LoreleiToolbarController.autoExpansion(
            for: .needsApproval("Computer Use"), isAssistantTurnActive: false
        ) == .always)
        // Nothing else does.
        #expect(LoreleiToolbarController.autoExpansion(
            for: .idle, isAssistantTurnActive: false
        ) == .none)
        #expect(LoreleiToolbarController.autoExpansion(
            for: .listening, isAssistantTurnActive: false
        ) == .none)
        #expect(LoreleiToolbarController.autoExpansion(
            for: .transcribing, isAssistantTurnActive: false
        ) == .none)
        #expect(LoreleiToolbarController.autoExpansion(
            for: .finished(success: true), isAssistantTurnActive: false
        ) == .none)
    }

    @Test func toolbarAutoExpandsWhenTheAssistantStartsResponding() async throws {
        let defaults = UserDefaults(suiteName: "ToolbarAutoExpansionTurnTests")!
        defaults.removePersistentDomain(forName: "ToolbarAutoExpansionTurnTests")
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
        let controller = LoreleiToolbarController(companionManager: manager)

        #expect(!controller.isExpanded)

        manager.submitTypedMessage("open the notes app")
        for _ in 0..<40 {
            if controller.isExpanded { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(controller.isExpanded)
    }

    @Test func latestExchangeShowsOnlyTheCurrentCombo() {
        func user(_ text: String) -> ConversationEntry {
            ConversationEntry(id: UUID(), role: .user, text: text)
        }
        func assistant(_ text: String) -> ConversationEntry {
            ConversationEntry(id: UUID(), role: .assistant, text: text)
        }

        #expect(LoreleiToolbarView.latestExchange(in: []).isEmpty)

        // A finished pair is the whole exchange.
        let pair = [user("first"), assistant("answer")]
        #expect(LoreleiToolbarView.latestExchange(in: pair).map(\.text) == ["first", "answer"])

        // Earlier turns drop away.
        let manyTurns = [
            user("first"), assistant("answer one"),
            user("second"), assistant("answer two")
        ]
        #expect(LoreleiToolbarView.latestExchange(in: manyTurns).map(\.text) == ["second", "answer two"])

        // A question with no answer yet still shows.
        let unanswered = [user("first"), assistant("answer one"), user("second")]
        #expect(LoreleiToolbarView.latestExchange(in: unanswered).map(\.text) == ["second"])

        // A steer becomes the head of the current exchange.
        let steered = [
            user("first"), assistant("answer one"),
            user("↪ actually the other window"), assistant("answer two")
        ]
        #expect(LoreleiToolbarView.latestExchange(in: steered).map(\.text) == [
            "↪ actually the other window",
            "answer two"
        ])

        // No user entry at all: show what there is rather than nothing.
        let assistantOnly = [assistant("greeting")]
        #expect(LoreleiToolbarView.latestExchange(in: assistantOnly).map(\.text) == ["greeting"])
    }
}
