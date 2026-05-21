//
//  BuddyTranscriptionProvider.swift
//  leanring-buddy
//
//  Shared protocol surface for voice transcription backends.
//

import AVFoundation
import Foundation

protocol BuddyStreamingTranscriptionSession: AnyObject {
    var finalTranscriptFallbackDelaySeconds: TimeInterval { get }
    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer)
    func requestFinalTranscript()
    func cancel()
}

protocol BuddyTranscriptionProvider {
    var displayName: String { get }
    var requiresSpeechRecognitionPermission: Bool { get }
    var isConfigured: Bool { get }
    var unavailableExplanation: String? { get }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession
}

enum BuddyTranscriptionProviderFactory {
    private enum PreferredProvider: String {
        case openAI = "openai"
        case appleSpeech = "apple"
    }

    static func makeDefaultProvider() -> any BuddyTranscriptionProvider {
        let provider = resolveProvider()
        print("🎙️ Transcription: using \(provider.displayName)")
        return provider
    }

    static func shouldUseOpenAIProvider(
        preferredProviderRawValue: String?,
        openAIIsConfigured: Bool
    ) -> Bool {
        let preferredProvider = preferredProviderRawValue
            .map { $0.lowercased() }
            .flatMap(PreferredProvider.init(rawValue:))

        return preferredProvider == .openAI && openAIIsConfigured
    }

    private static func resolveProvider() -> any BuddyTranscriptionProvider {
        let preferredProviderRawValue = AppBundleConfiguration
            .stringValue(forKey: "VoiceTranscriptionProvider")?
            .lowercased()
        let preferredProvider = preferredProviderRawValue.flatMap(PreferredProvider.init(rawValue:))

        let openAIProvider = OpenAIAudioTranscriptionProvider()

        if preferredProvider == .appleSpeech {
            return AppleSpeechTranscriptionProvider()
        }

        if preferredProvider == .openAI && !openAIProvider.isConfigured {
            print("⚠️ Transcription: OpenAI preferred but not configured, falling back")

            print("⚠️ Transcription: using Apple Speech as fallback")
            return AppleSpeechTranscriptionProvider()
        }

        if shouldUseOpenAIProvider(
            preferredProviderRawValue: preferredProviderRawValue,
            openAIIsConfigured: openAIProvider.isConfigured
        ) {
            return openAIProvider
        }

        return AppleSpeechTranscriptionProvider()
    }
}
