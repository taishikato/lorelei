//
//  CompanionManagerPermissionsTests.swift
//  LoreleiTests
//

import Foundation
import Testing
@testable import Lorelei

@MainActor
struct CompanionManagerPermissionsTests {
    @Test func freshCompanionManagerReportsAllRequiredPermissionsMissing() async throws {
        let defaults = UserDefaults(suiteName: "CompanionManagerPermissionsTests")!
        defaults.removePersistentDomain(forName: "CompanionManagerPermissionsTests")
        let store = WorkspaceSettingsStore(defaults: defaults)
        let manager = CompanionManager(
            speechOutput: PermissionTestSpeechOutput(),
            workspaceSettingsStore: store
        )

        #expect(!manager.allPermissionsGranted)
        #expect(manager.missingPermissionNames == ["Microphone", "Accessibility", "Screen Recording", "Screen Content"])
    }
}

@MainActor
private final class PermissionTestSpeechOutput: SpeechOutputing {
    func speak(_ text: String) {}
    func stopSpeaking() {}
}
