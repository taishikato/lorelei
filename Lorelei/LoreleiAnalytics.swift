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
    static let apiKey = ""
    static let host = "https://us.i.posthog.com"
}

enum LoreleiAnalyticsEvent {
    case appLaunched
    case dictationCompleted(transcriptCharacters: Int, viaSteer: Bool)
    case turnStarted(sandboxPolicy: String)
    case turnCompleted(success: Bool, durationSeconds: Double)
    case steerSent
    case steerFailed
    case runStopped
    case approvalRequested
    case approvalResolved(accepted: Bool)
    case settingsPanelOpened
    case toolbarExpanded

    var name: String {
        switch self {
        case .appLaunched: "app_launched"
        case .dictationCompleted: "dictation_completed"
        case .turnStarted: "turn_started"
        case .turnCompleted: "turn_completed"
        case .steerSent: "steer_sent"
        case .steerFailed: "steer_failed"
        case .runStopped: "run_stopped"
        case .approvalRequested: "approval_requested"
        case .approvalResolved: "approval_resolved"
        case .settingsPanelOpened: "settings_panel_opened"
        case .toolbarExpanded: "toolbar_expanded"
        }
    }

    var properties: [String: Any] {
        switch self {
        case .appLaunched, .steerSent, .steerFailed, .runStopped,
             .approvalRequested, .settingsPanelOpened, .toolbarExpanded:
            return [:]
        case .dictationCompleted(let transcriptCharacters, let viaSteer):
            return [
                "transcript_characters": transcriptCharacters,
                "via_steer": viaSteer
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
        }
    }
}

enum LoreleiAnalytics {
    static let optOutDefaultsKey = "LoreleiAnalyticsOptOut"

    private static var isConfigured = false

    /// Analytics run only in Release builds with an API key present, and
    /// respect the user's opt-out toggle in the settings panel.
    static var isEnabled: Bool {
        #if DEBUG
        return false
        #else
        return !LoreleiAnalyticsConfiguration.apiKey.isEmpty
            && !UserDefaults.standard.bool(forKey: optOutDefaultsKey)
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
        PostHogSDK.shared.setup(config)
    }

    static func capture(_ event: LoreleiAnalyticsEvent) {
        guard isEnabled else { return }
        setUpIfNeeded()
        PostHogSDK.shared.capture(event.name, properties: event.properties)
    }

    static func setOptOut(_ optedOut: Bool) {
        UserDefaults.standard.set(optedOut, forKey: optOutDefaultsKey)
        if optedOut, isConfigured {
            PostHogSDK.shared.flush()
        }
    }
}
