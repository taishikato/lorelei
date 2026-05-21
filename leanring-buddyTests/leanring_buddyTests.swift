//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
import Foundation
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

    @Test func workspaceSelectionPersistsOnePath() async throws {
        let defaults = UserDefaults(suiteName: "WorkspaceSettingsStoreTests")!
        defaults.removePersistentDomain(forName: "WorkspaceSettingsStoreTests")

        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = "/Users/example/Project"

        let reloadedStore = WorkspaceSettingsStore(defaults: defaults)
        #expect(reloadedStore.selectedWorkspacePath == "/Users/example/Project")
    }

    @Test func workspaceStoreLoadsExistingValueFromDefaults() async throws {
        let defaults = UserDefaults(suiteName: "WorkspaceSettingsStoreExistingValueTests")!
        defaults.removePersistentDomain(forName: "WorkspaceSettingsStoreExistingValueTests")
        defaults.set("/Users/example/ExistingProject", forKey: WorkspaceSettingsStore.selectedWorkspacePathDefaultsKey)

        let store = WorkspaceSettingsStore(defaults: defaults)

        #expect(store.selectedWorkspacePath == "/Users/example/ExistingProject")
    }

    @Test func clearingWorkspaceSelectionRemovesPersistedValue() async throws {
        let defaults = UserDefaults(suiteName: "WorkspaceSettingsStoreClearingTests")!
        defaults.removePersistentDomain(forName: "WorkspaceSettingsStoreClearingTests")

        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = "/Users/example/Project"
        store.clearSelectedWorkspacePath()

        let reloadedStore = WorkspaceSettingsStore(defaults: defaults)
        #expect(defaults.string(forKey: WorkspaceSettingsStore.selectedWorkspacePathDefaultsKey) == nil)
        #expect(reloadedStore.selectedWorkspacePath == nil)
    }

    @Test func workspacePathStatusRequiresExistingDirectory() async throws {
        let defaults = UserDefaults(suiteName: "WorkspaceSettingsStoreDirectoryStatusTests")!
        defaults.removePersistentDomain(forName: "WorkspaceSettingsStoreDirectoryStatusTests")
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let store = WorkspaceSettingsStore(defaults: defaults)
        store.selectedWorkspacePath = temporaryDirectory.path
        #expect(store.selectedWorkspaceStatus == .validDirectory(temporaryDirectory.path))
        #expect(store.canOpenSelectedWorkspace)

        store.selectedWorkspacePath = temporaryDirectory.appendingPathComponent("missing").path
        #expect(store.selectedWorkspaceStatus == .invalidDirectory(store.selectedWorkspacePath!))
        #expect(!store.canOpenSelectedWorkspace)
    }
}
