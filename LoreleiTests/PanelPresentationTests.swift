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
        for _ in 0..<20 {
            if controller.isExpanded {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        #expect(manager.runStatus == .needsApproval("Computer Use"))
        #expect(controller.isExpanded)
    }
}
