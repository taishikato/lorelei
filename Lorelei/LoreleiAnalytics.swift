//
//  LoreleiAnalytics.swift
//  Lorelei
//
//  Product analytics via PostHog.
//
//  Privacy contract: NEVER send what the user said or what the assistant
//  answered - no transcripts, no conversation text, no file paths. Events
//  carry only coarse metadata (counts, durations, statuses) so usage is
//  visible without the content being readable.
//

import Foundation
import PostHog

enum LoreleiAnalyticsConfiguration {
    /// PostHog project API key (phc_...). Client-side keys are public by
    /// design. Empty disables analytics entirely.
    static let apiKey = "phc_f2SrTDcAw7HO7Nk1rVSct7Zk0ox7cQttfONrhsfAzHU"
    static let host = "https://us.i.posthog.com"
}

enum LoreleiAnalyticsEvent {
    case appLaunched
    case dictationCompleted(transcriptCharacters: Int, viaSteer: Bool)
    case systemDictationStarted
    case systemDictationInserted(
        usedFallbackText: Bool,
        appCategory: String,
        formatMs: Int,
        totalMs: Int,
        rawVisibleMs: Int,
        replacement: String
    )
    case systemDictationCopiedToClipboard(
        formatMs: Int,
        totalMs: Int,
        replacement: String
    )
    case turnStarted(sandboxPolicy: String)
    case turnCompleted(success: Bool, durationSeconds: Double)
    case steerSent
    case steerFailed
    case runStopped
    case approvalRequested
    case approvalResolved(accepted: Bool)
    case settingsPanelOpened
    case toolbarExpanded
    case newChatStarted
    case onboardingStarted
    case onboardingCompleted
    case updateCheckPerformed(updateAvailable: Bool)

    var name: String {
        switch self {
        case .appLaunched: "app_launched"
        case .dictationCompleted: "dictation_completed"
        case .systemDictationStarted: "system_dictation_started"
        case .systemDictationInserted: "system_dictation_inserted"
        case .systemDictationCopiedToClipboard: "system_dictation_copied_to_clipboard"
        case .turnStarted: "turn_started"
        case .turnCompleted: "turn_completed"
        case .steerSent: "steer_sent"
        case .steerFailed: "steer_failed"
        case .runStopped: "run_stopped"
        case .approvalRequested: "approval_requested"
        case .approvalResolved: "approval_resolved"
        case .settingsPanelOpened: "settings_panel_opened"
        case .toolbarExpanded: "toolbar_expanded"
        case .newChatStarted: "new_chat_started"
        case .onboardingStarted: "onboarding_started"
        case .onboardingCompleted: "onboarding_completed"
        case .updateCheckPerformed: "update_check_performed"
        }
    }

    var properties: [String: Any] {
        switch self {
        case .appLaunched, .steerSent, .steerFailed, .runStopped,
             .approvalRequested, .settingsPanelOpened, .toolbarExpanded,
             .newChatStarted, .onboardingStarted, .onboardingCompleted,
             .systemDictationStarted:
            return [:]
        case .dictationCompleted(let transcriptCharacters, let viaSteer):
            return [
                "transcript_characters": transcriptCharacters,
                "via_steer": viaSteer
            ]
        case .systemDictationInserted(
            let usedFallbackText,
            let appCategory,
            let formatMs,
            let totalMs,
            let rawVisibleMs,
            let replacement
        ):
            return [
                "used_fallback_text": usedFallbackText,
                "app_category": appCategory,
                "format_ms": formatMs,
                "total_ms": totalMs,
                "raw_visible_ms": rawVisibleMs,
                "replacement": replacement
            ]
        case .systemDictationCopiedToClipboard(let formatMs, let totalMs, let replacement):
            return [
                "format_ms": formatMs,
                "total_ms": totalMs,
                "replacement": replacement
            ]
        case .turnStarted(let sandboxPolicy):
            return ["sandbox_policy": sandboxPolicy]
        case .turnCompleted(let success, let durationSeconds):
            return [
                "success": success,
                "duration_seconds": (durationSeconds * 10).rounded() / 10
            ]
        case .approvalResolved(let accepted):
            return ["accepted": accepted]
        case .updateCheckPerformed(let updateAvailable):
            return ["update_available": updateAvailable]
        }
    }
}

enum LoreleiAnalytics {
    private static var isConfigured = false

    /// Analytics run only in Release builds with an API key present.
    static var isEnabled: Bool {
        #if DEBUG
        return false
        #else
        return !LoreleiAnalyticsConfiguration.apiKey.isEmpty
        #endif
    }

    static func setUpIfNeeded() {
        guard isEnabled, !isConfigured else { return }
        isConfigured = true

        let config = PostHogConfig(
            apiKey: LoreleiAnalyticsConfiguration.apiKey,
            host: LoreleiAnalyticsConfiguration.host
        )
        config.captureApplicationLifecycleEvents = false
        // Lorelei emits a handful of events per session, so flush each one
        // immediately instead of waiting for the SDK's default batch of 20.
        config.flushAt = 1
        PostHogSDK.shared.setup(config)
    }

    static func capture(_ event: LoreleiAnalyticsEvent) {
        guard isEnabled else { return }
        setUpIfNeeded()
        PostHogSDK.shared.capture(event.name, properties: event.properties)
    }
}
