//
//  LoreleiAnalyticsTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

struct LoreleiAnalyticsTests {
    @Test func eventNamesAreStable() async throws {
        #expect(LoreleiAnalyticsEvent.appLaunched.name == "app_launched")
        #expect(LoreleiAnalyticsEvent.dictationCompleted(transcriptCharacters: 5, viaSteer: false).name == "dictation_completed")
        #expect(LoreleiAnalyticsEvent.systemDictationStarted.name == "system_dictation_started")
        #expect(LoreleiAnalyticsEvent.systemDictationInserted(
            usedFallbackText: false,
            appCategory: "unknown",
            formatMs: 850,
            totalMs: 1400
        ).name == "system_dictation_inserted")
        #expect(LoreleiAnalyticsEvent.systemDictationCopiedToClipboard(
            formatMs: 850,
            totalMs: 1400
        ).name == "system_dictation_copied_to_clipboard")
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
        #expect(LoreleiAnalyticsEvent.onboardingStarted.name == "onboarding_started")
        #expect(LoreleiAnalyticsEvent.onboardingCompleted.name == "onboarding_completed")
        #expect(LoreleiAnalyticsEvent.updateCheckPerformed(updateAvailable: true).name == "update_check_performed")
    }

    @Test func systemDictationInsertedCarriesFallbackFlagAndAppCategory() async throws {
        let event = LoreleiAnalyticsEvent.systemDictationInserted(
            usedFallbackText: true,
            appCategory: "chat",
            formatMs: 850,
            totalMs: 1400
        )
        let properties = event.properties

        #expect(properties["used_fallback_text"] as? Bool == true)
        #expect(properties["app_category"] as? String == "chat")
        #expect(properties["format_ms"] as? Int == 850)
        #expect(properties["total_ms"] as? Int == 1400)
        #expect(properties.count == 4)
    }

    @Test func systemDictationInsertedCarriesDurations() async throws {
        let event = LoreleiAnalyticsEvent.systemDictationInserted(
            usedFallbackText: false,
            appCategory: "other",
            formatMs: 850,
            totalMs: 1400
        )
        #expect(event.name == "system_dictation_inserted")
        let properties = event.properties
        #expect(properties["used_fallback_text"] as? Bool == false)
        #expect(properties["format_ms"] as? Int == 850)
        #expect(properties["total_ms"] as? Int == 1400)
    }

    @Test func systemDictationCopiedToClipboardCarriesDurations() async throws {
        let event = LoreleiAnalyticsEvent.systemDictationCopiedToClipboard(
            formatMs: 850,
            totalMs: 1400
        )
        #expect(event.name == "system_dictation_copied_to_clipboard")
        let properties = event.properties
        #expect(properties["format_ms"] as? Int == 850)
        #expect(properties["total_ms"] as? Int == 1400)
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
