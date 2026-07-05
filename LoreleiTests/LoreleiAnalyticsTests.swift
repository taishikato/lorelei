//
//  LoreleiAnalyticsTests.swift
//  LoreleiTests
//

import Testing
@testable import Lorelei

struct LoreleiAnalyticsTests {
    @Test func eventNamesAreStable() async throws {
        #expect(LoreleiAnalyticsEvent.appLaunched.name == "app_launched")
        #expect(LoreleiAnalyticsEvent.dictationCompleted(transcriptCharacters: 5, viaSteer: false).name == "dictation_completed")
        #expect(LoreleiAnalyticsEvent.turnStarted(sandboxPolicy: "readOnly").name == "turn_started")
        #expect(LoreleiAnalyticsEvent.turnCompleted(success: true, durationSeconds: 3).name == "turn_completed")
        #expect(LoreleiAnalyticsEvent.steerSent.name == "steer_sent")
        #expect(LoreleiAnalyticsEvent.steerFailed.name == "steer_failed")
        #expect(LoreleiAnalyticsEvent.runStopped.name == "run_stopped")
        #expect(LoreleiAnalyticsEvent.approvalRequested.name == "approval_requested")
        #expect(LoreleiAnalyticsEvent.approvalResolved(accepted: true).name == "approval_resolved")
        #expect(LoreleiAnalyticsEvent.settingsPanelOpened.name == "settings_panel_opened")
        #expect(LoreleiAnalyticsEvent.toolbarExpanded.name == "toolbar_expanded")
        #expect(LoreleiAnalyticsEvent.newChatStarted.name == "new_chat_started")
    }

    @Test func dictationEventCarriesOnlyMetadataNeverContent() async throws {
        let event = LoreleiAnalyticsEvent.dictationCompleted(transcriptCharacters: 42, viaSteer: true)
        let properties = event.properties

        #expect(properties["transcript_characters"] as? Int == 42)
        #expect(properties["via_steer"] as? Bool == true)
        // Privacy contract: exactly the two metadata fields, no text payload.
        #expect(properties.count == 2)
    }

    @Test func turnCompletedRoundsDurationToOneDecimal() async throws {
        let event = LoreleiAnalyticsEvent.turnCompleted(success: false, durationSeconds: 12.3456)
        let properties = event.properties

        #expect(properties["success"] as? Bool == false)
        #expect(properties["duration_seconds"] as? Double == 12.3)
    }

    @Test func analyticsAreDisabledInDebugBuilds() async throws {
        // The suite always runs in Debug; sending telemetry from dev builds
        // would pollute production data.
        #expect(!LoreleiAnalytics.isEnabled)
    }
}
