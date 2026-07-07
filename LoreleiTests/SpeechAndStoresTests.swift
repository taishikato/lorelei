//
//  SpeechAndStoresTests.swift
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
struct SpeechAndStoresTests {

    @Test func speechAnalyzerReducerCombinesVolatileAndFinalizedText() async throws {
        var reducer = SpeechAnalyzerTranscriptReducer()

        reducer.applyVolatile("hel")
        #expect(reducer.currentTranscript == "hel")

        reducer.applyVolatile("hello wor")
        #expect(reducer.currentTranscript == "hello wor")

        reducer.applyFinalized("hello world")
        #expect(reducer.currentTranscript == "hello world")
        #expect(reducer.finalizedText == "hello world")
        #expect(reducer.volatileText.isEmpty)

        reducer.applyVolatile("again")
        #expect(reducer.currentTranscript == "hello world again")
    }

    @Test func speechAnalyzerReducerFinalizeIsIdempotentPerSegment() async throws {
        var reducer = SpeechAnalyzerTranscriptReducer()

        reducer.applyFinalized("open textedit")
        reducer.applyFinalized("type hello")

        #expect(reducer.finalizedText == "open textedit type hello")
    }

    @Test func defaultTranscriptionProviderUsesSpeechAnalyzer() async throws {
        let provider = BuddyTranscriptionProviderFactory.makeProvider(preferredProviderRawValue: nil)

        #expect(provider is SpeechAnalyzerTranscriptionProvider)
        #expect(!provider.requiresSpeechRecognitionPermission)
    }

    @Test func appleTranscriptionProviderConfigUsesSpeechAnalyzer() async throws {
        let provider = BuddyTranscriptionProviderFactory.makeProvider(preferredProviderRawValue: "apple")

        #expect(provider is SpeechAnalyzerTranscriptionProvider)
        #expect(!provider.requiresSpeechRecognitionPermission)
    }

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

    @Test func selectedAudioInputDevicePersistsAndReloads() async throws {
        let defaults = UserDefaults(suiteName: "AudioInputDeviceStorePersistenceTests")!
        defaults.removePersistentDomain(forName: "AudioInputDeviceStorePersistenceTests")
        let enumerator = FakeAudioInputDeviceEnumerator(devices: [
            AudioInputDevice(id: "built-in", name: "Built-in Microphone"),
            AudioInputDevice(id: "usb", name: "USB Microphone")
        ])

        let store = AudioInputDeviceStore(enumerator: enumerator, defaults: defaults)
        store.selectedDeviceUID = "usb"

        let reloadedStore = AudioInputDeviceStore(enumerator: enumerator, defaults: defaults)
        #expect(reloadedStore.selectedDeviceUID == "usb")
        #expect(defaults.string(forKey: AudioInputDeviceStore.selectedInputDeviceUIDDefaultsKey) == "usb")
    }

    @Test func systemDefaultAudioInputRemovesPersistedSelection() async throws {
        let defaults = UserDefaults(suiteName: "AudioInputDeviceStoreSystemDefaultTests")!
        defaults.removePersistentDomain(forName: "AudioInputDeviceStoreSystemDefaultTests")
        let enumerator = FakeAudioInputDeviceEnumerator(devices: [
            AudioInputDevice(id: "built-in", name: "Built-in Microphone")
        ])

        let store = AudioInputDeviceStore(enumerator: enumerator, defaults: defaults)
        store.selectedDeviceUID = "built-in"
        store.selectedDeviceUID = nil

        let reloadedStore = AudioInputDeviceStore(enumerator: enumerator, defaults: defaults)
        #expect(defaults.string(forKey: AudioInputDeviceStore.selectedInputDeviceUIDDefaultsKey) == nil)
        #expect(reloadedStore.selectedDeviceUID == nil)
    }

    @Test func disconnectedAudioInputDeviceFallsBackToSystemDefault() async throws {
        let defaults = UserDefaults(suiteName: "AudioInputDeviceStoreDisconnectedTests")!
        defaults.removePersistentDomain(forName: "AudioInputDeviceStoreDisconnectedTests")
        defaults.set("missing", forKey: AudioInputDeviceStore.selectedInputDeviceUIDDefaultsKey)
        let enumerator = FakeAudioInputDeviceEnumerator(devices: [
            AudioInputDevice(id: "built-in", name: "Built-in Microphone")
        ])

        let store = AudioInputDeviceStore(enumerator: enumerator, defaults: defaults)

        #expect(store.selectedDeviceUID == "missing")
        #expect(store.resolvedDeviceID() == nil)
    }

    @Test func effectiveInputDeviceReleasesPreviousSelectionOnFallback() async throws {
        let defaults = UserDefaults(suiteName: "AudioInputDeviceStoreEffectiveDeviceTests")!
        defaults.removePersistentDomain(forName: "AudioInputDeviceStoreEffectiveDeviceTests")
        let enumerator = FakeAudioInputDeviceEnumerator(devices: [
            AudioInputDevice(id: "built-in", name: "Built-in Microphone"),
            AudioInputDevice(id: "usb", name: "USB Microphone")
        ])
        let store = AudioInputDeviceStore(enumerator: enumerator, defaults: defaults)

        // A connected selection resolves to that device.
        store.selectedDeviceUID = "usb"
        #expect(store.effectiveInputDeviceID() == AudioDeviceID(2))

        // System Default falls back to the default device (built-in), not the
        // previously selected one, so the engine can un-pin the USB device.
        store.selectedDeviceUID = nil
        #expect(store.effectiveInputDeviceID() == AudioDeviceID(1))

        // A disconnected selection also falls back to the default device.
        store.selectedDeviceUID = "missing"
        #expect(store.effectiveInputDeviceID() == AudioDeviceID(1))
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
