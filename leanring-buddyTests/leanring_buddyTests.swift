//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import Lorelei

@MainActor
struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func openAITranscriptionIsNotDefaultWhenConfigured() async throws {
        let shouldUseOpenAI = BuddyTranscriptionProviderFactory.shouldUseOpenAIProvider(
            preferredProviderRawValue: nil,
            openAIIsConfigured: true
        )

        #expect(!shouldUseOpenAI)
    }

    @Test func openAITranscriptionCanBeExplicitlySelectedWhenConfigured() async throws {
        let shouldUseOpenAI = BuddyTranscriptionProviderFactory.shouldUseOpenAIProvider(
            preferredProviderRawValue: "openai",
            openAIIsConfigured: true
        )

        #expect(shouldUseOpenAI)
    }
}
